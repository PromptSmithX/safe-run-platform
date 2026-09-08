import Foundation
import SafeRunDomain
import SQLite3

public enum GatewayAcceptance: Equatable, Sendable {
    case inserted
    case duplicate
}

public struct GatewayQueueSnapshot: Equatable, Sendable {
    public let counts: [PacketPriority: Int]
    public let lastPacketID: UUID?

    public var totalCount: Int { counts.values.reduce(0, +) }
}

public struct UploadQueueClaim: Equatable, Sendable {
    public let localID: Int64
    public let packet: TransportPacket
    public let attemptCount: Int
}

public struct SessionBinding: Equatable, Sendable {
    public let localSessionID: String
    public let serverSessionID: String
    public let credentialAccount: String
    public let expiresAt: Date
    public let state: String
    public let lastSequence: Int
}

public struct PendingUploadSummary: Equatable, Sendable {
    public let retryable: Int
    public let terminal: Int
    public let nextAttemptAt: Date?
}

public enum GatewayQueueError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case integrityFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message), .sqlite(let message), .integrityFailed(let message): return message
        }
    }
}

public actor SQLiteGatewayQueue {
    private let database: OpaquePointer
    private let telemetryLimit: Int
    private var lastPacketID: UUID?

    public init(databaseURL: URL, telemetryLimit: Int = 10_000) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open gateway database."
            if let handle { sqlite3_close(handle) }
            throw GatewayQueueError.openFailed(message)
        }
        database = handle
        self.telemetryLimit = max(1, telemetryLimit)

        try Self.execute(handle, "PRAGMA journal_mode=WAL;")
        try Self.execute(handle, "PRAGMA synchronous=FULL;")
        try Self.verifyIntegrity(handle)
        try Self.execute(handle, """
            CREATE TABLE IF NOT EXISTS packets (
                local_id INTEGER PRIMARY KEY AUTOINCREMENT,
                packet_id TEXT NOT NULL UNIQUE,
                session_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                kind TEXT NOT NULL,
                priority INTEGER NOT NULL,
                payload_blob BLOB NOT NULL,
                enqueued_at REAL NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                next_attempt_at REAL,
                server_acked_at REAL
            );
            """)
        try Self.execute(handle, "CREATE INDEX IF NOT EXISTS idx_packets_pending ON packets(server_acked_at, priority, local_id);")
        try Self.execute(handle, "CREATE INDEX IF NOT EXISTS idx_packets_session_sequence ON packets(session_id, sequence);")
        try Self.addColumnIfNeeded(handle, table: "packets", name: "leased_until", definition: "REAL")
        try Self.addColumnIfNeeded(handle, table: "packets", name: "terminal_error_code", definition: "TEXT")
        try Self.addColumnIfNeeded(handle, table: "packets", name: "payload_scrubbed_at", definition: "REAL")
        try Self.execute(handle, """
            CREATE TABLE IF NOT EXISTS session_bindings (
                local_session_id TEXT PRIMARY KEY,
                server_session_id TEXT NOT NULL,
                credential_account TEXT NOT NULL,
                expires_at REAL NOT NULL,
                state TEXT NOT NULL DEFAULT 'active',
                last_sequence INTEGER NOT NULL DEFAULT 0,
                finalized_at REAL
            );
            """)
        try Self.addColumnIfNeeded(handle, table: "session_bindings", name: "last_reconciled_at", definition: "REAL")
        try Self.addColumnIfNeeded(handle, table: "session_bindings", name: "server_state", definition: "TEXT")
        try Self.addColumnIfNeeded(handle, table: "session_bindings", name: "recovery_diagnostic", definition: "TEXT")
        try Self.execute(handle, "PRAGMA user_version=3;")
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: databaseURL.path
        )
    }

    deinit { sqlite3_close(database) }

    public func accept(_ packet: TransportPacket, at date: Date = Date()) throws -> GatewayAcceptance {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let sql = """
                INSERT OR IGNORE INTO packets
                (packet_id, session_id, sequence, kind, priority, payload_blob, enqueued_at)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw sqliteError() }
            defer { sqlite3_finalize(statement) }
            bind(packet.packetID.uuidString, to: 1, in: statement)
            bind(packet.sessionID, to: 2, in: statement)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(packet.sequence))
            bind(packet.kind.rawValue, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(packet.priority.rawValue))
            packet.envelopeData.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), Self.transient)
            }
            sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            let inserted = sqlite3_changes(database) > 0
            if inserted {
                try trimTelemetry()
                lastPacketID = packet.packetID
            }
            try execute("COMMIT;")
            return inserted ? .inserted : .duplicate
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func snapshot() throws -> GatewayQueueSnapshot {
        var counts: [PacketPriority: Int] = [:]
        for priority in PacketPriority.allCases {
            counts[priority] = try scalarInt(
                "SELECT COUNT(*) FROM packets WHERE server_acked_at IS NULL AND priority = \(priority.rawValue);"
            )
        }
        return GatewayQueueSnapshot(counts: counts, lastPacketID: lastPacketID)
    }

    public func nextPending() throws -> TransportPacket? {
        let sql = """
            SELECT payload_blob FROM packets
            WHERE server_acked_at IS NULL
            ORDER BY priority ASC, local_id ASC LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError() }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0, let bytes = sqlite3_column_blob(statement, 0) else {
            throw GatewayQueueError.sqlite("Stored packet payload is empty.")
        }
        return try TransportPacket.decodeEnvelope(Data(bytes: bytes, count: length))
    }

    public func claimNext(now: Date = Date(), leaseSeconds: TimeInterval = 30) throws -> UploadQueueClaim? {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let sql = """
                SELECT local_id, payload_blob, attempt_count FROM packets
                WHERE server_acked_at IS NULL AND terminal_error_code IS NULL
                  AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                  AND (leased_until IS NULL OR leased_until <= ?)
                ORDER BY priority ASC, local_id ASC LIMIT 1;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw sqliteError() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { try execute("COMMIT;"); return nil }
            guard step == SQLITE_ROW else { throw sqliteError() }
            let localID = sqlite3_column_int64(statement, 0)
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0, let bytes = sqlite3_column_blob(statement, 1) else {
                throw GatewayQueueError.sqlite("Stored packet payload is empty.")
            }
            let packet = try TransportPacket.decodeEnvelope(Data(bytes: bytes, count: length))
            let attempt = Int(sqlite3_column_int(statement, 2))
            try execute("UPDATE packets SET leased_until = \(now.addingTimeInterval(max(1, leaseSeconds)).timeIntervalSince1970) WHERE local_id = \(localID);")
            try execute("COMMIT;")
            return UploadQueueClaim(localID: localID, packet: packet, attemptCount: attempt)
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    public func markUploaded(localID: Int64, at date: Date = Date()) throws {
        try execute("UPDATE packets SET server_acked_at = \(date.timeIntervalSince1970), payload_blob = X'', payload_scrubbed_at = \(date.timeIntervalSince1970), leased_until = NULL, next_attempt_at = NULL WHERE local_id = \(localID);")
    }

    public func completeUpload(
        localID: Int64,
        localSessionID: String,
        sequence: Int,
        marksSessionEnding: Bool,
        at date: Date = Date()
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try markUploaded(localID: localID, at: date)
            try updateBindingSequence(localSessionID: localSessionID, sequence: sequence)
            if marksSessionEnding { try markBindingEnding(localSessionID: localSessionID) }
            try execute("COMMIT;")
        } catch { try? execute("ROLLBACK;"); throw error }
    }

    public func scheduleRetry(localID: Int64, attemptCount: Int, nextAttemptAt: Date) throws {
        try execute("UPDATE packets SET attempt_count = \(attemptCount), next_attempt_at = \(nextAttemptAt.timeIntervalSince1970), leased_until = NULL WHERE local_id = \(localID);")
    }

    public func markTerminal(localID: Int64, code: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE packets SET terminal_error_code = ?, leased_until = NULL WHERE local_id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        bind(code, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, localID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    public func saveBinding(_ binding: SessionBinding) throws {
        let sql = """
            INSERT INTO session_bindings(local_session_id, server_session_id, credential_account, expires_at, state, last_sequence)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(local_session_id) DO UPDATE SET server_session_id=excluded.server_session_id,
              credential_account=excluded.credential_account, expires_at=excluded.expires_at,
              state=session_bindings.state, last_sequence=MAX(session_bindings.last_sequence, excluded.last_sequence);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        bind(binding.localSessionID, to: 1, in: statement)
        bind(binding.serverSessionID, to: 2, in: statement)
        bind(binding.credentialAccount, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, binding.expiresAt.timeIntervalSince1970)
        bind(binding.state, to: 5, in: statement)
        sqlite3_bind_int64(statement, 6, sqlite3_int64(binding.lastSequence))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    public func binding(for localSessionID: String) throws -> SessionBinding? {
        let sql = "SELECT server_session_id, credential_account, expires_at, state, last_sequence FROM session_bindings WHERE local_session_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        bind(localSessionID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return SessionBinding(
            localSessionID: localSessionID,
            serverSessionID: String(cString: sqlite3_column_text(statement, 0)),
            credentialAccount: String(cString: sqlite3_column_text(statement, 1)),
            expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            state: String(cString: sqlite3_column_text(statement, 3)),
            lastSequence: Int(sqlite3_column_int64(statement, 4))
        )
    }

    public func updateBindingSequence(localSessionID: String, sequence: Int) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE session_bindings SET last_sequence=MAX(last_sequence, ?) WHERE local_session_id=?;", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(sequence))
        bind(localSessionID, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    public func markBindingEnding(localSessionID: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE session_bindings SET state='ending' WHERE local_session_id=?;", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        bind(localSessionID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    public func markBindingEnded(localSessionID: String, at date: Date = Date()) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE session_bindings SET state='ended', finalized_at=? WHERE local_session_id=?;", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        bind(localSessionID, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    public func bindingsAwaitingFinalization() throws -> [SessionBinding] {
        let sql = "SELECT local_session_id, server_session_id, credential_account, expires_at, state, last_sequence FROM session_bindings WHERE state='ending';"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        var values: [SessionBinding] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(SessionBinding(
                localSessionID: String(cString: sqlite3_column_text(statement, 0)),
                serverSessionID: String(cString: sqlite3_column_text(statement, 1)),
                credentialAccount: String(cString: sqlite3_column_text(statement, 2)),
                expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                state: String(cString: sqlite3_column_text(statement, 4)),
                lastSequence: Int(sqlite3_column_int64(statement, 5))
            ))
        }
        return values
    }

    public func allBindings() throws -> [SessionBinding] {
        try readBindings(whereClause: "")
    }

    public func applyReconciliation(_ item: ReconciledRunSession, at date: Date = Date()) throws {
        var statement: OpaquePointer?
        let sql = "UPDATE session_bindings SET server_state=?, state=CASE WHEN ?='active' THEN state ELSE ? END, last_sequence=MAX(last_sequence, ?), last_reconciled_at=? WHERE local_session_id=?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        bind(item.status.rawValue, to: 1, in: statement)
        bind(item.status.rawValue, to: 2, in: statement)
        bind(item.status.rawValue, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, sqlite3_int64(item.lastSequence))
        sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        bind(item.clientSessionID, to: 6, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    public func purgeTombstones(olderThan date: Date) throws {
        try execute("DELETE FROM packets WHERE server_acked_at IS NOT NULL AND server_acked_at < \(date.timeIntervalSince1970);")
    }

    public func verifyIntegrity() throws { try Self.verifyIntegrity(database) }

    public func canFinalize(localSessionID: String) throws -> Bool {
        var statement: OpaquePointer?
        let sql = """
            SELECT
              SUM(CASE WHEN terminal_error_code IS NULL THEN 1 ELSE 0 END),
              SUM(CASE WHEN terminal_error_code IS NOT NULL AND priority = 0 THEN 1 ELSE 0 END)
            FROM packets WHERE session_id = ? AND server_acked_at IS NULL;
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        bind(localSessionID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_int(statement, 0) == 0 && sqlite3_column_int(statement, 1) == 0
    }

    public func pendingSummary(now: Date = Date()) throws -> PendingUploadSummary {
        let retryable = try scalarInt("SELECT COUNT(*) FROM packets WHERE server_acked_at IS NULL AND terminal_error_code IS NULL;")
        let terminal = try scalarInt("SELECT COUNT(*) FROM packets WHERE server_acked_at IS NULL AND terminal_error_code IS NOT NULL;")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT MIN(next_attempt_at) FROM packets WHERE server_acked_at IS NULL AND terminal_error_code IS NULL;", -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        let hasRow = sqlite3_step(statement) == SQLITE_ROW
        let next = hasRow && sqlite3_column_type(statement, 0) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)) : nil
        return PendingUploadSummary(retryable: retryable, terminal: terminal, nextAttemptAt: next)
    }

    private func trimTelemetry() throws {
        let count = try scalarInt(
            "SELECT COUNT(*) FROM packets WHERE server_acked_at IS NULL AND priority = \(PacketPriority.telemetry.rawValue);"
        )
        let excess = count - telemetryLimit
        guard excess > 0 else { return }
        try execute("""
            DELETE FROM packets WHERE local_id IN (
                SELECT local_id FROM packets
                WHERE server_acked_at IS NULL AND priority = \(PacketPriority.telemetry.rawValue)
                ORDER BY local_id ASC LIMIT \(excess)
            );
            """)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws { try Self.execute(database, sql) }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite operation failed."
            sqlite3_free(errorMessage)
            throw GatewayQueueError.sqlite(message)
        }
    }

    private static func addColumnIfNeeded(_ database: OpaquePointer, table: String, name: String, definition: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw GatewayQueueError.sqlite("Unable to inspect SQLite schema.")
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1), String(cString: value) == name { return }
        }
        try execute(database, "ALTER TABLE \(table) ADD COLUMN \(name) \(definition);")
    }

    private func readBindings(whereClause: String) throws -> [SessionBinding] {
        let sql = "SELECT local_session_id, server_session_id, credential_account, expires_at, state, last_sequence FROM session_bindings \(whereClause);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        defer { sqlite3_finalize(statement) }
        var values: [SessionBinding] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(SessionBinding(localSessionID: String(cString: sqlite3_column_text(statement, 0)), serverSessionID: String(cString: sqlite3_column_text(statement, 1)), credentialAccount: String(cString: sqlite3_column_text(statement, 2)), expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), state: String(cString: sqlite3_column_text(statement, 4)), lastSequence: Int(sqlite3_column_int64(statement, 5))))
        }
        return values
    }

    private static func verifyIntegrity(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check;", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw GatewayQueueError.integrityFailed("Unable to run SQLite integrity check.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0), String(cString: value) == "ok" else {
            throw GatewayQueueError.integrityFailed("SQLite integrity check failed; queue remains untouched and acknowledgements are disabled.")
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func sqliteError() -> GatewayQueueError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

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

public enum GatewayQueueError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message), .sqlite(let message): return message
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

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func sqliteError() -> GatewayQueueError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

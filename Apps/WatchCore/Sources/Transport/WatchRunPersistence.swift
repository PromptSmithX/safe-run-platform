import Foundation
import SafeRunDomain

public struct WatchQueueSnapshot: Equatable, Sendable {
    public let counts: [PacketPriority: Int]
    public let storageError: String?
    public var totalCount: Int { counts.values.reduce(0, +) }
}

public struct PersistedWatchPacket: Codable, Equatable, Sendable {
    public let packet: TransportPacket
    public let enqueuedAt: Date
}

public struct WatchRunPersistenceDiagnostics: Equatable, Sendable {
    public let storageError: String?
    public let recoveryReason: String?
    public let outboxCount: Int
}

public actor WatchRunPersistence {
    private struct State: Codable {
        var version = 2
        var activeRun: WatchRunRecoverySnapshot?
        var outbox: [PersistedWatchPacket] = []
        var recoveryReason: String?
        var recoverySyncQueued: Bool?
    }
    private struct LegacyQueue: Codable { let version: Int; let entries: [PersistedWatchPacket] }
    private struct LegacyRun: Codable { let sessionID: String?; let lastIssued: Int }

    private let fileURL: URL
    private let telemetryLimit: Int
    private var state: State
    private var storageError: String?

    public init(fileURL: URL, legacyQueueURL: URL? = nil, legacyRunURL: URL? = nil, telemetryLimit: Int = 120) {
        self.fileURL = fileURL; self.telemetryLimit = max(1, telemetryLimit)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let decoded = try SafeRunJSON.makeDecoder().decode(State.self, from: Data(contentsOf: fileURL))
                guard decoded.version == 2 else { throw WatchRunPersistenceError.unsupportedVersion }
                state = decoded
            } else {
                state = try Self.migrate(queueURL: legacyQueueURL, runURL: legacyRunURL)
                try Self.write(state, to: fileURL)
                Self.archiveLegacy([legacyQueueURL, legacyRunURL])
            }
        } catch {
            Self.archiveCorrupt(fileURL)
            if let legacyQueueURL { Self.archiveCorrupt(legacyQueueURL) }
            if let legacyRunURL { Self.archiveCorrupt(legacyRunURL) }
            state = State(recoveryReason: "local_state_unrecoverable")
            storageError = error.localizedDescription
        }
    }

    public func beginRunAndEnqueueStarted(at date: Date, configuration: RunnerSafetyConfigurationEnvelope?) throws -> TransportPacket {
        if state.activeRun != nil { throw WatchRunPersistenceError.runAlreadyActive }
        let sessionID = UUID().uuidString
        let payload = EventPayload(eventType: .sessionStarted, severity: .info)
        let packet = try makeEvent(sessionID: sessionID, sequence: 1, date: date, payload: payload)
        try mutate { draft in
            draft.activeRun = WatchRunRecoverySnapshot(localSessionID: sessionID, startedAt: date, lastIssuedSequence: 1, appliedConfiguration: configuration)
            draft.outbox.append(.init(packet: packet, enqueuedAt: date))
        }
        return packet
    }

    public func beginRecoveredRun(at date: Date, configuration: RunnerSafetyConfigurationEnvelope?) throws -> WatchRunRecoverySnapshot {
        if let active = state.activeRun { return active }
        let snapshot = WatchRunRecoverySnapshot(localSessionID: UUID().uuidString, startedAt: date, lastIssuedSequence: 0, appliedConfiguration: configuration)
        try mutate { draft in draft.activeRun = snapshot; draft.recoveryReason = "local_state_unrecoverable" }
        return snapshot
    }

    public func alignRecoveredStartDate(_ date: Date) throws -> WatchRunRecoverySnapshot {
        guard let active = state.activeRun else { throw WatchRunPersistenceError.noActiveRun }
        let aligned = WatchRunRecoverySnapshot(localSessionID: active.localSessionID, startedAt: date, lastIssuedSequence: active.lastIssuedSequence, appliedConfiguration: active.appliedConfiguration, checkIn: active.checkIn)
        try mutate { $0.activeRun = aligned }
        return aligned
    }

    public func enqueueTelemetry(_ payload: TelemetryPayload, at date: Date = Date(), packetID: UUID = UUID()) throws -> TransportPacket {
        try issueAndEnqueue(at: date) { sessionID, sequence in
            let envelope = TelemetryEnvelope(packetID: packetID, sessionID: sessionID, sequence: sequence, watchTimestamp: date, payload: payload)
            return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
        }
    }

    public func enqueueEvent(_ payload: EventPayload, at date: Date = Date(), packetID: UUID = UUID()) throws -> TransportPacket {
        try issueAndEnqueue(at: date) { sessionID, sequence in
            try makeEvent(sessionID: sessionID, sequence: sequence, date: date, payload: payload, packetID: packetID)
        }
    }

    public func enqueueRecoveryStateSyncIfNeeded(at date: Date = Date()) throws -> TransportPacket? {
        guard state.activeRun != nil else { throw WatchRunPersistenceError.noActiveRun }
        guard state.recoverySyncQueued != true else { return nil }
        let payload = EventPayload(eventType: .stateSync, severity: .info)
        return try issueAndEnqueue(at: date, markRecoverySync: true) { sessionID, sequence in try makeEvent(sessionID: sessionID, sequence: sequence, date: date, payload: payload) }
    }

    public func saveCheckInAndEnqueueStarted(_ snapshot: PersistentCheckInSnapshot, evaluation: RuleEvaluationSnapshot, at date: Date) throws -> TransportPacket {
        guard state.activeRun?.checkIn == nil else { throw WatchRunPersistenceError.checkInAlreadyActive }
        let payload = EventPayload(eventID: snapshot.startedEventID, eventType: .checkInStarted, severity: .warning, ruleID: "high_hr_sustained_v1", incidentID: snapshot.incidentID, context: snapshot.context ?? EventContext(ruleEvaluation: evaluation))
        return try issueAndEnqueue(at: date, checkIn: snapshot) { sessionID, sequence in
            try makeEvent(sessionID: sessionID, sequence: sequence, date: date, payload: payload)
        }
    }

    public func resolveCheckInAndEnqueueEvent(type: SafetyEventType, severity: IncidentSeverity, eventID: UUID, at date: Date, context: EventContext?) throws -> TransportPacket {
        guard let checkIn = state.activeRun?.checkIn, checkIn.terminalOutcome == nil else { throw WatchRunPersistenceError.noActiveCheckIn }
        let terminal = PersistentCheckInSnapshot(incidentID: checkIn.incidentID, startedEventID: checkIn.startedEventID, deadline: checkIn.deadline, context: checkIn.context, terminalEventID: eventID, terminalOutcome: type.rawValue)
        let payload = EventPayload(eventID: eventID, eventType: type, severity: severity, ruleID: "high_hr_sustained_v1", incidentID: checkIn.incidentID, context: context ?? checkIn.context)
        return try issueAndEnqueue(at: date, checkIn: terminal) { sessionID, sequence in
            try makeEvent(sessionID: sessionID, sequence: sequence, date: date, payload: payload)
        }
    }

    public func supersedeCheckInAndEnqueueSOS(eventID: UUID, incidentID: UUID, at date: Date, context: EventContext?) throws -> TransportPacket {
        let terminal = state.activeRun?.checkIn.map { PersistentCheckInSnapshot(incidentID: $0.incidentID, startedEventID: $0.startedEventID, deadline: $0.deadline, context: $0.context, terminalEventID: eventID, terminalOutcome: "superseded_by_manual_sos") }
        let payload = EventPayload(eventID: eventID, eventType: .manualSOS, severity: .critical, incidentID: incidentID, context: context)
        return try issueAndEnqueue(at: date, checkIn: terminal) { sessionID, sequence in
            try makeEvent(sessionID: sessionID, sequence: sequence, date: date, payload: payload)
        }
    }

    public func enqueueSessionEndedAndComplete(at date: Date, context: EventContext?) throws -> TransportPacket {
        guard let active = state.activeRun else { throw WatchRunPersistenceError.noActiveRun }
        let sequence = active.lastIssuedSequence + 1
        let payload = EventPayload(eventType: .sessionEnded, severity: .info, context: context)
        let packet = try makeEvent(sessionID: active.localSessionID, sequence: sequence, date: date, payload: payload)
        try mutate { draft in
            draft.outbox.append(.init(packet: packet, enqueuedAt: date))
            draft.activeRun = nil
            draft.recoverySyncQueued = nil
        }
        return packet
    }

    private func issueAndEnqueue(at date: Date, checkIn: PersistentCheckInSnapshot? = nil, markRecoverySync: Bool = false, makePacket: (String, Int) throws -> TransportPacket) throws -> TransportPacket {
        guard let active = state.activeRun, active.lastIssuedSequence < Int.max else { throw WatchRunPersistenceError.noActiveRun }
        let sequence = active.lastIssuedSequence + 1
        let packet = try makePacket(active.localSessionID, sequence)
        try mutate { draft in
            draft.activeRun = WatchRunRecoverySnapshot(localSessionID: active.localSessionID, startedAt: active.startedAt, lastIssuedSequence: sequence, appliedConfiguration: active.appliedConfiguration, checkIn: checkIn ?? active.checkIn)
            if !draft.outbox.contains(where: { $0.packet.packetID == packet.packetID }) {
                draft.outbox.append(PersistedWatchPacket(packet: packet, enqueuedAt: date))
                Self.trimTelemetry(&draft.outbox, limit: telemetryLimit)
            }
            if markRecoverySync { draft.recoverySyncQueued = true }
        }
        return packet
    }

    public func acknowledge(packetID: UUID) throws {
        try mutate { $0.outbox.removeAll { $0.packet.packetID == packetID } }
    }

    public func recover() -> WatchRunRecoverySnapshot? { state.activeRun }
    public func nextPacket() -> TransportPacket? { state.outbox.sorted { $0.packet.priority == $1.packet.priority ? ($0.packet.sequence < $1.packet.sequence) : ($0.packet.priority < $1.packet.priority) }.first?.packet }
    public func nextPacket(reorderTelemetry: Bool) -> TransportPacket? {
        let ordered = state.outbox.sorted { $0.packet.priority == $1.packet.priority ? ($0.packet.sequence < $1.packet.sequence) : ($0.packet.priority < $1.packet.priority) }
        guard reorderTelemetry, ordered.first?.packet.priority == .telemetry else { return ordered.first?.packet }
        return ordered.filter { $0.packet.priority == .telemetry }.last?.packet
    }
    public func queuedPackets() -> [TransportPacket] { state.outbox.sorted { $0.packet.sequence < $1.packet.sequence }.map(\.packet) }
    public func snapshot() -> WatchQueueSnapshot {
        var counts: [PacketPriority: Int] = [:]
        for priority in PacketPriority.allCases { counts[priority] = state.outbox.filter { $0.packet.priority == priority }.count }
        return WatchQueueSnapshot(counts: counts, storageError: storageError ?? (state.recoveryReason == "local_state_unrecoverable" ? state.recoveryReason : nil))
    }
    public func diagnostics() -> WatchRunPersistenceDiagnostics { .init(storageError: storageError, recoveryReason: state.recoveryReason, outboxCount: state.outbox.count) }

    private func mutate(_ body: (inout State) throws -> Void) throws {
        var draft = state
        try body(&draft)
        do { try Self.write(draft, to: fileURL); state = draft; storageError = nil }
        catch { storageError = error.localizedDescription; throw error }
    }

    private static func migrate(queueURL: URL?, runURL: URL?) throws -> State {
        var result = State(recoveryReason: "migrated_v1")
        if let queueURL, FileManager.default.fileExists(atPath: queueURL.path) {
            let legacy = try SafeRunJSON.makeDecoder().decode(LegacyQueue.self, from: Data(contentsOf: queueURL))
            result.outbox = Dictionary(grouping: legacy.entries, by: { $0.packet.packetID }).compactMap { $0.value.first }
        }
        if let runURL, FileManager.default.fileExists(atPath: runURL.path) {
            let legacy = try SafeRunJSON.makeDecoder().decode(LegacyRun.self, from: Data(contentsOf: runURL))
            if let id = legacy.sessionID {
                let maximum = max(legacy.lastIssued, result.outbox.filter { $0.packet.sessionID == id }.map(\.packet.sequence).max() ?? 0)
                result.activeRun = WatchRunRecoverySnapshot(localSessionID: id, startedAt: Date(), lastIssuedSequence: maximum)
            }
        }
        return result
    }

    private static func trimTelemetry(_ entries: inout [PersistedWatchPacket], limit: Int) {
        let telemetry = entries.indices.filter { entries[$0].packet.priority == .telemetry }
        for index in telemetry.prefix(max(0, telemetry.count - limit)).reversed() { entries.remove(at: index) }
    }
    private static func write(_ state: State, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SafeRunJSON.makeEncoder().encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    private static func archiveLegacy(_ urls: [URL?]) { for case let url? in urls where FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("migrated-\(Int(Date().timeIntervalSince1970))")) } }
    private static func archiveCorrupt(_ url: URL) { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")) } }

    private func makeEvent(sessionID: String, sequence: Int, date: Date, payload: EventPayload, packetID: UUID = UUID()) throws -> TransportPacket {
        let envelope = EventEnvelope(packetID: packetID, sessionID: sessionID, sequence: sequence, watchTimestamp: date, payload: payload)
        return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
    }
}

public enum WatchRunPersistenceError: Error { case runAlreadyActive, noActiveRun, checkInAlreadyActive, noActiveCheckIn, unsupportedVersion }

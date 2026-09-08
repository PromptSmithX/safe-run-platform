import Foundation
import SafeRunDomain

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
                guard decoded.version == 2 else { throw QueueStorageError.unsupportedVersion }
                state = decoded
            } else {
                state = try Self.migrate(queueURL: legacyQueueURL, runURL: legacyRunURL)
                try Self.write(state, to: fileURL)
                Self.archiveLegacy([legacyQueueURL, legacyRunURL])
            }
        } catch {
            Self.archiveCorrupt(fileURL)
            state = State(recoveryReason: "local_state_unrecoverable")
            storageError = error.localizedDescription
        }
    }

    public func beginRun(at date: Date, configuration: RunnerSafetyConfigurationEnvelope?) throws -> WatchRunRecoverySnapshot {
        if let active = state.activeRun { return active }
        let snapshot = WatchRunRecoverySnapshot(localSessionID: UUID().uuidString, startedAt: date, lastIssuedSequence: 0, appliedConfiguration: configuration)
        try mutate { $0.activeRun = snapshot }
        return snapshot
    }

    public func issueAndEnqueue(at date: Date = Date(), makePacket: (String, Int) throws -> TransportPacket) throws -> TransportPacket {
        guard let active = state.activeRun, active.lastIssuedSequence < Int.max else { throw LocalRunSessionError.invalidState }
        let sequence = active.lastIssuedSequence + 1
        let packet = try makePacket(active.localSessionID, sequence)
        try mutate { draft in
            draft.activeRun = WatchRunRecoverySnapshot(localSessionID: active.localSessionID, startedAt: active.startedAt, lastIssuedSequence: sequence, appliedConfiguration: active.appliedConfiguration, checkIn: active.checkIn)
            if !draft.outbox.contains(where: { $0.packet.packetID == packet.packetID }) {
                draft.outbox.append(PersistedWatchPacket(packet: packet, enqueuedAt: date))
                Self.trimTelemetry(&draft.outbox, limit: telemetryLimit)
            }
        }
        return packet
    }

    public func enqueueEvent(at date: Date = Date(), makePacket: (String, Int) throws -> TransportPacket) throws -> TransportPacket { try issueAndEnqueue(at: date, makePacket: makePacket) }
    public func enqueueTelemetry(at date: Date = Date(), makePacket: (String, Int) throws -> TransportPacket) throws -> TransportPacket { try issueAndEnqueue(at: date, makePacket: makePacket) }

    public func acknowledge(packetID: UUID) throws {
        try mutate { $0.outbox.removeAll { $0.packet.packetID == packetID } }
    }

    public func saveCheckIn(_ snapshot: PersistentCheckInSnapshot?) throws {
        guard let active = state.activeRun else { throw LocalRunSessionError.invalidState }
        try mutate { $0.activeRun = WatchRunRecoverySnapshot(localSessionID: active.localSessionID, startedAt: active.startedAt, lastIssuedSequence: active.lastIssuedSequence, appliedConfiguration: active.appliedConfiguration, checkIn: snapshot) }
    }

    public func completeRun() throws { try mutate { $0.activeRun = nil } }
    public func recover() -> WatchRunRecoverySnapshot? { state.activeRun }
    public func nextPacket() -> TransportPacket? { state.outbox.sorted { $0.packet.priority == $1.packet.priority ? ($0.packet.sequence < $1.packet.sequence) : ($0.packet.priority < $1.packet.priority) }.first?.packet }
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
}

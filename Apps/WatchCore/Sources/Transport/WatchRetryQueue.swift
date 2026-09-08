import Foundation
import SafeRunDomain

public struct WatchQueueSnapshot: Equatable, Sendable {
    public let counts: [PacketPriority: Int]
    public let storageError: String?

    public var totalCount: Int { counts.values.reduce(0, +) }

    public init(counts: [PacketPriority: Int], storageError: String?) {
        self.counts = counts
        self.storageError = storageError
    }
}

public actor WatchRetryQueue {
    private struct Entry: Codable, Equatable {
        let packet: TransportPacket
        let enqueuedAt: Date
    }

    private struct State: Codable {
        let version: Int
        var entries: [Entry]
    }

    private let fileURL: URL
    private let telemetryLimit: Int
    private var state = State(version: 1, entries: [])
    private var storageError: String?

    public init(fileURL: URL, telemetryLimit: Int = 120) {
        self.fileURL = fileURL
        self.telemetryLimit = max(1, telemetryLimit)
        let loaded = Self.loadFromDisk(fileURL: fileURL)
        state = loaded.state
        storageError = loaded.error
    }

    @discardableResult
    public func enqueue(_ packet: TransportPacket, at date: Date = Date()) throws -> Bool {
        guard !state.entries.contains(where: { $0.packet.packetID == packet.packetID }) else {
            return false
        }

        let oldState = state
        state.entries.append(Entry(packet: packet, enqueuedAt: date))
        trimTelemetryIfNeeded()
        do {
            try persist()
            storageError = nil
            return true
        } catch {
            state = oldState
            storageError = error.localizedDescription
            throw error
        }
    }

    public func next() -> TransportPacket? {
        state.entries.sorted(by: Self.precedes).first?.packet
    }

    @discardableResult
    public func acknowledge(packetID: UUID) throws -> Bool {
        guard let index = state.entries.firstIndex(where: { $0.packet.packetID == packetID }) else {
            return false
        }
        let oldState = state
        state.entries.remove(at: index)
        do {
            try persist()
            storageError = nil
            return true
        } catch {
            state = oldState
            storageError = error.localizedDescription
            throw error
        }
    }

    public func snapshot() -> WatchQueueSnapshot {
        var counts: [PacketPriority: Int] = [:]
        for priority in PacketPriority.allCases {
            counts[priority] = state.entries.filter { $0.packet.priority == priority }.count
        }
        return WatchQueueSnapshot(counts: counts, storageError: storageError)
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.packet.priority != rhs.packet.priority {
            return lhs.packet.priority < rhs.packet.priority
        }
        if lhs.packet.sequence != rhs.packet.sequence {
            return lhs.packet.sequence < rhs.packet.sequence
        }
        return lhs.enqueuedAt < rhs.enqueuedAt
    }

    private func trimTelemetryIfNeeded() {
        let telemetry = state.entries
            .enumerated()
            .filter { $0.element.packet.priority == .telemetry }
            .sorted { Self.precedes($0.element, $1.element) }
        let excess = telemetry.count - telemetryLimit
        guard excess > 0 else { return }
        let indices = telemetry.prefix(excess).map(\.offset).sorted(by: >)
        for index in indices { state.entries.remove(at: index) }
    }

    private static func loadFromDisk(fileURL: URL) -> (state: State, error: String?) {
        let empty = State(version: 1, entries: [])
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (empty, nil) }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try SafeRunJSON.makeDecoder().decode(State.self, from: data)
            guard decoded.version == 1 else { throw QueueStorageError.unsupportedVersion }
            return (decoded, nil)
        } catch {
            let suffix = String(Int(Date().timeIntervalSince1970))
            let corruptURL = fileURL.appendingPathExtension("corrupt-\(suffix)")
            try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
            return (empty, error.localizedDescription)
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try SafeRunJSON.makeEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }
}

public enum QueueStorageError: Error, Equatable {
    case unsupportedVersion
}

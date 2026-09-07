import Foundation

public struct PacketSequence: Codable, Equatable, Sendable {
    public private(set) var lastIssued: Int

    public init(lastIssued: Int = 0) {
        precondition(lastIssued >= 0, "Last issued sequence cannot be negative.")
        self.lastIssued = lastIssued
    }

    @discardableResult
    public mutating func next() -> Int {
        precondition(lastIssued < Int.max, "Packet sequence exhausted.")
        lastIssued += 1
        return lastIssued
    }
}


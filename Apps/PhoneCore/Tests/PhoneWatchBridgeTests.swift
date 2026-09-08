import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunPhoneCore

@MainActor
final class PhoneWatchBridgeTests: XCTestCase {
    func testRepliesQueuedOnlyAfterPacketIsDurableAndThenDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try SQLiteGatewayQueue(
            databaseURL: directory.appendingPathComponent("gateway.sqlite")
        )
        let bridge = PhoneWatchBridge(queue: queue)
        let envelope = TelemetryEnvelope(
            sessionID: "session",
            sequence: 1,
            watchTimestamp: Date(),
            payload: TelemetryPayload(elapsedSeconds: 1)
        )
        let message = try SafeRunJSON.makeEncoder().encode(envelope)

        let firstData = await bridge.processMessageData(message)
        let durableSnapshot = try await queue.snapshot()
        let secondData = await bridge.processMessageData(message)
        let first = try SafeRunJSON.makeDecoder().decode(TransportAcknowledgement.self, from: firstData)
        let second = try SafeRunJSON.makeDecoder().decode(TransportAcknowledgement.self, from: secondData)

        XCTAssertEqual(first.status, .queued)
        XCTAssertEqual(durableSnapshot.totalCount, 1)
        XCTAssertEqual(second.status, .duplicate)
    }

    func testInvalidEnvelopeIsRejectedWithoutPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try SQLiteGatewayQueue(
            databaseURL: directory.appendingPathComponent("gateway.sqlite")
        )
        let bridge = PhoneWatchBridge(queue: queue)

        let replyData = await bridge.processMessageData(Data("not-json".utf8))
        let reply = try SafeRunJSON.makeDecoder().decode(TransportAcknowledgement.self, from: replyData)
        let snapshot = try await queue.snapshot()

        XCTAssertEqual(reply.status, .rejected)
        XCTAssertEqual(reply.errorCode, "invalid_envelope")
        XCTAssertEqual(snapshot.totalCount, 0)
    }
}

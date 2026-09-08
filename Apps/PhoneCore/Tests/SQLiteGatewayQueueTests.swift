import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunPhoneCore

final class SQLiteGatewayQueueTests: XCTestCase {
    func testInsertDuplicateAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gateway.sqlite")
        let packet = try makePacket(sequence: 1)
        let queue = try SQLiteGatewayQueue(databaseURL: url)

        let firstResult = try await queue.accept(packet)
        let duplicateResult = try await queue.accept(packet)
        let firstSnapshot = try await queue.snapshot()
        XCTAssertEqual(firstResult, .inserted)
        XCTAssertEqual(duplicateResult, .duplicate)
        XCTAssertEqual(firstSnapshot.totalCount, 1)

        let reopened = try SQLiteGatewayQueue(databaseURL: url)
        let reopenedSnapshot = try await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot.totalCount, 1)
    }

    func testTelemetryLimitDoesNotRemoveCriticalPacket() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try SQLiteGatewayQueue(
            databaseURL: directory.appendingPathComponent("gateway.sqlite"),
            telemetryLimit: 2
        )
        try await queue.accept(makePacket(sequence: 1, critical: true))
        for sequence in 2...4 { try await queue.accept(makePacket(sequence: sequence)) }
        let snapshot = try await queue.snapshot()

        XCTAssertEqual(snapshot.counts[.critical], 1)
        XCTAssertEqual(snapshot.counts[.telemetry], 2)
    }

    func testNextPendingReturnsCriticalBeforeTelemetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try SQLiteGatewayQueue(
            databaseURL: directory.appendingPathComponent("gateway.sqlite")
        )
        try await queue.accept(makePacket(sequence: 1))
        let critical = try makePacket(sequence: 2, critical: true)
        try await queue.accept(critical)

        let next = try await queue.nextPending()
        XCTAssertEqual(next?.packetID, critical.packetID)
        XCTAssertEqual(next?.priority, .critical)
    }

    func testLeaseRetryTerminalAndBindingPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gateway.sqlite")
        let queue = try SQLiteGatewayQueue(databaseURL: url)
        let packet = try makePacket(sequence: 1)
        try await queue.accept(packet)
        let initialClaim = try await queue.claimNext(now: Date(timeIntervalSince1970: 100))
        let claim = try XCTUnwrap(initialClaim)
        let leasedClaim = try await queue.claimNext(now: Date(timeIntervalSince1970: 101))
        XCTAssertNil(leasedClaim)
        let expiredLeaseClaim = try await queue.claimNext(now: Date(timeIntervalSince1970: 131))
        XCTAssertNotNil(expiredLeaseClaim)
        try await queue.scheduleRetry(localID: claim.localID, attemptCount: 1, nextAttemptAt: Date(timeIntervalSince1970: 200))
        let earlyClaim = try await queue.claimNext(now: Date(timeIntervalSince1970: 199))
        XCTAssertNil(earlyClaim)
        let retryClaim = try await queue.claimNext(now: Date(timeIntervalSince1970: 200))
        let retry = try XCTUnwrap(retryClaim)
        try await queue.markTerminal(localID: retry.localID, code: "INVALID_SCHEMA")

        let binding = SessionBinding(
            localSessionID: "session", serverSessionID: UUID().uuidString,
            credentialAccount: "session.session", expiresAt: Date(timeIntervalSince1970: 500),
            state: .active, lastSequence: 1
        )
        try await queue.saveBinding(binding)
        let restored = try SQLiteGatewayQueue(databaseURL: url)
        let restoredBinding = try await restored.binding(for: "session")
        let summary = try await restored.pendingSummary()
        XCTAssertEqual(restoredBinding?.serverSessionID, binding.serverSessionID)
        XCTAssertEqual(summary.terminal, 1)
    }

    func testUploadedPayloadIsScrubbedButTombstoneStillDeduplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = try SQLiteGatewayQueue(databaseURL: directory.appendingPathComponent("gateway.sqlite"))
        let packet = try makePacket(sequence: 1)
        try await queue.accept(packet)
        let pendingClaim = try await queue.claimNext()
        let claim = try XCTUnwrap(pendingClaim)
        try await queue.markUploaded(localID: claim.localID, at: Date(timeIntervalSince1970: 100))
        let tombstone = try await queue.tombstone(packetID: packet.packetID)
        XCTAssertTrue(tombstone.exists); XCTAssertEqual(tombstone.payloadBytes, 0)
        let duplicate = try await queue.accept(packet)
        XCTAssertEqual(duplicate, .duplicate)
    }

    private func makePacket(sequence: Int, critical: Bool = false) throws -> TransportPacket {
        if critical {
            let envelope = EventEnvelope(
                sessionID: "session",
                sequence: sequence,
                watchTimestamp: Date(),
                payload: EventPayload(eventType: .manualSOS, severity: .critical)
            )
            return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
        }
        let envelope = TelemetryEnvelope(
            sessionID: "session",
            sequence: sequence,
            watchTimestamp: Date(),
            payload: TelemetryPayload(elapsedSeconds: sequence)
        )
        return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
    }
}

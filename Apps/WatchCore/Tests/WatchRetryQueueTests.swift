import Foundation
import SafeRunDomain
import WatchConnectivity
import XCTest
@testable import SafeRunWatchCore

final class WatchRetryQueueTests: XCTestCase {
    func testQueuePersistsDeduplicatesAndOrdersPriority() async throws {
        let url = temporaryURL("queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = WatchRetryQueue(fileURL: url)
        let telemetry = try packet(sequence: 1, kind: .telemetry)
        let critical = try packet(sequence: 2, kind: .event, critical: true)

        let insertedTelemetry = try await queue.enqueue(telemetry)
        let duplicateTelemetry = try await queue.enqueue(telemetry)
        let insertedCritical = try await queue.enqueue(critical)
        XCTAssertTrue(insertedTelemetry)
        XCTAssertFalse(duplicateTelemetry)
        XCTAssertTrue(insertedCritical)
        let firstNext = await queue.next()
        XCTAssertEqual(firstNext?.packetID, critical.packetID)

        let restored = WatchRetryQueue(fileURL: url)
        let restoredSnapshot = await restored.snapshot()
        let restoredNext = await restored.next()
        XCTAssertEqual(restoredSnapshot.totalCount, 2)
        XCTAssertEqual(restoredNext?.packetID, critical.packetID)
    }

    func testOverflowOnlyRemovesOldestTelemetry() async throws {
        let url = temporaryURL("queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = WatchRetryQueue(fileURL: url, telemetryLimit: 2)
        let critical = try packet(sequence: 1, kind: .event, critical: true)
        try await queue.enqueue(critical)
        for sequence in 2...4 { try await queue.enqueue(packet(sequence: sequence, kind: .telemetry)) }

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.counts[.critical], 1)
        XCTAssertEqual(snapshot.counts[.telemetry], 2)
        XCTAssertEqual(snapshot.totalCount, 3)
    }

    func testAcknowledgementSurvivesRestart() async throws {
        let url = temporaryURL("queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = WatchRetryQueue(fileURL: url)
        let value = try packet(sequence: 1, kind: .telemetry)
        try await queue.enqueue(value)
        let acknowledged = try await queue.acknowledge(packetID: value.packetID)
        XCTAssertTrue(acknowledged)
        let restored = WatchRetryQueue(fileURL: url)
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.totalCount, 0)
    }

    func testCorruptQueueIsPreservedAndReported() async throws {
        let url = temporaryURL("queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: url)

        let queue = WatchRetryQueue(fileURL: url)
        let snapshot = await queue.snapshot()
        let files = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertNotNil(snapshot.storageError)
        XCTAssertTrue(files.contains { $0.lastPathComponent.contains(".corrupt-") })
    }

    private func packet(sequence: Int, kind: EnvelopeKind, critical: Bool = false) throws -> TransportPacket {
        if kind == .telemetry {
            let value = TelemetryEnvelope(
                sessionID: "session",
                sequence: sequence,
                watchTimestamp: Date(),
                payload: TelemetryPayload(elapsedSeconds: sequence)
            )
            return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(value))
        }
        let value = EventEnvelope(
            sessionID: "session",
            sequence: sequence,
            watchTimestamp: Date(),
            payload: EventPayload(
                eventType: critical ? .manualSOS : .sessionStarted,
                severity: critical ? .critical : .info
            )
        )
        return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(value))
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }
}

@MainActor
final class WatchConnectivityTransportTests: XCTestCase {
    func testPacketIsPersistedBeforeSendAndValidAckRemovesIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("queue.json")
        let queue = WatchRetryQueue(fileURL: fileURL)
        let session = FakeMessageSession()
        var existedAtSend = false
        session.onSend = { data, reply in
            existedAtSend = FileManager.default.fileExists(atPath: fileURL.path)
            do {
                let packet = try TransportPacket.decodeEnvelope(data)
                let ack = TransportAcknowledgement(packetID: packet.packetID, status: .queued)
                reply(try SafeRunJSON.makeEncoder().encode(ack))
            } catch {
                XCTFail("Unable to make acknowledgement: \(error)")
                reply(Data())
            }
        }
        let transport = WatchConnectivityTransport(queue: queue, session: session)
        transport.activate()
        try await transport.enqueue(makeTelemetryPacket())
        await Task.yield()
        await Task.yield()

        let snapshot = await queue.snapshot()
        XCTAssertTrue(existedAtSend)
        XCTAssertEqual(snapshot.totalCount, 0)
    }

    func testUnreachableSessionKeepsPacketWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = WatchRetryQueue(fileURL: directory.appendingPathComponent("queue.json"))
        let session = FakeMessageSession()
        session.isReachable = false
        let transport = WatchConnectivityTransport(queue: queue, session: session)
        transport.activate()

        try await transport.enqueue(makeTelemetryPacket())

        let snapshot = await queue.snapshot()
        XCTAssertEqual(session.sendCount, 0)
        XCTAssertEqual(snapshot.totalCount, 1)
    }

    func testWrongAcknowledgementDoesNotDeletePacket() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = WatchRetryQueue(fileURL: directory.appendingPathComponent("queue.json"))
        let session = FakeMessageSession()
        session.onSend = { _, reply in
            let ack = TransportAcknowledgement(packetID: UUID(), status: .queued)
            reply((try? SafeRunJSON.makeEncoder().encode(ack)) ?? Data())
        }
        let transport = WatchConnectivityTransport(queue: queue, session: session)
        transport.activate()

        try await transport.enqueue(makeTelemetryPacket())
        await Task.yield()
        await Task.yield()

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.totalCount, 1)
        XCTAssertEqual(transport.diagnostics.lastError, "invalid_acknowledgement")
    }

    private func makeTelemetryPacket() throws -> TransportPacket {
        let envelope = TelemetryEnvelope(
            sessionID: "session",
            sequence: 1,
            watchTimestamp: Date(),
            payload: TelemetryPayload(elapsedSeconds: 1)
        )
        return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
    }
}

@MainActor
private final class FakeMessageSession: WatchMessageSession {
    var activationState: WCSessionActivationState = .activated
    var isReachable = true
    var onSend: ((Data, @escaping (Data) -> Void) -> Void)?
    private(set) var sendCount = 0

    func activate(delegate: WCSessionDelegate) {}
    func sendMessageData(
        _ data: Data,
        replyHandler: @escaping (Data) -> Void,
        errorHandler: @escaping (Error) -> Void
    ) {
        sendCount += 1
        onSend?(data, replyHandler)
    }
}

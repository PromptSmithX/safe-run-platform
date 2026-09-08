import XCTest
import SafeRunDomain
@testable import SafeRunWatchCore

final class WatchRunPersistenceTests: XCTestCase {
    func testIssueAndEnqueuePersistsSequenceAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("watch-run-v2.json")
        let persistence = WatchRunPersistence(fileURL: url)
        let packet = try await persistence.beginRunAndEnqueueStarted(at: Date(timeIntervalSince1970: 1), configuration: nil)
        XCTAssertEqual(packet.sequence, 1)
        let reopened = WatchRunPersistence(fileURL: url)
        let recovered = await reopened.recover()
        let queued = await reopened.nextPacket()
        XCTAssertEqual(recovered?.lastIssuedSequence, 1)
        XCTAssertEqual(queued?.packetID, packet.packetID)
    }

    func testMigrationDeduplicatesAndContinuesMaximumSequence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queueURL = directory.appendingPathComponent("watch-packets.json")
        let runURL = directory.appendingPathComponent("active-run.json")
        let event = EventEnvelope(sessionID: "local", sequence: 7, watchTimestamp: Date(timeIntervalSince1970: 1), payload: EventPayload(eventType: .stateSync, severity: .info))
        let packet = try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(event))
        let entry = LegacyEntry(packet: packet, enqueuedAt: Date(timeIntervalSince1970: 2))
        try SafeRunJSON.makeEncoder().encode(LegacyQueue(version: 1, entries: [entry, entry])).write(to: queueURL)
        try SafeRunJSON.makeEncoder().encode(LegacyRun(sessionID: "local", lastIssued: 5)).write(to: runURL)
        let persistence = WatchRunPersistence(fileURL: directory.appendingPathComponent("watch-run-v2.json"), legacyQueueURL: queueURL, legacyRunURL: runURL)
        let recovered = await persistence.recover(); let packets = await persistence.queuedPackets()
        XCTAssertEqual(recovered?.lastIssuedSequence, 7)
        XCTAssertEqual(packets.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }

    func testDebugReorderNeverMovesTelemetryAheadOfCritical() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = WatchRunPersistence(fileURL: directory.appendingPathComponent("state.json"))
        _ = try await persistence.beginRunAndEnqueueStarted(at: Date(), configuration: nil)
        _ = try await persistence.enqueueTelemetry(TelemetryPayload(elapsedSeconds: 1))
        _ = try await persistence.enqueueEvent(EventPayload(eventType: .manualSOS, severity: .critical, incidentID: UUID()))
        try await persistence.acknowledge(packetID: (await persistence.queuedPackets())[0].packetID)
        let next = await persistence.nextPacket(reorderTelemetry: true)
        XCTAssertEqual(next?.priority, .critical)
    }
}

private struct LegacyEntry: Codable { let packet: TransportPacket; let enqueuedAt: Date }
private struct LegacyQueue: Codable { let version: Int; let entries: [LegacyEntry] }
private struct LegacyRun: Codable { let sessionID: String?; let lastIssued: Int }

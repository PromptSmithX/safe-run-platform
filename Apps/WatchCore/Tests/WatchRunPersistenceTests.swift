import XCTest
import SafeRunDomain
@testable import SafeRunWatchCore

final class WatchRunPersistenceTests: XCTestCase {
    func testIssueAndEnqueuePersistsSequenceAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("watch-run-v2.json")
        let persistence = WatchRunPersistence(fileURL: url)
        _ = try await persistence.beginRun(at: Date(timeIntervalSince1970: 1), configuration: nil)
        let packet = try await persistence.issueAndEnqueue { sessionID, sequence in
            let envelope = EventEnvelope(sessionID: sessionID, sequence: sequence, watchTimestamp: Date(timeIntervalSince1970: 2), payload: EventPayload(eventType: .sessionStarted, severity: .info))
            return try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
        }
        XCTAssertEqual(packet.sequence, 1)
        let reopened = WatchRunPersistence(fileURL: url)
        let recovered = await reopened.recover()
        let queued = await reopened.nextPacket()
        XCTAssertEqual(recovered?.lastIssuedSequence, 1)
        XCTAssertEqual(queued?.packetID, packet.packetID)
    }
}

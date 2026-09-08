import Foundation
import XCTest
@testable import SafeRunDomain

final class TransportContractTests: XCTestCase {
    func testTelemetryMetadataAndPriority() throws {
        let envelope = TelemetryEnvelope(
            sessionID: "local-session",
            sequence: 7,
            watchTimestamp: Date(timeIntervalSince1970: 1_800_000_000),
            payload: TelemetryPayload(elapsedSeconds: 42)
        )
        let data = try SafeRunJSON.makeEncoder().encode(envelope)
        let packet = try TransportPacket.decodeEnvelope(data)

        XCTAssertEqual(packet.packetID, envelope.packetID)
        XCTAssertEqual(packet.sessionID, "local-session")
        XCTAssertEqual(packet.sequence, 7)
        XCTAssertEqual(packet.priority, .telemetry)
    }

    func testCriticalEventGetsHighestPriority() throws {
        let envelope = EventEnvelope(
            sessionID: "local-session",
            sequence: 1,
            watchTimestamp: Date(),
            payload: EventPayload(eventType: .manualSOS, severity: .critical)
        )
        let packet = try TransportPacket.decodeEnvelope(
            SafeRunJSON.makeEncoder().encode(envelope)
        )
        XCTAssertEqual(packet.priority, .critical)
    }

    func testAcknowledgementUsesSnakeCaseAndRejectsWrongVersion() throws {
        let id = UUID()
        let data = try SafeRunJSON.makeEncoder().encode(
            TransportAcknowledgement(packetID: id, status: .queued)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["packet_id"] as? String, id.uuidString)

        let invalid = Data("{\"schema_version\":2,\"packet_id\":\"\(id.uuidString)\",\"status\":\"queued\"}".utf8)
        XCTAssertThrowsError(try SafeRunJSON.makeDecoder().decode(TransportAcknowledgement.self, from: invalid))
    }
}

import Foundation
import XCTest
@testable import SafeRunDomain

final class APIModelsTests: XCTestCase {
    func testReplacingSessionPreservesPacketIdentity() throws {
        let envelope = TelemetryEnvelope(sessionID: "local", sequence: 4, watchTimestamp: Date(), payload: TelemetryPayload(elapsedSeconds: 9))
        let packet = try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
        let mapped = try packet.replacingSessionID(with: "server")
        XCTAssertEqual(mapped.packetID, packet.packetID)
        XCTAssertEqual(mapped.sequence, packet.sequence)
        XCTAssertEqual(mapped.watchTimestamp, packet.watchTimestamp)
        XCTAssertEqual(mapped.sessionID, "server")
    }

    func testDeviceRegistrationUsesSnakeCaseContract() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let data = try SafeRunJSON.makeEncoder().encode(DeviceRegistrationRequest(
            deviceID: id, role: .caregiver, fcmToken: "fake-token", appVersion: "0.1.0"
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["device_id"] as? String, id.uuidString)
        XCTAssertEqual(object["fcm_token"] as? String, "fake-token")
        XCTAssertEqual(object["role"] as? String, "caregiver")
    }
}

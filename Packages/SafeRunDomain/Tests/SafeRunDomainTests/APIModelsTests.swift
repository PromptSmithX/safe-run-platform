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
}

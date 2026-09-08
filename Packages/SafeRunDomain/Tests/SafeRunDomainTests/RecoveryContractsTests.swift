import XCTest
@testable import SafeRunDomain

final class RecoveryContractsTests: XCTestCase {
    func testReconciliationUsesSnakeCaseAndRoundTrips() throws {
        let value = SessionReconciliationResponse(sessions: [
            ReconciledRunSession(clientSessionID: "local", serverSessionID: "server", status: .abandoned, lastSequence: 42, incidentIDs: ["incident"])
        ])
        let data = try SafeRunJSON.makeEncoder().encode(value)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("client_session_id"))
        XCTAssertTrue(json.contains("last_seq"))
        XCTAssertEqual(try SafeRunJSON.makeDecoder().decode(SessionReconciliationResponse.self, from: data), value)
    }
}

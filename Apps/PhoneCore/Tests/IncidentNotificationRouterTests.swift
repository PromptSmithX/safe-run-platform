import XCTest
@testable import SafeRunPhoneCore

final class IncidentNotificationRouterTests: XCTestCase {
    func testRejectsMalformedAndDuplicateRoutes() {
        var router = IncidentNotificationRouter()
        XCTAssertNil(router.accept(userInfo: ["type": "incident", "incident_id": "bad-id"]))
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertNotNil(router.accept(userInfo: ["type": "incident", "incident_id": id, "incident_status": "alerted"]))
        XCTAssertNil(router.accept(userInfo: ["type": "incident", "incident_id": id, "incident_status": "alerted"]))
        XCTAssertNotNil(router.accept(userInfo: ["type": "incident", "incident_id": id, "incident_status": "cancelled"]))
        XCTAssertNil(router.accept(userInfo: ["type": "other", "incident_id": "22222222-2222-4222-8222-222222222222"]))
    }
}

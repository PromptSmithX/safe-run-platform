import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunPhoneCore

final class CaregiverCoordinatorTests: XCTestCase {
    func testRefreshesUserTokenOnceAfterUnauthorizedIncidentRead() async throws {
        let incidentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let api = CaregiverAPIStub(incidentID: incidentID)
        let auth = UserTokenStub()
        let coordinator = CaregiverCoordinator(api: api, auth: auth)

        let detail = try await coordinator.loadIncident(id: incidentID)
        let refreshes = await auth.refreshValues()
        let tokens = await api.tokens()

        XCTAssertEqual(detail.incidentID, incidentID)
        XCTAssertEqual(refreshes, [false, true])
        XCTAssertEqual(tokens, ["cached", "refreshed"])
    }
}

private actor UserTokenStub: UserIDTokenProviding {
    private var refreshes: [Bool] = []
    func idToken(forceRefresh: Bool) async throws -> String {
        refreshes.append(forceRefresh)
        return forceRefresh ? "refreshed" : "cached"
    }
    func signOut() async throws {}
    func refreshValues() -> [Bool] { refreshes }
}

private actor CaregiverAPIStub: CaregiverAPIClientProtocol {
    private let incidentID: UUID
    private var seenTokens: [String] = []
    init(incidentID: UUID) { self.incidentID = incidentID }

    func registerDevice(_ request: DeviceRegistrationRequest, userToken: String) async throws -> DeviceRegistrationResponse {
        DeviceRegistrationResponse(registered: true, deviceID: request.deviceID)
    }
    func deactivateDevice(deviceID: UUID, userToken: String) async throws -> DeviceRegistrationResponse {
        DeviceRegistrationResponse(registered: false, deviceID: deviceID)
    }
    func incident(id: UUID, userToken: String) async throws -> IncidentDetail {
        seenTokens.append(userToken)
        if userToken == "cached" { throw APIClientFailure(statusCode: 401, code: "UNAUTHORIZED", retryable: false) }
        return IncidentDetail(
            incidentID: incidentID,
            sessionID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            type: .manualSOS, severity: .critical, status: .alerted, createdAt: Date()
        )
    }
    func acknowledgeIncident(id: UUID, request: IncidentAcknowledgementRequest, userToken: String) async throws -> IncidentAcknowledgementResponse {
        IncidentAcknowledgementResponse(incidentID: id, status: .acknowledged)
    }
    func tokens() -> [String] { seenTokens }
}

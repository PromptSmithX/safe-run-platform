import Foundation
import SafeRunDomain

public actor CaregiverCoordinator {
    private let api: any CaregiverAPIClientProtocol
    private let auth: any UserIDTokenProviding

    public init(api: any CaregiverAPIClientProtocol, auth: any UserIDTokenProviding) {
        self.api = api
        self.auth = auth
    }

    public func registerDevice(_ request: DeviceRegistrationRequest) async throws -> DeviceRegistrationResponse {
        try await withUserToken { token in try await api.registerDevice(request, userToken: token) }
    }

    public func deactivateDevice(id: UUID) async throws -> DeviceRegistrationResponse {
        try await withUserToken { token in try await api.deactivateDevice(deviceID: id, userToken: token) }
    }

    public func loadIncident(id: UUID) async throws -> IncidentDetail {
        try await withUserToken { token in try await api.incident(id: id, userToken: token) }
    }

    public func acknowledge(id: UUID) async throws -> IncidentAcknowledgementResponse {
        try await withUserToken { token in
            try await api.acknowledgeIncident(id: id, request: IncidentAcknowledgementRequest(), userToken: token)
        }
    }

    private func withUserToken<T: Sendable>(
        operation: (String) async throws -> T
    ) async throws -> T {
        do {
            let token = try await auth.idToken(forceRefresh: false)
            return try await operation(token)
        } catch let failure as APIClientFailure where failure.statusCode == 401 {
            let token = try await auth.idToken(forceRefresh: true)
            return try await operation(token)
        }
    }
}

import Foundation
import SafeRunDomain

public protocol UserIDTokenProviding: Sendable {
    func idToken(forceRefresh: Bool) async throws -> String
    func signOut() async throws
}

public protocol SafeRunAPIClientProtocol: Sendable {
    func createSession(_ request: CreateRunSessionRequest, userToken: String) async throws -> CreateRunSessionResponse
    func ingest(_ packet: TransportPacket, serverSessionID: String, ingestToken: String) async throws -> IngestResponse
    func endSession(serverSessionID: String, ingestToken: String, request: EndRunSessionRequest) async throws
    func reconcileSessions(_ request: SessionReconciliationRequest, userToken: String) async throws -> SessionReconciliationResponse
}

public protocol CaregiverAPIClientProtocol: Sendable {
    func registerDevice(_ request: DeviceRegistrationRequest, userToken: String) async throws -> DeviceRegistrationResponse
    func deactivateDevice(deviceID: UUID, userToken: String) async throws -> DeviceRegistrationResponse
    func incident(id: UUID, userToken: String) async throws -> IncidentDetail
    func acknowledgeIncident(id: UUID, request: IncidentAcknowledgementRequest, userToken: String) async throws -> IncidentAcknowledgementResponse
}

public struct APIClientFailure: Error, Equatable, Sendable {
    public let statusCode: Int?
    public let code: String
    public let retryable: Bool
    public let retryAfter: TimeInterval?

    public init(statusCode: Int?, code: String, retryable: Bool, retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.code = code
        self.retryable = retryable
        self.retryAfter = retryAfter
    }
}

public enum NetworkFailureInjection: Equatable, Sendable {
    case none
    case delay(TimeInterval)
    case forcedServerError
    case expiredToken
    case duplicateRequest
    case offline
}

public final class SafeRunAPIClient: SafeRunAPIClientProtocol, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let injection: NetworkFailureInjection

    public init(baseURL: URL, session: URLSession = .shared, injection: NetworkFailureInjection = .none) {
        self.baseURL = baseURL
        self.session = session
        self.injection = injection
    }

    public func createSession(_ request: CreateRunSessionRequest, userToken: String) async throws -> CreateRunSessionResponse {
        try await send(path: "v1/run-sessions", method: "POST", token: userToken, body: request)
    }

    public func ingest(_ packet: TransportPacket, serverSessionID: String, ingestToken: String) async throws -> IngestResponse {
        let suffix = packet.kind == .telemetry ? "telemetry" : "events"
        return try await send(
            path: "v1/run-sessions/\(serverSessionID)/\(suffix)", method: "POST", token: ingestToken,
            idempotencyKey: packet.packetID.uuidString, rawBody: packet.envelopeData
        )
    }

    public func endSession(serverSessionID: String, ingestToken: String, request: EndRunSessionRequest) async throws {
        let _: IngestResponse = try await send(
            path: "v1/run-sessions/\(serverSessionID)/end", method: "POST", token: ingestToken, body: request
        )
    }

    public func reconcileSessions(_ request: SessionReconciliationRequest, userToken: String) async throws -> SessionReconciliationResponse {
        try await send(path: "v1/run-sessions/reconcile", method: "POST", token: userToken, body: request)
    }

    public func registerDevice(_ request: DeviceRegistrationRequest, userToken: String) async throws -> DeviceRegistrationResponse {
        try await send(path: "v1/devices", method: "POST", token: userToken, body: request)
    }

    public func deactivateDevice(deviceID: UUID, userToken: String) async throws -> DeviceRegistrationResponse {
        try await send(path: "v1/devices/\(deviceID.uuidString)", method: "DELETE", token: userToken, rawBody: Data())
    }

    public func incident(id: UUID, userToken: String) async throws -> IncidentDetail {
        try await send(path: "v1/incidents/\(id.uuidString)", method: "GET", token: userToken, rawBody: Data())
    }

    public func acknowledgeIncident(
        id: UUID,
        request: IncidentAcknowledgementRequest,
        userToken: String
    ) async throws -> IncidentAcknowledgementResponse {
        try await send(path: "v1/incidents/\(id.uuidString)/acknowledge", method: "POST", token: userToken, body: request)
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String, method: String, token: String, idempotencyKey: String? = nil, body: Body
    ) async throws -> Response {
        try await send(path: path, method: method, token: token, idempotencyKey: idempotencyKey, rawBody: SafeRunJSON.makeEncoder().encode(body))
    }

    private func send<Response: Decodable>(
        path: String, method: String, token: String, idempotencyKey: String? = nil, rawBody: Data
    ) async throws -> Response {
        switch injection {
        case .none: break
        case .delay(let seconds): try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        case .forcedServerError: throw APIClientFailure(statusCode: 500, code: "DEBUG_FORCED_500", retryable: true)
        case .expiredToken: throw APIClientFailure(statusCode: 401, code: "SESSION_TOKEN_EXPIRED", retryable: false)
        case .duplicateRequest: break
        case .offline: throw APIClientFailure(statusCode: nil, code: "OFFLINE", retryable: true)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = rawBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        do {
            if injection == .duplicateRequest { _ = try await session.data(for: request) }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIClientFailure(statusCode: nil, code: "INVALID_RESPONSE", retryable: true)
            }
            guard (200...299).contains(http.statusCode) else {
                let apiError = try? SafeRunJSON.makeDecoder().decode(SafeRunAPIErrorEnvelope.self, from: data).error
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw APIClientFailure(
                    statusCode: http.statusCode,
                    code: apiError?.code ?? "HTTP_\(http.statusCode)",
                    retryable: apiError?.retryable ?? (
                        http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500
                    ),
                    retryAfter: retryAfter
                )
            }
            return try SafeRunJSON.makeDecoder().decode(Response.self, from: data)
        } catch let failure as APIClientFailure {
            throw failure
        } catch {
            throw APIClientFailure(statusCode: nil, code: "NETWORK", retryable: true)
        }
    }
}

extension SafeRunAPIClient: CaregiverAPIClientProtocol {}

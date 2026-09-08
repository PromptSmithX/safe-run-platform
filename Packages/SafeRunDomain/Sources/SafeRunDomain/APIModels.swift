import Foundation

public struct CreateRunSessionRequest: Codable, Equatable, Sendable {
    public let clientSessionID: String
    public let watchModel: String?
    public let appVersion: String?
    public let configVersion: Int?

    public init(clientSessionID: String, watchModel: String? = nil, appVersion: String? = nil, configVersion: Int? = nil) {
        self.clientSessionID = clientSessionID
        self.watchModel = watchModel
        self.appVersion = appVersion
        self.configVersion = configVersion
    }

    private enum CodingKeys: String, CodingKey {
        case clientSessionID = "client_session_id"
        case watchModel = "watch_model"
        case appVersion = "app_version"
        case configVersion = "config_version"
    }
}

public struct CreateRunSessionResponse: Codable, Equatable, Sendable {
    public let sessionID: String
    public let ingestToken: String
    public let expiresAt: Date
    public let serverTime: Date

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case ingestToken = "ingest_token"
        case expiresAt = "expires_at"
        case serverTime = "server_time"
    }
}

public struct IngestResponse: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let duplicate: Bool?
    public let lastSequence: Int?
    public let serverTime: Date?
    public let incidentID: String?
    public let incidentStatus: String?

    private enum CodingKeys: String, CodingKey {
        case accepted, duplicate
        case lastSequence = "last_seq"
        case serverTime = "server_time"
        case incidentID = "incident_id"
        case incidentStatus = "incident_status"
    }
}

public struct EndRunSessionRequest: Codable, Equatable, Sendable {
    public let reason: String
    public let lastSequence: Int

    public init(reason: String = "user_stopped", lastSequence: Int) {
        self.reason = reason
        self.lastSequence = lastSequence
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case lastSequence = "last_seq"
    }
}

public struct SafeRunAPIErrorEnvelope: Codable, Equatable, Sendable {
    public let error: SafeRunAPIError
}

public struct SafeRunAPIError: Codable, Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let requestID: String

    private enum CodingKeys: String, CodingKey {
        case code, message, retryable
        case requestID = "request_id"
    }
}

public extension TransportPacket {
    func replacingSessionID(with serverSessionID: String) throws -> TransportPacket {
        let decoder = SafeRunJSON.makeDecoder()
        let encoder = SafeRunJSON.makeEncoder()
        switch kind {
        case .telemetry:
            let source = try decoder.decode(TelemetryEnvelope.self, from: envelopeData)
            let replacement = TelemetryEnvelope(
                packetID: source.packetID,
                sessionID: serverSessionID,
                sequence: source.sequence,
                watchTimestamp: source.watchTimestamp,
                payload: source.payload
            )
            return try TransportPacket.decodeEnvelope(encoder.encode(replacement))
        case .event:
            let source = try decoder.decode(EventEnvelope.self, from: envelopeData)
            let replacement = EventEnvelope(
                packetID: source.packetID,
                sessionID: serverSessionID,
                sequence: source.sequence,
                watchTimestamp: source.watchTimestamp,
                payload: source.payload
            )
            return try TransportPacket.decodeEnvelope(encoder.encode(replacement))
        }
    }
}

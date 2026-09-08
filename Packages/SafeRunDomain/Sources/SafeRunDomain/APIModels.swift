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

public struct DeviceRegistrationRequest: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let platform: String
    public let role: DeviceRole
    public let fcmToken: String
    public let appVersion: String

    public init(deviceID: UUID, role: DeviceRole, fcmToken: String, appVersion: String, platform: String = "ios") {
        self.deviceID = deviceID
        self.platform = platform
        self.role = role
        self.fcmToken = fcmToken
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case platform, role
        case fcmToken = "fcm_token"
        case appVersion = "app_version"
    }
}

public struct DeviceRegistrationResponse: Codable, Equatable, Sendable {
    public let registered: Bool
    public let deviceID: UUID

    public init(registered: Bool, deviceID: UUID) {
        self.registered = registered
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey {
        case registered
        case deviceID = "device_id"
    }
}

public struct IncidentDetail: Codable, Equatable, Sendable, Identifiable {
    public let incidentID: UUID
    public let sessionID: UUID
    public let type: SafetyEventType
    public let severity: IncidentSeverity
    public let status: IncidentStatus
    public let createdAt: Date
    public let runnerEventAt: Date?
    public let context: EventContext?
    public let acknowledgedBy: String?
    public let acknowledgedAt: Date?
    public let runnerDisplayName: String?
    public let runnerPhoneE164: String?

    public var id: UUID { incidentID }

    public init(
        incidentID: UUID,
        sessionID: UUID,
        type: SafetyEventType,
        severity: IncidentSeverity,
        status: IncidentStatus,
        createdAt: Date,
        runnerEventAt: Date? = nil,
        context: EventContext? = nil,
        acknowledgedBy: String? = nil,
        acknowledgedAt: Date? = nil,
        runnerDisplayName: String? = nil,
        runnerPhoneE164: String? = nil
    ) {
        self.incidentID = incidentID
        self.sessionID = sessionID
        self.type = type
        self.severity = severity
        self.status = status
        self.createdAt = createdAt
        self.runnerEventAt = runnerEventAt
        self.context = context
        self.acknowledgedBy = acknowledgedBy
        self.acknowledgedAt = acknowledgedAt
        self.runnerDisplayName = runnerDisplayName
        self.runnerPhoneE164 = runnerPhoneE164
    }

    private enum CodingKeys: String, CodingKey {
        case incidentID = "incident_id"
        case sessionID = "session_id"
        case type, severity, status, context
        case createdAt = "created_at"
        case runnerEventAt = "runner_event_at"
        case acknowledgedBy = "acknowledged_by"
        case acknowledgedAt = "acknowledged_at"
        case runnerDisplayName = "runner_display_name"
        case runnerPhoneE164 = "runner_phone_e164"
    }
}

public struct IncidentAcknowledgementRequest: Codable, Equatable, Sendable {
    public let action: IncidentAcknowledgementAction

    public init(action: IncidentAcknowledgementAction = .seen) {
        self.action = action
    }
}

public struct IncidentAcknowledgementResponse: Codable, Equatable, Sendable {
    public let incidentID: UUID
    public let status: IncidentStatus
    public let acknowledgedBy: String?
    public let acknowledgedAt: Date?

    public init(incidentID: UUID, status: IncidentStatus, acknowledgedBy: String? = nil, acknowledgedAt: Date? = nil) {
        self.incidentID = incidentID
        self.status = status
        self.acknowledgedBy = acknowledgedBy
        self.acknowledgedAt = acknowledgedAt
    }

    private enum CodingKeys: String, CodingKey {
        case incidentID = "incident_id"
        case status
        case acknowledgedBy = "acknowledged_by"
        case acknowledgedAt = "acknowledged_at"
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

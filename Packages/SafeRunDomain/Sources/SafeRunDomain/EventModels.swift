import Foundation

public struct LastKnownLocation: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lon"
    }
}

public struct EventContext: Codable, Equatable, Sendable {
    public var heartRateBPM: Double?
    public var lastLocation: LastKnownLocation?
    public var elapsedSeconds: Int?

    public init(
        heartRateBPM: Double? = nil,
        lastLocation: LastKnownLocation? = nil,
        elapsedSeconds: Int? = nil
    ) {
        self.heartRateBPM = heartRateBPM
        self.lastLocation = lastLocation
        self.elapsedSeconds = elapsedSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case heartRateBPM = "heart_rate_bpm"
        case lastLocation = "last_location"
        case elapsedSeconds = "elapsed_s"
    }
}

public struct EventPayload: Codable, Equatable, Sendable {
    public var eventID: UUID
    public var eventType: SafetyEventType
    public var severity: IncidentSeverity
    public var ruleID: String?
    public var incidentID: UUID?
    public var context: EventContext?

    public init(
        eventID: UUID = UUID(),
        eventType: SafetyEventType,
        severity: IncidentSeverity,
        ruleID: String? = nil,
        incidentID: UUID? = nil,
        context: EventContext? = nil
    ) {
        precondition(
            eventType != .manualSOSCancelled || (severity == .critical && incidentID != nil),
            "manual_sos_cancelled must be critical and include incident_id."
        )
        self.eventID = eventID
        self.eventType = eventType
        self.severity = severity
        self.ruleID = ruleID
        self.incidentID = incidentID
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventType = "event_type"
        case severity
        case ruleID = "rule_id"
        case incidentID = "incident_id"
        case context
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.incidentID) else {
            throw DecodingError.keyNotFound(
                CodingKeys.incidentID,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Event payload must include incident_id, even when null."
                )
            )
        }

        self.eventID = try container.decode(UUID.self, forKey: .eventID)
        self.eventType = try container.decode(SafetyEventType.self, forKey: .eventType)
        self.severity = try container.decode(IncidentSeverity.self, forKey: .severity)
        self.ruleID = try container.decodeIfPresent(String.self, forKey: .ruleID)
        self.incidentID = try container.decodeIfPresent(UUID.self, forKey: .incidentID)
        self.context = try container.decodeIfPresent(EventContext.self, forKey: .context)
        if eventType == .manualSOSCancelled && (severity != .critical || incidentID == nil) {
            throw DecodingError.dataCorruptedError(
                forKey: .incidentID,
                in: container,
                debugDescription: "manual_sos_cancelled must be critical and include incident_id."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(severity, forKey: .severity)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        if let incidentID {
            try container.encode(incidentID, forKey: .incidentID)
        } else {
            try container.encodeNil(forKey: .incidentID)
        }
        try container.encodeIfPresent(context, forKey: .context)
    }
}

public struct EventEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packetID: UUID
    public let sessionID: String
    public let sequence: Int
    public let watchTimestamp: Date
    public let kind: EnvelopeKind
    public let payload: EventPayload

    public init(
        packetID: UUID = UUID(),
        sessionID: String,
        sequence: Int,
        watchTimestamp: Date,
        payload: EventPayload
    ) {
        precondition(sequence >= 1, "Envelope sequence must start at 1.")
        self.schemaVersion = SafeRunContract.schemaVersion
        self.packetID = packetID
        self.sessionID = sessionID
        self.sequence = sequence
        self.watchTimestamp = watchTimestamp
        self.kind = .event
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case packetID = "packet_id"
        case sessionID = "session_id"
        case sequence = "seq"
        case watchTimestamp = "watch_timestamp"
        case kind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == SafeRunContract.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported schema version \(schemaVersion)."
            )
        }

        let sequence = try container.decode(Int.self, forKey: .sequence)
        guard sequence >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence,
                in: container,
                debugDescription: "Envelope sequence must be at least 1."
            )
        }

        let kind = try container.decode(EnvelopeKind.self, forKey: .kind)
        guard kind == .event else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Expected event envelope."
            )
        }

        self.schemaVersion = schemaVersion
        self.packetID = try container.decode(UUID.self, forKey: .packetID)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.sequence = sequence
        self.watchTimestamp = try container.decode(Date.self, forKey: .watchTimestamp)
        self.kind = kind
        self.payload = try container.decode(EventPayload.self, forKey: .payload)
    }
}

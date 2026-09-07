import Foundation

public struct TelemetryLocation: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracyMeters: Double
    public var ageMilliseconds: Int

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double,
        ageMilliseconds: Int
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.ageMilliseconds = ageMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lon"
        case horizontalAccuracyMeters = "horizontal_accuracy_m"
        case ageMilliseconds = "age_ms"
    }
}

public struct TransportSnapshot: Codable, Equatable, Sendable {
    public var phoneReachable: Bool

    public init(phoneReachable: Bool) {
        self.phoneReachable = phoneReachable
    }

    private enum CodingKeys: String, CodingKey {
        case phoneReachable = "phone_reachable"
    }
}

public struct TelemetryPayload: Codable, Equatable, Sendable {
    public var heartRateBPM: Double?
    public var heartRateSampleAgeMilliseconds: Int?
    public var elapsedSeconds: Int
    public var distanceMeters: Double?
    public var speedMetersPerSecond: Double?
    public var location: TelemetryLocation?
    public var motionState: MotionState?
    public var watchBattery: Double?
    public var transport: TransportSnapshot?

    public init(
        heartRateBPM: Double? = nil,
        heartRateSampleAgeMilliseconds: Int? = nil,
        elapsedSeconds: Int,
        distanceMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        location: TelemetryLocation? = nil,
        motionState: MotionState? = nil,
        watchBattery: Double? = nil,
        transport: TransportSnapshot? = nil
    ) {
        self.heartRateBPM = heartRateBPM
        self.heartRateSampleAgeMilliseconds = heartRateSampleAgeMilliseconds
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.location = location
        self.motionState = motionState
        self.watchBattery = watchBattery
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey {
        case heartRateBPM = "heart_rate_bpm"
        case heartRateSampleAgeMilliseconds = "heart_rate_sample_age_ms"
        case elapsedSeconds = "elapsed_s"
        case distanceMeters = "distance_m"
        case speedMetersPerSecond = "speed_mps"
        case location
        case motionState = "motion_state"
        case watchBattery = "watch_battery"
        case transport
    }
}

public struct TelemetryEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packetID: UUID
    public let sessionID: String
    public let sequence: Int
    public let watchTimestamp: Date
    public let kind: EnvelopeKind
    public let payload: TelemetryPayload

    public init(
        packetID: UUID = UUID(),
        sessionID: String,
        sequence: Int,
        watchTimestamp: Date,
        payload: TelemetryPayload
    ) {
        precondition(sequence >= 1, "Envelope sequence must start at 1.")
        self.schemaVersion = SafeRunContract.schemaVersion
        self.packetID = packetID
        self.sessionID = sessionID
        self.sequence = sequence
        self.watchTimestamp = watchTimestamp
        self.kind = .telemetry
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
        guard kind == .telemetry else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Expected telemetry envelope."
            )
        }

        self.schemaVersion = schemaVersion
        self.packetID = try container.decode(UUID.self, forKey: .packetID)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.sequence = sequence
        self.watchTimestamp = try container.decode(Date.self, forKey: .watchTimestamp)
        self.kind = kind
        self.payload = try container.decode(TelemetryPayload.self, forKey: .payload)
    }
}


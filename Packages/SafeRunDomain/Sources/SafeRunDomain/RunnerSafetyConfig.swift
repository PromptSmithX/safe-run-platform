import Foundation

public struct RunnerSafetyConfig: Codable, Equatable, Sendable {
    public var highHRThresholdBPM: Double?
    public var highHRSustainedSeconds: TimeInterval
    public var checkInSeconds: Int
    public var ruleCooldownSeconds: Int
    public var staleHeartRateSeconds: Int
    public var telemetryIntervalSeconds: Int
    public var warmUpSeconds: Int
    public var highHRHysteresisBPM: Double
    public var highHRRearmSeconds: Int
    public var minimumHighHRSamples: Int

    public init(
        highHRThresholdBPM: Double? = nil,
        highHRSustainedSeconds: TimeInterval = 30,
        checkInSeconds: Int = 20,
        ruleCooldownSeconds: Int = 300,
        staleHeartRateSeconds: Int = 5,
        telemetryIntervalSeconds: Int = 10,
        warmUpSeconds: Int = 180,
        highHRHysteresisBPM: Double = 10,
        highHRRearmSeconds: Int = 30,
        minimumHighHRSamples: Int = 3
    ) {
        self.highHRThresholdBPM = highHRThresholdBPM
        self.highHRSustainedSeconds = highHRSustainedSeconds
        self.checkInSeconds = checkInSeconds
        self.ruleCooldownSeconds = ruleCooldownSeconds
        self.staleHeartRateSeconds = staleHeartRateSeconds
        self.telemetryIntervalSeconds = telemetryIntervalSeconds
        self.warmUpSeconds = warmUpSeconds
        self.highHRHysteresisBPM = highHRHysteresisBPM
        self.highHRRearmSeconds = highHRRearmSeconds
        self.minimumHighHRSamples = minimumHighHRSamples
    }

    private enum CodingKeys: String, CodingKey {
        case highHRThresholdBPM = "high_hr_threshold_bpm"
        case highHRSustainedSeconds = "high_hr_sustained_seconds"
        case checkInSeconds = "check_in_seconds"
        case ruleCooldownSeconds = "rule_cooldown_seconds"
        case staleHeartRateSeconds = "stale_heart_rate_seconds"
        case telemetryIntervalSeconds = "telemetry_interval_seconds"
        case warmUpSeconds = "warm_up_seconds"
        case highHRHysteresisBPM = "high_hr_hysteresis_bpm"
        case highHRRearmSeconds = "high_hr_rearm_seconds"
        case minimumHighHRSamples = "minimum_high_hr_samples"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        highHRThresholdBPM = try values.decodeIfPresent(Double.self, forKey: .highHRThresholdBPM)
        highHRSustainedSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .highHRSustainedSeconds) ?? 30
        checkInSeconds = try values.decodeIfPresent(Int.self, forKey: .checkInSeconds) ?? 20
        ruleCooldownSeconds = try values.decodeIfPresent(Int.self, forKey: .ruleCooldownSeconds) ?? 300
        staleHeartRateSeconds = try values.decodeIfPresent(Int.self, forKey: .staleHeartRateSeconds) ?? 5
        telemetryIntervalSeconds = try values.decodeIfPresent(Int.self, forKey: .telemetryIntervalSeconds) ?? 10
        warmUpSeconds = try values.decodeIfPresent(Int.self, forKey: .warmUpSeconds) ?? 180
        highHRHysteresisBPM = try values.decodeIfPresent(Double.self, forKey: .highHRHysteresisBPM) ?? 10
        highHRRearmSeconds = try values.decodeIfPresent(Int.self, forKey: .highHRRearmSeconds) ?? 30
        minimumHighHRSamples = try values.decodeIfPresent(Int.self, forKey: .minimumHighHRSamples) ?? 3
    }
}

public struct RunnerSafetyConfigurationEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let configurationID: UUID
    public let revision: Int
    public let updatedAt: Date
    public let config: RunnerSafetyConfig

    public init(configurationID: UUID = UUID(), revision: Int, updatedAt: Date = Date(), config: RunnerSafetyConfig) {
        precondition(revision >= 1)
        precondition(Self.isValid(config))
        schemaVersion = SafeRunContract.schemaVersion
        self.configurationID = configurationID
        self.revision = revision
        self.updatedAt = updatedAt
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", configurationID = "configuration_id", revision
        case updatedAt = "updated_at", config
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        configurationID = try c.decode(UUID.self, forKey: .configurationID)
        revision = try c.decode(Int.self, forKey: .revision)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        config = try c.decode(RunnerSafetyConfig.self, forKey: .config)
        guard schemaVersion == SafeRunContract.schemaVersion, revision >= 1,
              Self.isValid(config) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Invalid safety configuration envelope"))
        }
    }

    private static func isValid(_ config: RunnerSafetyConfig) -> Bool {
        (config.highHRThresholdBPM.map { $0.isFinite && (40...240).contains($0) } ?? true)
            && config.highHRSustainedSeconds > 0 && config.checkInSeconds > 0
            && config.ruleCooldownSeconds >= 0 && config.staleHeartRateSeconds > 0
            && config.telemetryIntervalSeconds > 0 && config.warmUpSeconds >= 0
            && config.highHRHysteresisBPM >= 0 && config.highHRRearmSeconds >= 0
            && config.minimumHighHRSamples >= 1
    }
}

import Foundation

public struct RunnerSafetyConfig: Codable, Equatable, Sendable {
    public var highHRThresholdBPM: Double?
    public var highHRSustainedSeconds: TimeInterval
    public var checkInSeconds: Int
    public var ruleCooldownSeconds: Int
    public var staleHeartRateSeconds: Int
    public var telemetryIntervalSeconds: Int

    public init(
        highHRThresholdBPM: Double? = nil,
        highHRSustainedSeconds: TimeInterval = 30,
        checkInSeconds: Int = 20,
        ruleCooldownSeconds: Int = 300,
        staleHeartRateSeconds: Int = 5,
        telemetryIntervalSeconds: Int = 10
    ) {
        self.highHRThresholdBPM = highHRThresholdBPM
        self.highHRSustainedSeconds = highHRSustainedSeconds
        self.checkInSeconds = checkInSeconds
        self.ruleCooldownSeconds = ruleCooldownSeconds
        self.staleHeartRateSeconds = staleHeartRateSeconds
        self.telemetryIntervalSeconds = telemetryIntervalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case highHRThresholdBPM = "high_hr_threshold_bpm"
        case highHRSustainedSeconds = "high_hr_sustained_seconds"
        case checkInSeconds = "check_in_seconds"
        case ruleCooldownSeconds = "rule_cooldown_seconds"
        case staleHeartRateSeconds = "stale_heart_rate_seconds"
        case telemetryIntervalSeconds = "telemetry_interval_seconds"
    }
}


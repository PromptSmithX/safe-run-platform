import Foundation
import SafeRunDomain

public enum HighHeartRateRuleState: Equatable, Sendable {
    case disabled, warmingUp, monitoring, accumulating(sampleCount: Int), triggered, coolingDown, lockedForRun
}

public struct HeartRateRuleSample: Equatable, Sendable {
    public let bpm: Double?
    public let sampledAt: Date?
    public init(bpm: Double?, sampledAt: Date?) { self.bpm = bpm; self.sampledAt = sampledAt }
}

public struct HighHeartRateTrigger: Equatable, Sendable {
    public let evaluation: RuleEvaluationSnapshot
}

public struct SustainedHighHeartRateRule: Sendable {
    public private(set) var state: HighHeartRateRuleState = .monitoring
    private var highSamples: [(Date, Double)] = []
    private var cooldownUntil: Date?
    private var belowSince: Date?

    public init() {}

    public mutating func evaluate(sample: HeartRateRuleSample, runStartedAt: Date, runState: RunState, now: Date, config: RunnerSafetyConfig, checkInActive: Bool) -> HighHeartRateTrigger? {
        guard let threshold = config.highHRThresholdBPM else { reset(.disabled); return nil }
        guard state != .lockedForRun else { return nil }
        guard runState == .active else { reset(.monitoring); return nil }
        guard now.timeIntervalSince(runStartedAt) >= TimeInterval(config.warmUpSeconds) else { reset(.warmingUp); return nil }
        guard let bpm = sample.bpm, bpm.isFinite, bpm > 0, let sampledAt = sample.sampledAt else { resetWindow(); return nil }
        let age = now.timeIntervalSince(sampledAt)
        guard age >= 0, age <= TimeInterval(config.staleHeartRateSeconds) else { resetWindow(); return nil }

        if cooldownUntil != nil {
            state = .coolingDown
            if bpm < threshold - config.highHRHysteresisBPM {
                belowSince = belowSince ?? sampledAt
            } else { belowSince = nil }
            guard let cooldownUntil, now >= cooldownUntil,
                  let belowSince, now.timeIntervalSince(belowSince) >= TimeInterval(config.highHRRearmSeconds) else { return nil }
            self.cooldownUntil = nil; self.belowSince = nil; highSamples.removeAll(); state = .monitoring
        }

        guard !checkInActive else { return nil }
        guard bpm >= threshold else { resetWindow(); return nil }
        if let previous = highSamples.last, sampledAt.timeIntervalSince(previous.0) > TimeInterval(config.staleHeartRateSeconds) {
            highSamples.removeAll()
        }
        if highSamples.last?.0 != sampledAt { highSamples.append((sampledAt, bpm)) }
        state = .accumulating(sampleCount: highSamples.count)
        guard let first = highSamples.first, sampledAt.timeIntervalSince(first.0) >= config.highHRSustainedSeconds,
              highSamples.count >= config.minimumHighHRSamples else { return nil }
        let values = highSamples.map { $0.1 }
        state = .triggered
        return HighHeartRateTrigger(evaluation: RuleEvaluationSnapshot(
            thresholdBPM: threshold, windowSeconds: sampledAt.timeIntervalSince(first.0), sampleCount: values.count,
            minimumBPM: values.min()!, maximumBPM: values.max()!, averageBPM: values.reduce(0, +) / Double(values.count)
        ))
    }

    public mutating func runnerIsOK(at date: Date, config: RunnerSafetyConfig) {
        cooldownUntil = date.addingTimeInterval(TimeInterval(config.ruleCooldownSeconds)); belowSince = nil
        highSamples.removeAll(); state = .coolingDown
    }

    public mutating func escalationCompleted() { reset(.lockedForRun) }
    public mutating func resetForRun() { cooldownUntil = nil; belowSince = nil; reset(.monitoring) }
    private mutating func resetWindow() { highSamples.removeAll(); belowSince = nil; state = cooldownUntil == nil ? .monitoring : .coolingDown }
    private mutating func reset(_ next: HighHeartRateRuleState) { highSamples.removeAll(); state = next }
}

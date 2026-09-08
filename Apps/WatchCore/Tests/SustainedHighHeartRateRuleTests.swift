import SafeRunDomain
@testable import SafeRunWatchCore
import Foundation
import XCTest

final class SustainedHighHeartRateRuleTests: XCTestCase {
    func testDisabledRuleNeverTriggers() {
        var rule = SustainedHighHeartRateRule()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertNil(rule.evaluate(sample: .init(bpm: 200, sampledAt: start), runStartedAt: start, runState: .active, now: start.addingTimeInterval(500), config: RunnerSafetyConfig(), checkInActive: false))
    }

    func testSustainedFreshSamplesTriggerOnce() {
        var rule = SustainedHighHeartRateRule(); let start = Date(timeIntervalSince1970: 0)
        let config = RunnerSafetyConfig(highHRThresholdBPM: 170, highHRSustainedSeconds: 30, warmUpSeconds: 0, minimumHighHRSamples: 3)
        for second in [0.0, 15, 29] { XCTAssertNil(rule.evaluate(sample: .init(bpm: 180, sampledAt: start.addingTimeInterval(second)), runStartedAt: start, runState: .active, now: start.addingTimeInterval(second), config: config, checkInActive: false)) }
        let trigger = rule.evaluate(sample: .init(bpm: 181, sampledAt: start.addingTimeInterval(30)), runStartedAt: start, runState: .active, now: start.addingTimeInterval(30), config: config, checkInActive: false)
        XCTAssertEqual(trigger?.evaluation.sampleCount, 4)
    }

    func testStaleSampleBreaksWindow() {
        var rule = SustainedHighHeartRateRule(); let start = Date(timeIntervalSince1970: 0)
        let config = RunnerSafetyConfig(highHRThresholdBPM: 170, warmUpSeconds: 0)
        _ = rule.evaluate(sample: .init(bpm: 180, sampledAt: start), runStartedAt: start, runState: .active, now: start, config: config, checkInActive: false)
        XCTAssertNil(rule.evaluate(sample: .init(bpm: 180, sampledAt: start), runStartedAt: start, runState: .active, now: start.addingTimeInterval(6), config: config, checkInActive: false))
        XCTAssertEqual(rule.state, .monitoring)
    }

    func testCooldownRequiresTimeAndHysteresisWindow() {
        var rule = SustainedHighHeartRateRule(); let start = Date(timeIntervalSince1970: 0)
        let config = RunnerSafetyConfig(highHRThresholdBPM: 170, ruleCooldownSeconds: 10, staleHeartRateSeconds: 60, warmUpSeconds: 0, highHRRearmSeconds: 5)
        rule.runnerIsOK(at: start, config: config)
        _ = rule.evaluate(sample: .init(bpm: 150, sampledAt: start.addingTimeInterval(5)), runStartedAt: start, runState: .active, now: start.addingTimeInterval(5), config: config, checkInActive: false)
        _ = rule.evaluate(sample: .init(bpm: 150, sampledAt: start.addingTimeInterval(10)), runStartedAt: start, runState: .active, now: start.addingTimeInterval(10), config: config, checkInActive: false)
        XCTAssertEqual(rule.state, .monitoring)
    }
}

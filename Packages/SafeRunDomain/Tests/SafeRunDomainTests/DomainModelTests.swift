import XCTest
@testable import SafeRunDomain

final class DomainModelTests: XCTestCase {
    func testRunStateRawValuesMatchContract() {
        XCTAssertEqual(RunState.allCases.map(\.rawValue), [
            "idle",
            "preparing",
            "active",
            "paused",
            "recovering",
            "ending",
            "ended",
            "failed"
        ])
    }

    func testSafetyEventRawValuesMatchMVPContract() {
        XCTAssertEqual(SafetyEventType.manualSOS.rawValue, "manual_sos")
        XCTAssertEqual(SafetyEventType.manualSOSCancelled.rawValue, "manual_sos_cancelled")
        XCTAssertEqual(SafetyEventType.checkInOK.rawValue, "check_in_ok")
        XCTAssertEqual(SafetyEventType.stateSync.rawValue, "state_sync")
        XCTAssertFalse(SafetyEventType.allCases.map(\.rawValue).contains("fall_detected"))
    }

    func testPacketSequenceStartsAtOneAndCanResume() {
        var fresh = PacketSequence()
        XCTAssertEqual(fresh.next(), 1)
        XCTAssertEqual(fresh.next(), 2)

        var restored = PacketSequence(lastIssued: 41)
        XCTAssertEqual(restored.next(), 42)
        XCTAssertEqual(restored.lastIssued, 42)
    }

    func testDefaultSafetyConfigDoesNotInferMedicalThreshold() {
        let config = RunnerSafetyConfig()

        XCTAssertNil(config.highHRThresholdBPM)
        XCTAssertEqual(config.warmUpSeconds, 180)
        XCTAssertEqual(config.highHRHysteresisBPM, 10)
        XCTAssertEqual(config.highHRRearmSeconds, 30)
        XCTAssertEqual(config.minimumHighHRSamples, 3)
        XCTAssertEqual(config.highHRSustainedSeconds, 30)
        XCTAssertEqual(config.checkInSeconds, 20)
        XCTAssertEqual(config.ruleCooldownSeconds, 300)
        XCTAssertEqual(config.staleHeartRateSeconds, 5)
        XCTAssertEqual(config.telemetryIntervalSeconds, 10)
    }

    func testLegacySafetyConfigReceivesNewDefaults() throws {
        let data = Data(#"{"high_hr_threshold_bpm":null,"high_hr_sustained_seconds":30,"check_in_seconds":20,"rule_cooldown_seconds":300,"stale_heart_rate_seconds":5,"telemetry_interval_seconds":10}"#.utf8)
        let config = try SafeRunJSON.makeDecoder().decode(RunnerSafetyConfig.self, from: data)
        XCTAssertEqual(config.warmUpSeconds, 180)
        XCTAssertEqual(config.highHRRearmSeconds, 30)
        XCTAssertEqual(config.minimumHighHRSamples, 3)
    }
}

import SafeRunDomain
@testable import SafeRunWatchCore
import Foundation
import XCTest

@MainActor
private final class CheckInDispatcherSpy: CheckInEventDispatching {
    var events: [(SafetyEventType, IncidentSeverity, UUID)] = []
    func queueCheckInEvent(_ type: SafetyEventType, severity: IncidentSeverity, incidentID: UUID, evaluation: RuleEvaluationSnapshot?) async throws {
        events.append((type, severity, incidentID))
    }
}

@MainActor
final class CheckInCoordinatorTests: XCTestCase {
    private let evidence = RuleEvaluationSnapshot(thresholdBPM: 170, windowSeconds: 30, sampleCount: 3, minimumBPM: 171, maximumBPM: 180, averageBPM: 175)

    func testOKUsesSameIncidentWithoutCriticalSeverity() async {
        let spy = CheckInDispatcherSpy(), incident = UUID()
        let coordinator = CheckInCoordinator(dispatcher: spy, makeUUID: { incident })
        await coordinator.startCheckIn(reason: .sustainedHighHeartRate, evaluation: evidence, timeoutSeconds: 20, at: Date())
        await coordinator.userOK()
        XCTAssertEqual(spy.events.map { $0.0 }, [.checkInStarted, .checkInOK])
        XCTAssertEqual(spy.events.map { $0.1 }, [.warning, .info])
        XCTAssertTrue(spy.events.allSatisfy { $0.2 == incident })
    }

    func testTimeoutCanOnlyResolveOnce() async {
        let spy = CheckInDispatcherSpy()
        let start = Date()
        let tested = CheckInCoordinator(dispatcher: spy)
        await tested.startCheckIn(reason: .sustainedHighHeartRate, evaluation: evidence, timeoutSeconds: 20, at: start)
        await tested.tick(at: start.addingTimeInterval(20))
        await tested.userRequestsHelp()
        XCTAssertEqual(spy.events.filter { $0.1 == .critical }.count, 1)
    }
}

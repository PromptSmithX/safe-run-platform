import Foundation
import XCTest
@testable import SafeRunWatchCore

@MainActor
final class ManualSOSControllerTests: XCTestCase {
    func testDuplicateTriggerIsIgnoredUntilCancellationCompletes() async {
        let dispatcher = SOSDispatcherStub()
        let controller = ManualSOSController(dispatcher: dispatcher)

        await controller.trigger()
        await controller.trigger()
        XCTAssertEqual(dispatcher.triggerCount, 1)

        await controller.cancel()
        XCTAssertEqual(dispatcher.cancelCount, 1)
        if case .cancellationQueued(let receipt) = controller.state {
            XCTAssertEqual(receipt.incidentID, dispatcher.incidentID)
        } else {
            XCTFail("Expected queued cancellation")
        }

        controller.resetAfterCancellation()
        await controller.trigger()
        XCTAssertEqual(dispatcher.triggerCount, 2)
    }
}

@MainActor
private final class SOSDispatcherStub: ManualSOSDispatching {
    let incidentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    var triggerCount = 0
    var cancelCount = 0

    func queueManualSOS() async throws -> ManualSOSReceipt {
        triggerCount += 1
        return ManualSOSReceipt(eventID: UUID(), incidentID: incidentID, queuedAt: Date())
    }

    func queueManualSOSCancellation(incidentID: UUID) async throws -> ManualSOSReceipt {
        cancelCount += 1
        return ManualSOSReceipt(eventID: UUID(), incidentID: incidentID, queuedAt: Date())
    }
}

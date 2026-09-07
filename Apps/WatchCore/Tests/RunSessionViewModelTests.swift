import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunWatchCore

@MainActor
final class RunSessionViewModelTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testSuccessfulStartAndStopTransitions() async {
        let now = fixedDate
        let workout = FakeWorkoutProvider(automaticallyAdvance: false, now: { now })
        let location = FakeLocationProvider(automaticallyAdvance: false, now: { now })
        let viewModel = makeViewModel(workout: workout, location: location, now: now)

        await viewModel.start()

        XCTAssertEqual(viewModel.state, .active)
        XCTAssertEqual(workout.startCount, 1)
        XCTAssertEqual(location.startCount, 1)
        XCTAssertEqual(viewModel.locationStatus(at: fixedDate), .fresh)

        await viewModel.stop()

        XCTAssertEqual(viewModel.state, .ended)
        XCTAssertEqual(workout.stopCount, 1)
        XCTAssertEqual(location.stopCount, 1)
        XCTAssertNotNil(viewModel.lastSummary?.savedWorkoutID)
    }

    func testWorkoutAuthorizationFailurePreventsStart() async {
        let now = fixedDate
        let workout = FakeWorkoutProvider(automaticallyAdvance: false, now: { now })
        workout.authorizationError = FakeProviderError.authorizationDenied
        let location = FakeLocationProvider(automaticallyAdvance: false, now: { now })
        let viewModel = makeViewModel(workout: workout, location: location, now: now)

        await viewModel.start()

        XCTAssertEqual(viewModel.state, .failed)
        XCTAssertEqual(workout.startCount, 0)
        XCTAssertEqual(location.startCount, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testLocationDenialDoesNotBlockWorkout() async {
        let now = fixedDate
        let workout = FakeWorkoutProvider(automaticallyAdvance: false, now: { now })
        let location = FakeLocationProvider(automaticallyAdvance: false, now: { now })
        location.authorizationError = FakeProviderError.authorizationDenied
        let viewModel = makeViewModel(workout: workout, location: location, now: now)

        await viewModel.start()

        XCTAssertEqual(viewModel.state, .active)
        XCTAssertEqual(workout.startCount, 1)
        XCTAssertEqual(location.startCount, 0)
        XCTAssertEqual(viewModel.locationStatus(at: fixedDate), .unavailable)
    }

    func testHeartRateBecomesUnavailableWhenStale() async {
        let now = fixedDate
        let workout = FakeWorkoutProvider(
            samples: [135],
            automaticallyAdvance: false,
            now: { now }
        )
        let location = FakeLocationProvider(automaticallyAdvance: false, now: { now })
        let viewModel = makeViewModel(workout: workout, location: location, now: now)

        await viewModel.start()

        XCTAssertEqual(viewModel.displayedHeartRate(at: fixedDate), 135)
        XCTAssertNil(viewModel.displayedHeartRate(at: fixedDate.addingTimeInterval(6)))
    }

    func testFakeProvidersCanStartAgainAfterStop() async throws {
        let now = fixedDate
        let workout = FakeWorkoutProvider(automaticallyAdvance: false, now: { now })
        let location = FakeLocationProvider(automaticallyAdvance: false, now: { now })

        try await workout.startWorkout(at: fixedDate)
        _ = try await workout.stopWorkout(at: fixedDate.addingTimeInterval(10))
        try await workout.startWorkout(at: fixedDate.addingTimeInterval(20))

        location.startUpdatingLocation()
        location.stopUpdatingLocation()
        location.startUpdatingLocation()

        XCTAssertEqual(workout.startCount, 2)
        XCTAssertEqual(location.startCount, 2)
    }

    private func makeViewModel(
        workout: FakeWorkoutProvider,
        location: FakeLocationProvider,
        now: Date
    ) -> RunSessionViewModel {
        RunSessionViewModel(
            workoutProvider: workout,
            locationProvider: location,
            now: { now }
        )
    }
}

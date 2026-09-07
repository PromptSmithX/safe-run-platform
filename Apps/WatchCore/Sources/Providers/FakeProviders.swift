import Foundation
import SafeRunDomain

public enum FakeProviderError: Error, Equatable, LocalizedError {
    case authorizationDenied

    public var errorDescription: String? {
        "Fake provider authorization denied."
    }
}

@MainActor
public final class FakeWorkoutProvider: WorkoutDataProviding {
    public var onSnapshot: ((WorkoutSnapshot) -> Void)?
    public var authorizationError: Error?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    private let samples: [Double]
    private let automaticallyAdvance: Bool
    private let now: () -> Date
    private var sampleIndex = 0
    private var startedAt: Date?
    private var sampleTask: Task<Void, Never>?

    public init(
        samples: [Double] = [118, 124, 132, 138, 142, 136],
        automaticallyAdvance: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.samples = samples.isEmpty ? [120] : samples
        self.automaticallyAdvance = automaticallyAdvance
        self.now = now
    }

    public func requestAuthorization() async throws {
        if let authorizationError {
            throw authorizationError
        }
    }

    public func startWorkout(at date: Date) async throws {
        guard startedAt == nil else {
            throw WorkoutProviderError.workoutAlreadyActive
        }

        startCount += 1
        sampleIndex = 0
        startedAt = date
        emit(state: .active)

        if automaticallyAdvance {
            sampleTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }
                    self.emitNextSample()
                }
            }
        }
    }

    public func stopWorkout(at date: Date) async throws -> WorkoutSummary {
        guard let startedAt else {
            throw WorkoutProviderError.noActiveWorkout
        }

        stopCount += 1
        sampleTask?.cancel()
        sampleTask = nil
        self.startedAt = nil
        emit(state: .ended, startedAtOverride: startedAt)

        return WorkoutSummary(
            startedAt: startedAt,
            endedAt: date,
            savedWorkoutID: UUID()
        )
    }

    public func emitNextSample() {
        guard startedAt != nil else {
            return
        }
        sampleIndex = (sampleIndex + 1) % samples.count
        emit(state: .active)
    }

    private func emit(state: RunState, startedAtOverride: Date? = nil) {
        let sampleDate = state == .active ? now() : nil
        let heartRate = state == .active ? samples[sampleIndex] : nil
        onSnapshot?(
            WorkoutSnapshot(
                state: state,
                startedAt: startedAtOverride ?? startedAt,
                heartRateBPM: heartRate,
                heartRateSampleDate: sampleDate
            )
        )
    }
}

@MainActor
public final class FakeLocationProvider: LocationDataProviding {
    public var onLocation: ((LocationReading) -> Void)?
    public var authorizationError: Error?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    private let automaticallyAdvance: Bool
    private let now: () -> Date
    private var locationIndex = 0
    private var locationTask: Task<Void, Never>?
    private let route: [(Double, Double)]

    public init(
        route: [(Double, Double)] = [
            (10.7765, 106.7009),
            (10.7767, 106.7011),
            (10.7769, 106.7014)
        ],
        automaticallyAdvance: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.route = route.isEmpty ? [(10.7765, 106.7009)] : route
        self.automaticallyAdvance = automaticallyAdvance
        self.now = now
    }

    public func requestAuthorization() async throws {
        if let authorizationError {
            throw authorizationError
        }
    }

    public func startUpdatingLocation() {
        startCount += 1
        locationIndex = 0
        emitCurrentLocation()

        if automaticallyAdvance {
            locationTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }
                    self.emitNextLocation()
                }
            }
        }
    }

    public func stopUpdatingLocation() {
        stopCount += 1
        locationTask?.cancel()
        locationTask = nil
    }

    public func emitNextLocation() {
        locationIndex = (locationIndex + 1) % route.count
        emitCurrentLocation()
    }

    private func emitCurrentLocation() {
        let coordinate = route[locationIndex]
        onLocation?(
            LocationReading(
                latitude: coordinate.0,
                longitude: coordinate.1,
                horizontalAccuracyMeters: 8,
                timestamp: now(),
                speedMetersPerSecond: 2.5
            )
        )
    }
}


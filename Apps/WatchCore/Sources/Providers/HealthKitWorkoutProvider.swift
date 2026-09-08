import Foundation
import HealthKit
import SafeRunDomain

@MainActor
public final class HealthKitWorkoutProvider: NSObject, WorkoutDataProviding {
    public var onSnapshot: ((WorkoutSnapshot) -> Void)?
    public var onMirroringError: ((String) -> Void)?

    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var startedAt: Date?
    private var latestHeartRateBPM: Double?
    private var latestHeartRateDate: Date?

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        super.init()
    }

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WorkoutProviderError.healthDataUnavailable
        }
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            throw WorkoutProviderError.healthDataUnavailable
        }

        let workoutType = HKObjectType.workoutType()
        let readTypes: Set<HKObjectType> = [heartRateType]
        let shareTypes: Set<HKSampleType> = [workoutType]

        try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)

        guard healthStore.authorizationStatus(for: workoutType) == .sharingAuthorized else {
            throw WorkoutProviderError.workoutAuthorizationDenied
        }
    }

    public func startWorkout(at date: Date) async throws {
        guard session == nil else {
            throw WorkoutProviderError.workoutAlreadyActive
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor

        let session = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: configuration
        )
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder
        self.startedAt = date
        latestHeartRateBPM = nil
        latestHeartRateDate = nil
        emit(state: .preparing)

        session.startActivity(with: date)

        do {
            try await beginCollection(builder, at: date)
            session.startMirroringToCompanionDevice { [weak self] success, error in
                guard !success else { return }
                Task { @MainActor in
                    self?.onMirroringError?(
                        error?.localizedDescription ?? "Workout mirroring unavailable."
                    )
                }
            }
            emit(state: .active)
        } catch {
            session.end()
            clearActiveWorkout()
            emit(state: .failed)
            throw WorkoutProviderError.collectionFailed
        }
    }

    public func stopWorkout(at date: Date) async throws -> WorkoutSummary {
        guard let session, let builder, let startedAt else {
            throw WorkoutProviderError.noActiveWorkout
        }

        session.end()

        do {
            try await endCollection(builder, at: date)
        } catch {
            clearActiveWorkout()
            emit(state: .failed)
            throw WorkoutProviderError.collectionFailed
        }

        let workout: HKWorkout
        do {
            workout = try await finishWorkout(builder)
        } catch {
            clearActiveWorkout()
            emit(state: .failed)
            throw WorkoutProviderError.saveFailed
        }

        let summary = WorkoutSummary(
            startedAt: startedAt,
            endedAt: date,
            savedWorkoutID: workout.uuid
        )
        clearActiveWorkout()
        emit(state: .ended)
        return summary
    }

    private func beginCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: date) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WorkoutProviderError.collectionFailed)
                }
            }
        }
    }

    private func endCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: date) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WorkoutProviderError.collectionFailed)
                }
            }
        }
    }

    private func finishWorkout(_ builder: HKLiveWorkoutBuilder) async throws -> HKWorkout {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HKWorkout, Error>) in
            builder.finishWorkout { workout, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let workout {
                    continuation.resume(returning: workout)
                } else {
                    continuation.resume(throwing: WorkoutProviderError.saveFailed)
                }
            }
        }
    }

    private func handleSessionState(_ state: HKWorkoutSessionState) {
        switch state {
        case .notStarted:
            emit(state: .preparing)
        case .running:
            emit(state: .active)
        case .paused:
            emit(state: .paused)
        case .ended:
            emit(state: .ended)
        @unknown default:
            break
        }
    }

    private func handleHeartRate(_ beatsPerMinute: Double, sampleDate: Date) {
        latestHeartRateBPM = beatsPerMinute
        latestHeartRateDate = sampleDate
        emit(state: .active)
    }

    private func handleFailure() {
        clearActiveWorkout()
        emit(state: .failed)
    }

    private func emit(state: RunState) {
        onSnapshot?(
            WorkoutSnapshot(
                state: state,
                startedAt: startedAt,
                heartRateBPM: latestHeartRateBPM,
                heartRateSampleDate: latestHeartRateDate
            )
        )
    }

    private func clearActiveWorkout() {
        session = nil
        builder = nil
    }
}

extension HealthKitWorkoutProvider: HKWorkoutSessionDelegate {
    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            self?.handleSessionState(toState)
        }
    }

    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.handleFailure()
        }
    }
}

extension HealthKitWorkoutProvider: HKLiveWorkoutBuilderDelegate {
    nonisolated public func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {}

    nonisolated public func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity() else {
            return
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let beatsPerMinute = quantity.doubleValue(for: unit)
        let sampleDate = statistics.endDate

        Task { @MainActor [weak self] in
            self?.handleHeartRate(beatsPerMinute, sampleDate: sampleDate)
        }
    }
}

import Combine
import Foundation
import HealthKit

@MainActor
public final class RemoteWorkoutCoordinator: NSObject, ObservableObject {
    @Published public private(set) var state = "waiting"
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var lastError: String?

    private let healthStore: HKHealthStore
    private var mirroredSession: HKWorkoutSession?

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        super.init()
    }

    public func activate() {
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in self?.accept(session) }
        }
    }

    private func accept(_ session: HKWorkoutSession) {
        mirroredSession?.delegate = nil
        mirroredSession = session
        session.delegate = self
        startedAt = session.startDate
        state = String(describing: session.state)
        lastError = nil
    }
}

extension RemoteWorkoutCoordinator: HKWorkoutSessionDelegate {
    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            self?.state = String(describing: toState)
            if self?.startedAt == nil { self?.startedAt = workoutSession.startDate }
        }
    }

    nonisolated public func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.state = "failed"
            self?.lastError = error.localizedDescription
        }
    }
}

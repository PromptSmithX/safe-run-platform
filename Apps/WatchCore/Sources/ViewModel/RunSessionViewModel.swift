import Combine
import Foundation
import SafeRunDomain

@MainActor
public final class RunSessionViewModel: ObservableObject {
    @Published public private(set) var state: RunState = .idle
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var heartRateBPM: Double?
    @Published public private(set) var heartRateSampleDate: Date?
    @Published public private(set) var latestLocation: LocationReading?
    @Published public private(set) var locationAvailable = true
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastSummary: WorkoutSummary?
    @Published public private(set) var transportSessionID: String?
    @Published public private(set) var lastPacketSequence: Int?

    private let workoutProvider: any WorkoutDataProviding
    private let locationProvider: any LocationDataProviding
    private let safetyConfig: RunnerSafetyConfig
    private let locationPolicy: LocationQualityPolicy
    private let now: () -> Date
    private var packetCoordinator: WatchRunPacketCoordinator?

    public init(
        workoutProvider: any WorkoutDataProviding,
        locationProvider: any LocationDataProviding,
        safetyConfig: RunnerSafetyConfig = RunnerSafetyConfig(),
        locationPolicy: LocationQualityPolicy = LocationQualityPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.workoutProvider = workoutProvider
        self.locationProvider = locationProvider
        self.safetyConfig = safetyConfig
        self.locationPolicy = locationPolicy
        self.now = now

        workoutProvider.onSnapshot = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        locationProvider.onLocation = { [weak self] reading in
            self?.latestLocation = reading
            self?.locationAvailable = true
        }
    }

    public func attachPacketCoordinator(_ coordinator: WatchRunPacketCoordinator) {
        packetCoordinator = coordinator
        coordinator.onSessionProgress = { [weak self] sessionID, sequence in
            self?.transportSessionID = sessionID
            self?.lastPacketSequence = sequence
        }
    }

    public func start() async {
        guard state == .idle || state == .ended || state == .failed else {
            return
        }

        state = .preparing
        errorMessage = nil
        lastSummary = nil
        latestLocation = nil
        locationAvailable = true

        do {
            try await workoutProvider.requestAuthorization()
        } catch {
            fail(with: error)
            return
        }

        do {
            try await locationProvider.requestAuthorization()
        } catch {
            locationAvailable = false
        }

        let startDate = now()
        do {
            try await workoutProvider.startWorkout(at: startDate)
            startedAt = startDate
            state = .active
            if locationAvailable {
                locationProvider.startUpdatingLocation()
            }
            await packetCoordinator?.runDidStart()
        } catch {
            locationProvider.stopUpdatingLocation()
            fail(with: error)
        }
    }

    public func stop() async {
        guard state == .active || state == .paused else {
            return
        }

        state = .ending
        locationProvider.stopUpdatingLocation()

        do {
            lastSummary = try await workoutProvider.stopWorkout(at: now())
            state = .ended
        } catch {
            fail(with: error)
        }
        await packetCoordinator?.runDidEnd()
    }

    public func reset() {
        guard state == .ended || state == .failed else {
            return
        }

        state = .idle
        startedAt = nil
        heartRateBPM = nil
        heartRateSampleDate = nil
        latestLocation = nil
        locationAvailable = true
        errorMessage = nil
        lastSummary = nil
    }

    public func elapsedSeconds(at date: Date) -> Int {
        guard let startedAt else {
            return 0
        }
        return max(0, Int(date.timeIntervalSince(startedAt)))
    }

    public func displayedHeartRate(at date: Date) -> Double? {
        guard let heartRateBPM, let heartRateSampleDate else {
            return nil
        }
        let age = date.timeIntervalSince(heartRateSampleDate)
        guard age >= 0, age <= TimeInterval(safetyConfig.staleHeartRateSeconds) else {
            return nil
        }
        return heartRateBPM
    }

    public func locationStatus(at date: Date) -> LocationDisplayStatus {
        guard locationAvailable else {
            return .unavailable
        }
        guard let latestLocation else {
            return .waiting
        }

        let age = date.timeIntervalSince(latestLocation.timestamp)
        return age >= 0 && age <= locationPolicy.maximumAge ? .fresh : .stale
    }

    public func telemetrySample() -> RunTelemetrySample? {
        guard state == .active, let startedAt else { return nil }
        return RunTelemetrySample(
            startedAt: startedAt,
            heartRateBPM: heartRateBPM,
            heartRateSampleDate: heartRateSampleDate,
            location: latestLocation
        )
    }

    private func apply(_ snapshot: WorkoutSnapshot) {
        if state != .ending {
            state = snapshot.state
        }
        startedAt = snapshot.startedAt ?? startedAt
        heartRateBPM = snapshot.heartRateBPM
        heartRateSampleDate = snapshot.heartRateSampleDate
    }

    private func fail(with error: Error) {
        state = .failed
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

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
    @Published public private(set) var ruleState: HighHeartRateRuleState = .disabled
    @Published public private(set) var activeConfigurationRevision: Int?
    private var safetyConfig: RunnerSafetyConfig
    private var pendingConfiguration: RunnerSafetyConfigurationEnvelope?
    private var heartRateRule = SustainedHighHeartRateRule()
    private var checkInCoordinator: CheckInCoordinator?
    private let locationPolicy: LocationQualityPolicy
    private let now: () -> Date
    private var packetCoordinator: WatchRunPacketCoordinator?
    private var recoveryAwaitingCheckInResolution = false

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

    public func attachCheckInCoordinator(_ coordinator: CheckInCoordinator) { checkInCoordinator = coordinator }
    public func stageSafetyConfiguration(_ envelope: RunnerSafetyConfigurationEnvelope) { pendingConfiguration = envelope }

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
        if let pendingConfiguration { safetyConfig = pendingConfiguration.config; activeConfigurationRevision = pendingConfiguration.revision }
        heartRateRule.resetForRun()
        do {
            try await workoutProvider.startWorkout(at: startDate)
            startedAt = startDate
            state = .active
            if locationAvailable {
                locationProvider.startUpdatingLocation()
            }
            await packetCoordinator?.runDidStart(configuration: pendingConfiguration)
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

    public func recoverActiveRun() async {
        guard state == .idle || state == .failed else { return }
        state = .recovering
        do {
            guard let snapshot = try await workoutProvider.recoverWorkout() else {
                guard let local = await packetCoordinator?.recoverySnapshot() else { state = .idle; return }
                if let savedCheckIn = local.checkIn, savedCheckIn.terminalOutcome == nil {
                    recoveryAwaitingCheckInResolution = true
                    await checkInCoordinator?.restore(savedCheckIn, at: now())
                } else {
                    await packetCoordinator?.runDidEnd()
                    state = .ended
                }
                return
            }
            startedAt = snapshot.startedAt
            state = snapshot.state
            if locationAvailable { locationProvider.startUpdatingLocation() }
            if let recovery = await packetCoordinator?.recoverRun(startedAt: snapshot.startedAt ?? now()), let savedCheckIn = recovery.checkIn, savedCheckIn.terminalOutcome == nil {
                await checkInCoordinator?.restore(savedCheckIn, at: now())
            }
        } catch { fail(with: error) }
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
        evaluateHeartRateRule(at: now())
    }

    private func evaluateHeartRateRule(at date: Date) {
        guard let startedAt else { return }
        let activeCheckIn: Bool
        if case .some(.active) = checkInCoordinator?.state { activeCheckIn = true } else { activeCheckIn = false }
        let trigger = heartRateRule.evaluate(
            sample: HeartRateRuleSample(bpm: heartRateBPM, sampledAt: heartRateSampleDate),
            runStartedAt: startedAt, runState: state, now: date, config: safetyConfig, checkInActive: activeCheckIn
        )
        ruleState = heartRateRule.state
        guard let trigger, let checkInCoordinator else { return }
        Task { await checkInCoordinator.startCheckIn(reason: .sustainedHighHeartRate, evaluation: trigger.evaluation, timeoutSeconds: safetyConfig.checkInSeconds, at: date) }
    }

    public func checkInResolved(_ resolution: CheckInResolution) {
        switch resolution {
        case .ok: heartRateRule.runnerIsOK(at: now(), config: safetyConfig)
        case .help, .timeout, .superseded: heartRateRule.escalationCompleted()
        }
        ruleState = heartRateRule.state
        if recoveryAwaitingCheckInResolution && resolution != .superseded {
            recoveryAwaitingCheckInResolution = false
            Task { await packetCoordinator?.runDidEnd(); state = .ended }
        }
    }

    public func manualSOSQueuedDuringRecovery() {
        guard recoveryAwaitingCheckInResolution else { return }
        recoveryAwaitingCheckInResolution = false
        Task { await packetCoordinator?.runDidEnd(); state = .ended }
    }

    private func fail(with error: Error) {
        state = .failed
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

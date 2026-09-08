import Combine
import SafeRunDomain
import SafeRunWatchCore
import SwiftUI
import WatchKit

@main
@MainActor
struct SafeRunWatchApplication: App {
    @WKExtensionDelegateAdaptor(SafeRunWatchExtensionDelegate.self) private var extensionDelegate
    @StateObject private var viewModel: RunSessionViewModel
    @StateObject private var transport: WatchConnectivityTransport
    @StateObject private var sos: ManualSOSController
    @StateObject private var checkIn: CheckInCoordinator

    init() {
        let providers = WatchProviderFactory.make()
        #if DEBUG
        let debugRule = ProcessInfo.processInfo.arguments.contains("-SafeRunRuleTest")
        let initialConfig = debugRule
            ? RunnerSafetyConfig(highHRThresholdBPM: 170, highHRSustainedSeconds: 5, checkInSeconds: 10, ruleCooldownSeconds: 10, warmUpSeconds: 0, highHRRearmSeconds: 5, minimumHighHRSamples: 3)
            : RunnerSafetyConfig()
        #else
        let initialConfig = RunnerSafetyConfig()
        #endif
        let viewModel = RunSessionViewModel(
            workoutProvider: providers.workout,
            locationProvider: providers.location,
            safetyConfig: initialConfig
        )
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let persistence = WatchRunPersistence(
            fileURL: support.appendingPathComponent("watch-run-v2.json"),
            legacyQueueURL: support.appendingPathComponent("watch-packets.json"),
            legacyRunURL: support.appendingPathComponent("active-run.json")
        )
        let configStore = WatchSafetyConfigStore(fileURL: support.appendingPathComponent("safety-config.json"))
        let chaos = DebugChaosController()
        let transport = WatchConnectivityTransport(persistence: persistence, configurationStore: configStore, chaos: chaos.configuration)
        let coordinator = WatchRunPacketCoordinator(
            transport: transport,
            persistence: persistence,
            sample: { [weak viewModel] in viewModel?.telemetrySample() },
            chaos: chaos
        )
        viewModel.attachPacketCoordinator(coordinator)
        let checkIn = CheckInCoordinator(dispatcher: coordinator)
        checkIn.onResolved = { [weak viewModel] resolution in viewModel?.checkInResolved(resolution) }
        viewModel.attachCheckInCoordinator(checkIn)
        transport.onSafetyConfiguration = { [weak viewModel] envelope in viewModel?.stageSafetyConfiguration(envelope) }
        #if DEBUG
        if !debugRule { Task { if let envelope = await configStore.load() { viewModel.stageSafetyConfiguration(envelope) } } }
        #else
        Task { if let envelope = await configStore.load() { viewModel.stageSafetyConfiguration(envelope) } }
        #endif
        let sos = ManualSOSController(dispatcher: coordinator)
        sos.onQueued = { [weak viewModel] _ in viewModel?.manualSOSQueuedDuringRecovery() }
        transport.activate()
        _viewModel = StateObject(wrappedValue: viewModel)
        _transport = StateObject(wrappedValue: transport)
        _sos = StateObject(wrappedValue: sos)
        _checkIn = StateObject(wrappedValue: checkIn)
    }

    var body: some Scene {
        WindowGroup {
            RunSessionView(viewModel: viewModel, transport: transport, sos: sos, checkIn: checkIn)
                .task { await viewModel.recoverActiveRun() }
                .onReceive(NotificationCenter.default.publisher(for: .safeRunRecoverActiveWorkout)) { _ in
                    Task { await viewModel.recoverActiveRun() }
                }
        }
    }
}

private extension Notification.Name { static let safeRunRecoverActiveWorkout = Notification.Name("SafeRunRecoverActiveWorkout") }

final class SafeRunWatchExtensionDelegate: NSObject, WKExtensionDelegate {
    func handleActiveWorkoutRecovery() {
        NotificationCenter.default.post(name: .safeRunRecoverActiveWorkout, object: nil)
    }
}

@MainActor
private enum WatchProviderFactory {
    static func make() -> (
        workout: any WorkoutDataProviding,
        location: any LocationDataProviding
    ) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SafeRunRuleTest") {
            return (FakeWorkoutProvider(samples: [175, 178, 181, 179, 182, 180]), FakeLocationProvider())
        }
        if isSimulator || ProcessInfo.processInfo.arguments.contains("-SafeRunFakeData") {
            return (
                FakeWorkoutProvider(),
                FakeLocationProvider()
            )
        }
        #endif

        return (
            HealthKitWorkoutProvider(),
            WatchLocationProvider()
        )
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

private struct RunSessionView: View {
    @ObservedObject var viewModel: RunSessionViewModel
    @ObservedObject var transport: WatchConnectivityTransport
    @ObservedObject var sos: ManualSOSController
    @ObservedObject var checkIn: CheckInCoordinator
    @State private var isHoldingSOS = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                idleView
            case .preparing, .recovering:
                progressView(message: "Preparing run…")
            case .active, .paused:
                activeView
            case .ending:
                progressView(message: "Saving workout…")
            case .ended:
                endedView
            case .failed:
                failedView
            }
        }
        .padding(.horizontal, 6)
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)

            Text("Safe Run")
                .font(.headline)

            Button("Start run") {
                Task {
                    sos.resetForRun()
                    checkIn.resetForRun()
                    await viewModel.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityHint("Starts an outdoor running workout")
        }
    }

    private var activeView: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if case .active(let checkInContext) = checkIn.state {
                checkInView(checkInContext, now: context.date)
            } else {
            VStack(spacing: 5) {
                Text(heartRateText(at: context.date))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(durationText(seconds: viewModel.elapsedSeconds(at: context.date)))
                    .font(.headline.monospacedDigit())

                Label(
                    locationText(at: context.date),
                    systemImage: locationSymbol(at: context.date)
                )
                .font(.caption2)
                .foregroundStyle(locationColor(at: context.date))

                Text(transportStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                if let detail = transportDetail {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(transport.diagnostics.lastError == nil ? .secondary : .orange)
                        .lineLimit(1)
                }

                if let sessionID = viewModel.transportSessionID,
                   let sequence = viewModel.lastPacketSequence {
                    Text("…\(sessionID.suffix(5)) #\(sequence)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }

                Text("Config r\(viewModel.activeConfigurationRevision ?? 0) • \(String(describing: viewModel.ruleState))")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)

                sosControls

                Button("Stop") {
                    Task {
                        await viewModel.stop()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityHint("Stops and saves the current workout")
            }
            }
        }
    }

    private func checkInView(_ context: CheckInContext, now: Date) -> some View {
        let remaining = max(0, Int(ceil(context.deadline.timeIntervalSince(now))))
        return VStack(spacing: 8) {
            Image(systemName: "heart.text.square.fill").font(.title).foregroundStyle(.orange)
            Text("Bạn có ổn không?").font(.headline)
            Text("\(remaining)s").font(.title.monospacedDigit())
            Button("Tôi ổn") { Task { await checkIn.userOK() } }.buttonStyle(.borderedProminent).tint(.green)
            Button("Gọi người thân") { Task { await checkIn.userRequestsHelp() } }.buttonStyle(.borderedProminent).tint(.red)
            Button("Giữ SOS 2 giây") { }
                .buttonStyle(.bordered)
                .onLongPressGesture(minimumDuration: 2) {
                    checkIn.supersedeWithManualSOS()
                    WKInterfaceDevice.current().play(.notification)
                    Task { await sos.trigger() }
                }
        }
        .task(id: remaining) {
            if remaining == 20 { WKInterfaceDevice.current().play(.notification) }
            if (1...3).contains(remaining) { WKInterfaceDevice.current().play(.click) }
            await checkIn.tick(at: now)
        }
    }

    @ViewBuilder
    private var sosControls: some View {
        switch sos.state {
        case .idle, .failed:
            VStack(spacing: 3) {
                Button {
                    // Long press below is the deliberate activation path.
                } label: {
                    Label(isHoldingSOS ? "Tiếp tục giữ…" : "Giữ SOS 2 giây", systemImage: "sos.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .onLongPressGesture(minimumDuration: 2, maximumDistance: 30) {
                    isHoldingSOS = false
                    WKInterfaceDevice.current().play(.notification)
                    checkIn.supersedeWithManualSOS()
                    Task { await sos.trigger() }
                } onPressingChanged: { pressing in
                    isHoldingSOS = pressing
                }
                .accessibilityLabel("SOS")
                .accessibilityHint("Giữ hai giây để xếp hàng cảnh báo cho người thân")

                if case .failed(let message) = sos.state {
                    Text(message).font(.system(size: 8)).foregroundStyle(.orange)
                }
            }
        case .queueing:
            ProgressView("Đang xếp hàng SOS…")
        case .queued(let receipt):
            VStack(spacing: 3) {
                Text("SOS đã xếp hàng • …\(receipt.incidentID.uuidString.suffix(6))")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Button("Hủy cảnh báo") { Task { await sos.cancel() } }
                    .buttonStyle(.bordered)
            }
        case .cancelling:
            ProgressView("Đang xếp hàng yêu cầu hủy…")
        case .cancellationQueued:
            VStack(spacing: 3) {
                Text("Yêu cầu hủy đã xếp hàng")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Button("Xong") { sos.resetAfterCancellation() }
            }
        }
    }

    private var transportStatus: String {
        let connection = transport.diagnostics.isReachable ? "Phone online" : "Phone offline"
        let critical = transport.diagnostics.queueCounts[.critical, default: 0]
        let telemetry = transport.diagnostics.queueCounts[.telemetry, default: 0]
        return "\(connection) • P0 \(critical) • P3 \(telemetry)"
    }

    private var transportDetail: String? {
        if let error = transport.diagnostics.lastError { return "Transport: \(error)" }
        if let id = transport.diagnostics.lastAcknowledgedPacketID {
            return "ACK …\(id.uuidString.suffix(6))"
        }
        return nil
    }

    private func progressView(message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
    }

    private var endedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)

            Text(viewModel.lastSummary?.savedWorkoutID == nil
                ? "Run ended"
                : "Workout saved")
                .font(.headline)

            Button("Done") {
                viewModel.reset()
            }
        }
    }

    private var failedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(viewModel.errorMessage ?? "Unable to start Safe Run.")
                .font(.caption)
                .multilineTextAlignment(.center)

            Button("Back") {
                viewModel.reset()
            }
        }
    }

    private func heartRateText(at date: Date) -> String {
        guard let heartRate = viewModel.displayedHeartRate(at: date) else {
            return "—"
        }
        return String(Int(heartRate.rounded()))
    }

    private func durationText(seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func locationText(at date: Date) -> String {
        switch viewModel.locationStatus(at: date) {
        case .unavailable:
            return "Location unavailable"
        case .waiting:
            return "Waiting for GPS"
        case .fresh:
            return "GPS ready"
        case .stale:
            return "GPS stale"
        }
    }

    private func locationSymbol(at date: Date) -> String {
        viewModel.locationStatus(at: date) == .fresh
            ? "location.fill"
            : "location.slash"
    }

    private func locationColor(at date: Date) -> Color {
        viewModel.locationStatus(at: date) == .fresh
            ? .green
            : .secondary
    }
}

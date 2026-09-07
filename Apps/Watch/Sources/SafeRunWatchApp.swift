import SafeRunDomain
import SafeRunWatchCore
import SwiftUI

@main
@MainActor
struct SafeRunWatchApplication: App {
    @StateObject private var viewModel: RunSessionViewModel

    init() {
        let providers = WatchProviderFactory.make()
        _viewModel = StateObject(
            wrappedValue: RunSessionViewModel(
                workoutProvider: providers.workout,
                locationProvider: providers.location
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RunSessionView(viewModel: viewModel)
        }
    }
}

@MainActor
private enum WatchProviderFactory {
    static func make() -> (
        workout: any WorkoutDataProviding,
        location: any LocationDataProviding
    ) {
        #if DEBUG
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

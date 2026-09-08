import SafeRunDomain
import SafeRunPhoneCore
import SwiftUI

@main
@MainActor
struct SafeRunIOSApp: App {
    @StateObject private var bridge: PhoneWatchBridge
    @StateObject private var mirroring: RemoteWorkoutCoordinator

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let queue = try? SQLiteGatewayQueue(
            databaseURL: support.appendingPathComponent("phone-gateway.sqlite")
        )
        let bridge = PhoneWatchBridge(queue: queue)
        let mirroring = RemoteWorkoutCoordinator()
        bridge.activate()
        mirroring.activate()
        _bridge = StateObject(wrappedValue: bridge)
        _mirroring = StateObject(wrappedValue: mirroring)
    }

    var body: some Scene {
        WindowGroup {
            IOSBootstrapView(bridge: bridge, mirroring: mirroring)
        }
    }
}

private struct IOSBootstrapView: View {
    @ObservedObject var bridge: PhoneWatchBridge
    @ObservedObject var mirroring: RemoteWorkoutCoordinator

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.red)

            Text("Safe Run")
                .font(.title.bold())

            Text("iPhone companion")
                .foregroundStyle(.secondary)

            GroupBox("Watch transport") {
                VStack(alignment: .leading, spacing: 6) {
                    diagnostic("Activation", bridge.diagnostics.activationState)
                    diagnostic("Paired", bridge.diagnostics.isPaired ? "yes" : "no")
                    diagnostic("Watch app", bridge.diagnostics.isWatchAppInstalled ? "installed" : "missing")
                    diagnostic("Reachable", bridge.diagnostics.isReachable ? "yes" : "no")
                    diagnostic("Durable queue", "\(bridge.diagnostics.queueDepth) packets")
                    diagnostic(
                        "Priority queues",
                        "P0 \(bridge.diagnostics.queueCounts[.critical, default: 0]) / P3 \(bridge.diagnostics.queueCounts[.telemetry, default: 0])"
                    )
                    diagnostic("Last packet", bridge.diagnostics.lastPacketID?.uuidString ?? "none")
                    if let error = bridge.diagnostics.lastError {
                        diagnostic("Last error", error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Workout recovery") {
                diagnostic("Mirrored state", mirroring.state)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private func diagnostic(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.caption)
    }
}

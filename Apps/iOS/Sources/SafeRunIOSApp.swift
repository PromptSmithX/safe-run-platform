import SafeRunDomain
import SafeRunPhoneCore
import SwiftUI

@main
@MainActor
struct SafeRunIOSApp: App {
    @StateObject private var bridge: PhoneWatchBridge
    @StateObject private var mirroring: RemoteWorkoutCoordinator
    @StateObject private var uploader: PhoneUploadController

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
        let uploader = PhoneUploadController(queue: queue, bridge: bridge)
        bridge.activate()
        mirroring.activate()
        _bridge = StateObject(wrappedValue: bridge)
        _mirroring = StateObject(wrappedValue: mirroring)
        _uploader = StateObject(wrappedValue: uploader)
    }

    var body: some Scene {
        WindowGroup {
            IOSBootstrapView(bridge: bridge, mirroring: mirroring, uploader: uploader)
        }
    }
}

private struct IOSBootstrapView: View {
    @ObservedObject var bridge: PhoneWatchBridge
    @ObservedObject var mirroring: RemoteWorkoutCoordinator
    @ObservedObject var uploader: PhoneUploadController

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

            GroupBox("Backend upload") {
                VStack(alignment: .leading, spacing: 6) {
                    diagnostic("Auth/config", uploader.configurationStatus)
                    diagnostic("Worker", uploader.diagnostics.isDraining ? "uploading" : "idle")
                    diagnostic("Server session", uploader.diagnostics.lastServerSessionID ?? "none")
                    diagnostic("Last result", uploader.diagnostics.lastHTTPResult ?? "none")
                    diagnostic("Attempts", "\(uploader.diagnostics.attemptCount)")
                    diagnostic(
                        "Next retry",
                        uploader.diagnostics.nextRetryAt?.formatted(date: .omitted, time: .standard) ?? "none"
                    )
                    diagnostic("Terminal", "\(uploader.diagnostics.terminalCount)")
                    if let error = uploader.diagnostics.lastErrorCode { diagnostic("Upload error", error) }
                    Button("Retry now") { uploader.retryNow() }
                }
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

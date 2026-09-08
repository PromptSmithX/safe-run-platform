import SafeRunDomain
import SafeRunPhoneCore
import FirebaseMessaging
import SwiftUI
import UIKit

@main
@MainActor
struct SafeRunIOSApp: App {
    @UIApplicationDelegateAdaptor(SafeRunApplicationDelegate.self) private var appDelegate
    @StateObject private var bridge: PhoneWatchBridge
    @StateObject private var mirroring: RemoteWorkoutCoordinator
    @StateObject private var uploader: PhoneUploadController
    @StateObject private var caregiver: CaregiverNotificationController

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
        _caregiver = StateObject(wrappedValue: CaregiverNotificationController())
    }

    var body: some Scene {
        WindowGroup {
            IOSBootstrapView(bridge: bridge, mirroring: mirroring, uploader: uploader, caregiver: caregiver)
        }
    }
}

private final class SafeRunApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }
}

private struct IOSBootstrapView: View {
    @ObservedObject var bridge: PhoneWatchBridge
    @ObservedObject var mirroring: RemoteWorkoutCoordinator
    @ObservedObject var uploader: PhoneUploadController
    @ObservedObject var caregiver: CaregiverNotificationController
    @AppStorage("SafeRunAppRole") private var role = DeviceRole.runner.rawValue

    var body: some View {
        NavigationStack {
        VStack(spacing: 12) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.red)

            Text("Safe Run")
                .font(.title.bold())

            Picker("Role", selection: $role) {
                Text("Runner").tag(DeviceRole.runner.rawValue)
                Text("Caregiver").tag(DeviceRole.caregiver.rawValue)
            }
            .pickerStyle(.segmented)

            Text(role == DeviceRole.caregiver.rawValue ? "Caregiver" : "iPhone companion")
                .foregroundStyle(.secondary)

            if role == DeviceRole.caregiver.rawValue {
                caregiverView
            } else {
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
        }
        .padding()
        .navigationDestination(item: $caregiver.selectedIncidentID) { _ in
            IncidentDetailView(controller: caregiver)
        }
        .task { caregiver.setRole(role) }
        .onChange(of: role) { _, newRole in caregiver.setRole(newRole) }
        }
    }

    private var caregiverView: some View {
        VStack(spacing: 12) {
            Text("Bật thông báo để nhận cảnh báo Safe Run từ thành viên gia đình đã được provision.")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Enable notifications") {
                Task { await caregiver.requestPermissionAndRegister() }
            }
            .buttonStyle(.borderedProminent)
            diagnostic("Registration", caregiver.registrationStatus)
            if let receivedAt = caregiver.receivedAt { diagnostic("Received", receivedAt.formatted()) }
            if let openedAt = caregiver.openedAt { diagnostic("Opened", openedAt.formatted()) }
            Button("Sign out") { Task { await caregiver.signOut() } }
                .buttonStyle(.bordered)
        }
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

private struct IncidentDetailView: View {
    @ObservedObject var controller: CaregiverNotificationController
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let incident = controller.incident {
                Section("Safe Run incident") {
                    LabeledContent("Reason", value: reason(incident.type))
                    LabeledContent("Status", value: incident.status.rawValue)
                    LabeledContent("Event time", value: (incident.runnerEventAt ?? incident.createdAt).formatted())
                    LabeledContent("Heart rate at event", value: incident.context?.heartRateBPM.map { "\(Int($0.rounded())) BPM" } ?? "Unavailable")
                    LabeledContent("Last location", value: location(incident.context?.lastLocation))
                }
                Section {
                    Button("Đã xem") { Task { await controller.acknowledge() } }
                        .disabled(incident.status != .alerted)
                    Button("Gọi \(incident.runnerDisplayName ?? "runner")") {
                        if let phone = incident.runnerPhoneE164, let url = URL(string: "tel:\(phone)") { openURL(url) }
                    }
                    .disabled(!validPhone(incident.runnerPhoneE164))
                }
            } else if let error = controller.incidentError {
                Text(error).foregroundStyle(.orange)
                Button("Retry") { Task { await controller.loadSelectedIncident() } }
            } else {
                ProgressView("Loading incident…")
            }
        }
        .navigationTitle("Incident")
        .task { await controller.loadSelectedIncident() }
    }

    private func reason(_ type: SafetyEventType) -> String {
        type == .manualSOS ? "Runner requested a family check" : "Safe Run requested attention"
    }

    private func location(_ value: LastKnownLocation?) -> String {
        guard let value else { return "Unavailable" }
        return String(format: "%.5f, %.5f", value.latitude, value.longitude)
    }

    private func validPhone(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: #"^\+[1-9]\d{7,14}$"#, options: .regularExpression) != nil
    }
}

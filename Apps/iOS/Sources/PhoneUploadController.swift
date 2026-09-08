import Combine
import Foundation
import Network
import SafeRunPhoneCore
import UIKit

@MainActor
final class PhoneUploadController: ObservableObject {
    @Published private(set) var diagnostics = UploadWorkerDiagnostics()
    @Published private(set) var configurationStatus = "initializing"

    private var worker: GatewayUploadWorker?
    private var recovery: PhoneRecoveryCoordinator?
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.saferun.network-monitor")

    init(queue: SQLiteGatewayQueue?, bridge: PhoneWatchBridge) {
        guard let queue else {
            configurationStatus = "gateway storage unavailable"
            return
        }
        do {
            let baseURL = try FirebaseBootstrap.configure()
            let injection = Self.failureInjection()
            let auth = FirebaseRunnerAuthProvider()
            let credentials = KeychainIngestCredentialStore()
            let api = SafeRunAPIClient(baseURL: baseURL, injection: injection)
            let worker = GatewayUploadWorker(
                queue: queue,
                api: api,
                auth: auth,
                credentials: credentials
            )
            let recovery = PhoneRecoveryCoordinator(reconciler: PhoneSessionReconciler(queue: queue, api: api, auth: auth, credentials: credentials), worker: worker)
            self.worker = worker
            self.recovery = recovery
            configurationStatus = FirebaseBootstrap.usesEmulator ? "anonymous auth • emulator" : "anonymous auth • configured"
            Task {
                await worker.setDiagnosticsHandler { [weak self] snapshot in
                    Task { @MainActor in self?.diagnostics = snapshot }
                }
                await recovery.wake()
            }
            bridge.onPacketAccepted = { [weak self] _ in self?.drainWithBackgroundTime() }
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in self?.drainWithBackgroundTime() }
            }
            pathMonitor.start(queue: monitorQueue)
        } catch {
            configurationStatus = error.localizedDescription
        }
    }

    deinit { pathMonitor.cancel() }

    func retryNow() { drainWithBackgroundTime() }

    func attachMirroring(_ mirroring: RemoteWorkoutCoordinator) {
        mirroring.onSessionChanged = { [weak self] in self?.drainWithBackgroundTime() }
    }

    private func drainWithBackgroundTime() {
        guard let recovery else { return }
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "SafeRunUpload") {
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
            taskID = .invalid
        }
        Task {
            await recovery.wake()
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
            taskID = .invalid
        }
    }

    private static func failureInjection() -> NetworkFailureInjection {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-SafeRunNetworkDelay"), arguments.indices.contains(index + 1),
           let delay = TimeInterval(arguments[index + 1]) { return .delay(delay) }
        if arguments.contains("-SafeRunForce500") { return .forcedServerError }
        if arguments.contains("-SafeRunExpiredToken") { return .expiredToken }
        if arguments.contains("-SafeRunDuplicateRequest") { return .duplicateRequest }
        if arguments.contains("-SafeRunOffline") { return .offline }
        #endif
        return .none
    }
}

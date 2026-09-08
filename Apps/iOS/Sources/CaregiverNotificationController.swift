import FirebaseMessaging
import Combine
import Foundation
import SafeRunDomain
import SafeRunPhoneCore
import Security
import UIKit
import UserNotifications

@MainActor
final class CaregiverNotificationController: NSObject, ObservableObject {
    @Published private(set) var registrationStatus = "not enabled"
    @Published private(set) var incident: IncidentDetail?
    @Published private(set) var incidentError: String?
    @Published private(set) var receivedAt: Date?
    @Published private(set) var openedAt: Date?
    @Published var selectedIncidentID: UUID?

    private let installationID: UUID
    private let auth = FirebaseRunnerAuthProvider()
    private var coordinator: CaregiverCoordinator?
    private var notificationRouter = IncidentNotificationRouter()
    private var caregiverEnabled = false
    private var pendingToken: String?

    override init() {
        installationID = (try? DeviceInstallationIDStore().loadOrCreate()) ?? UUID()
        super.init()
        do {
            let baseURL = try FirebaseBootstrap.configure()
            coordinator = CaregiverCoordinator(
                api: SafeRunAPIClient(baseURL: baseURL),
                auth: auth
            )
            UNUserNotificationCenter.current().delegate = self
            Messaging.messaging().delegate = self
            routeDebugIncidentIfPresent()
            registerDebugTokenIfPresent()
        } catch {
            registrationStatus = error.localizedDescription
        }
    }

    func requestPermissionAndRegister() async {
        guard coordinator != nil else { return }
        caregiverEnabled = true
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                registrationStatus = "notification permission denied"
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
            registrationStatus = "waiting for FCM token"
            if let token = try? await Messaging.messaging().token() {
                await register(token: token)
            }
        } catch {
            registrationStatus = error.localizedDescription
        }
    }

    func setRole(_ role: String) {
        let wasEnabled = caregiverEnabled
        caregiverEnabled = role == DeviceRole.caregiver.rawValue
        if caregiverEnabled, let pendingToken {
            Task { await register(token: pendingToken) }
        } else if wasEnabled, let coordinator {
            Task {
                _ = try? await coordinator.deactivateDevice(id: installationID)
                registrationStatus = "not enabled"
            }
        }
    }

    func loadSelectedIncident() async {
        guard let selectedIncidentID, let coordinator else { return }
        incidentError = nil
        do {
            incident = try await coordinator.loadIncident(id: selectedIncidentID)
        } catch {
            incidentError = Self.safeError(error)
        }
    }

    func acknowledge() async {
        guard let id = incident?.incidentID, let coordinator else { return }
        do {
            _ = try await coordinator.acknowledge(id: id)
            incident = try await coordinator.loadIncident(id: id)
        } catch {
            incidentError = Self.safeError(error)
        }
    }

    func signOut() async {
        if let coordinator { _ = try? await coordinator.deactivateDevice(id: installationID) }
        try? await auth.signOut()
        registrationStatus = "signed out"
        incident = nil
        selectedIncidentID = nil
    }

    private func register(token: String) async {
        pendingToken = token
        guard caregiverEnabled else { return }
        guard let coordinator else { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            _ = try await coordinator.registerDevice(DeviceRegistrationRequest(
                deviceID: installationID, role: .caregiver, fcmToken: token, appVersion: version
            ))
            registrationStatus = "caregiver device registered"
        } catch {
            registrationStatus = Self.safeError(error)
        }
    }

    private func route(userInfo: [AnyHashable: Any], opened: Bool) {
        let strings = userInfo.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        guard let id = notificationRouter.accept(userInfo: strings) else { return }
        receivedAt = receivedAt ?? Date()
        if opened { openedAt = Date() }
        selectedIncidentID = id
        Task { await loadSelectedIncident() }
    }

    private func routeDebugIncidentIfPresent() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-SafeRunDebugPushIncident"),
           arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) {
            selectedIncidentID = id
        }
        #endif
    }

    private func registerDebugTokenIfPresent() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-SafeRunFakeFCMToken"), arguments.indices.contains(index + 1) {
            caregiverEnabled = true
            Task { await register(token: arguments[index + 1]) }
        }
        #endif
    }

    private static func safeError(_ error: Error) -> String {
        if let failure = error as? APIClientFailure { return failure.code }
        return "caregiver_request_failed"
    }
}

extension CaregiverNotificationController: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in await self.register(token: fcmToken) }
    }
}

extension CaregiverNotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { route(userInfo: notification.request.content.userInfo, opened: false) }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { route(userInfo: response.notification.request.content.userInfo, opened: true) }
    }
}

private struct DeviceInstallationIDStore {
    private let service = "com.saferun.mvp.installation"
    private let account = "device-id"

    func loadOrCreate() throws -> UUID {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let raw = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: raw) { return id }

        let id = UUID()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.uuidString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return id
    }
}

import FirebaseAuth
import FirebaseCore
import Foundation
import SafeRunPhoneCore

enum FirebaseBootstrapError: Error, LocalizedError {
    case missingConfiguration
    var errorDescription: String? { "Firebase configuration is missing." }
}

enum FirebaseBootstrap {
    static var usesEmulator: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-SafeRunFirebaseEmulator")
        #else
        false
        #endif
    }

    static func configure() throws -> URL {
        if FirebaseApp.app() == nil {
            if usesEmulator {
                let options = FirebaseOptions(
                    googleAppID: "1:1234567890:ios:0000000000000000",
                    gcmSenderID: "1234567890"
                )
                options.apiKey = "AIzaSy000000000000000000000000000000000"
                options.projectID = "demo-safe-run"
                options.bundleID = Bundle.main.bundleIdentifier
                FirebaseApp.configure(options: options)
                Auth.auth().useEmulator(withHost: "127.0.0.1", port: 9099)
            } else {
                guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
                    throw FirebaseBootstrapError.missingConfiguration
                }
                FirebaseApp.configure()
            }
        }
        if usesEmulator {
            return URL(string: "http://127.0.0.1:5001/demo-safe-run/asia-southeast1/api/")!
        }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SAFERUN_API_BASE_URL") as? String,
              let url = URL(string: raw) else {
            throw FirebaseBootstrapError.missingConfiguration
        }
        return url
    }
}

final class FirebaseRunnerAuthProvider: UserIDTokenProviding, @unchecked Sendable {
    func idToken(forceRefresh: Bool) async throws -> String {
        let user: User
        if let current = Auth.auth().currentUser {
            user = current
        } else {
            user = try await Auth.auth().signInAnonymously().user
        }
        return try await user.getIDToken(forcingRefresh: forceRefresh)
    }

    func signOut() async throws { try Auth.auth().signOut() }
}

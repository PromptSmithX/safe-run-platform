import Foundation
import SafeRunDomain

public actor PhoneSessionReconciler {
    private let queue: SQLiteGatewayQueue
    private let api: any SafeRunAPIClientProtocol
    private let auth: any UserIDTokenProviding
    private let credentials: any IngestCredentialStoring

    public init(queue: SQLiteGatewayQueue, api: any SafeRunAPIClientProtocol, auth: any UserIDTokenProviding, credentials: any IngestCredentialStoring) {
        self.queue = queue; self.api = api; self.auth = auth; self.credentials = credentials
    }

    public func reconcile(now: Date = Date()) async throws {
        let bindings = try await queue.allBindings()
        for chunk in bindings.map(\.localSessionID).chunked(maximum: 50) {
            let token = try await auth.idToken(forceRefresh: false)
            let response = try await api.reconcileSessions(SessionReconciliationRequest(clientSessionIDs: chunk), userToken: token)
            for item in response.sessions {
                try await queue.applyReconciliation(item, at: now)
                if item.status != .active, let binding = bindings.first(where: { $0.localSessionID == item.clientSessionID }) {
                    try await credentials.remove(account: binding.credentialAccount)
                }
            }
        }
        try await queue.purgeTombstones(olderThan: now.addingTimeInterval(-30 * 24 * 60 * 60))
    }
}

private extension Array {
    func chunked(maximum: Int) -> [[Element]] {
        guard maximum > 0 else { return [] }
        return stride(from: 0, to: count, by: maximum).map { Array(self[$0..<Swift.min($0 + maximum, count)]) }
    }
}

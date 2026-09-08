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
            var token = try await auth.idToken(forceRefresh: false)
            let response: SessionReconciliationResponse
            do { response = try await api.reconcileSessions(SessionReconciliationRequest(clientSessionIDs: chunk), userToken: token) }
            catch let failure as APIClientFailure where failure.statusCode == 401 {
                token = try await auth.idToken(forceRefresh: true)
                response = try await api.reconcileSessions(SessionReconciliationRequest(clientSessionIDs: chunk), userToken: token)
            }
            for item in response.sessions {
                try await queue.applyReconciliation(item, at: now)
                guard let binding = bindings.first(where: { $0.localSessionID == item.clientSessionID }) else { continue }
                if item.status != .active {
                    try await credentials.remove(account: binding.credentialAccount)
                } else if binding.expiresAt <= now.addingTimeInterval(30) || (try await credentials.token(account: binding.credentialAccount)) == nil {
                    let refreshed = try await api.createSession(CreateRunSessionRequest(clientSessionID: binding.localSessionID, appVersion: "0.1.0", configVersion: 1), userToken: token)
                    try await credentials.save(token: refreshed.ingestToken, account: binding.credentialAccount)
                    try await queue.saveBinding(SessionBinding(localSessionID: binding.localSessionID, serverSessionID: refreshed.sessionID, credentialAccount: binding.credentialAccount, expiresAt: refreshed.expiresAt, state: binding.state, lastSequence: max(binding.lastSequence, item.lastSequence)))
                }
            }
            let returned = Set(response.sessions.map(\.clientSessionID))
            for missing in bindings where chunk.contains(missing.localSessionID) && !returned.contains(missing.localSessionID) {
                try await credentials.remove(account: missing.credentialAccount)
                try await queue.removeBinding(localSessionID: missing.localSessionID)
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

import Foundation
import SafeRunDomain

public struct UploadWorkerDiagnostics: Equatable, Sendable {
    public var isDraining = false
    public var lastHTTPResult: String?
    public var lastErrorCode: String?
    public var lastLocalSessionID: String?
    public var lastServerSessionID: String?
    public var attemptCount = 0
    public var nextRetryAt: Date?
    public var terminalCount = 0

    public init() {}
}

public enum UploadDisposition: Equatable, Sendable {
    case uploaded
    case retry(Date)
    case terminal(String)
}

public actor GatewayUploadWorker {
    public var onDiagnostics: (@Sendable (UploadWorkerDiagnostics) -> Void)?

    private let queue: SQLiteGatewayQueue
    private let api: any SafeRunAPIClientProtocol
    private let auth: any UserIDTokenProviding
    private let credentials: any IngestCredentialStoring
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private var state = UploadWorkerDiagnostics()
    private var draining = false
    private var finalizationNeedsRetry = false
    private var retryTask: Task<Void, Never>?

    public init(
        queue: SQLiteGatewayQueue,
        api: any SafeRunAPIClientProtocol,
        auth: any UserIDTokenProviding,
        credentials: any IngestCredentialStoring,
        now: @escaping @Sendable () -> Date = Date.init,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.queue = queue
        self.api = api
        self.auth = auth
        self.credentials = credentials
        self.now = now
        self.random = random
    }

    public func trigger() async {
        guard !draining else { return }
        draining = true
        state.isDraining = true
        publish()
        defer {
            draining = false
            state.isDraining = false
            publish()
        }

        for _ in 0..<100 {
            do {
                guard let claim = try await queue.claimNext(now: now()) else { break }
                await process(claim)
            } catch {
                state.lastErrorCode = "QUEUE_FAILURE"
                publish()
                break
            }
        }
        await finalizeReadySessions()
        await refreshSummaryAndSchedule()
    }

    public func diagnostics() -> UploadWorkerDiagnostics { state }

    public func setDiagnosticsHandler(_ handler: (@Sendable (UploadWorkerDiagnostics) -> Void)?) {
        onDiagnostics = handler
        publish()
    }

    public func signOut() async throws {
        try await credentials.removeAll()
        try await auth.signOut()
    }

    private func process(_ claim: UploadQueueClaim) async {
        state.attemptCount = claim.attemptCount + 1
        state.lastLocalSessionID = claim.packet.sessionID
        do {
            let binding = try await ensureBinding(localSessionID: claim.packet.sessionID, force: false)
            state.lastServerSessionID = binding.serverSessionID
            guard let token = try await credentials.token(account: binding.credentialAccount) else {
                throw APIClientFailure(statusCode: 401, code: "SESSION_TOKEN_MISSING", retryable: false)
            }
            let mapped = try claim.packet.replacingSessionID(with: binding.serverSessionID)
            _ = try await api.ingest(mapped, serverSessionID: binding.serverSessionID, ingestToken: token)
            try await queue.completeUpload(
                localID: claim.localID,
                localSessionID: claim.packet.sessionID,
                sequence: claim.packet.sequence,
                marksSessionEnding: try isSessionEnded(claim.packet),
                at: now()
            )
            state.lastHTTPResult = "accepted"
            state.lastErrorCode = nil
        } catch let failure as APIClientFailure {
            if failure.statusCode == 401, claim.attemptCount == 0 {
                do {
                    _ = try await ensureBinding(localSessionID: claim.packet.sessionID, force: true)
                    try await queue.scheduleRetry(localID: claim.localID, attemptCount: 1, nextAttemptAt: now())
                    return
                } catch { }
            }
            await applyFailure(failure, to: claim)
        } catch {
            await applyFailure(APIClientFailure(statusCode: nil, code: "CLIENT_FAILURE", retryable: true), to: claim)
        }
        publish()
    }

    private func ensureBinding(localSessionID: String, force: Bool) async throws -> SessionBinding {
        if !force,
           let existing = try await queue.binding(for: localSessionID),
           existing.expiresAt > now().addingTimeInterval(30),
           try await credentials.token(account: existing.credentialAccount) != nil {
            return existing
        }
        let response: CreateRunSessionResponse
        do {
            let token = try await auth.idToken(forceRefresh: false)
            response = try await api.createSession(
                CreateRunSessionRequest(clientSessionID: localSessionID, appVersion: "0.1.0", configVersion: 1),
                userToken: token
            )
        } catch let failure as APIClientFailure where failure.statusCode == 401 {
            let token = try await auth.idToken(forceRefresh: true)
            response = try await api.createSession(
                CreateRunSessionRequest(clientSessionID: localSessionID, appVersion: "0.1.0", configVersion: 1),
                userToken: token
            )
        }
        let account = "session.\(localSessionID)"
        try await credentials.save(token: response.ingestToken, account: account)
        let binding = SessionBinding(
            localSessionID: localSessionID,
            serverSessionID: response.sessionID,
            credentialAccount: account,
            expiresAt: response.expiresAt,
            state: .active,
            lastSequence: 0
        )
        try await queue.saveBinding(binding)
        return binding
    }

    private func applyFailure(_ failure: APIClientFailure, to claim: UploadQueueClaim) async {
        state.lastHTTPResult = failure.statusCode.map(String.init) ?? "network"
        state.lastErrorCode = failure.code
        do {
            if failure.retryable || failure.statusCode == nil || failure.statusCode == 408 || failure.statusCode == 429 || (failure.statusCode ?? 0) >= 500 {
                let next = now().addingTimeInterval(failure.retryAfter ?? backoff(priority: claim.packet.priority, attempt: claim.attemptCount + 1))
                try await queue.scheduleRetry(localID: claim.localID, attemptCount: claim.attemptCount + 1, nextAttemptAt: next)
                state.nextRetryAt = next
            } else {
                try await queue.markTerminal(localID: claim.localID, code: failure.code)
            }
        } catch { state.lastErrorCode = "QUEUE_FAILURE" }
    }

    private func backoff(priority: PacketPriority, attempt: Int) -> TimeInterval {
        let base: Double = priority == .critical ? 1 : 2
        let cap: Double = priority == .critical ? 30 : 300
        return min(cap, base * pow(2, Double(max(0, min(attempt - 1, 12))))) * min(max(random(), 0), 1)
    }

    private func finalizeReadySessions() async {
        finalizationNeedsRetry = false
        guard let bindings = try? await queue.bindingsAwaitingFinalization() else { return }
        for binding in bindings {
            guard (try? await queue.canFinalize(localSessionID: binding.localSessionID)) == true,
                  let storedToken = try? await credentials.token(account: binding.credentialAccount),
                  let token = storedToken else { continue }
            do {
                try await api.endSession(
                    serverSessionID: binding.serverSessionID,
                    ingestToken: token,
                    request: EndRunSessionRequest(lastSequence: binding.lastSequence)
                )
                try await queue.markBindingEnded(localSessionID: binding.localSessionID, at: now())
                try await credentials.remove(account: binding.credentialAccount)
            } catch let failure as APIClientFailure where failure.statusCode == 401 {
                do {
                    let refreshed = try await ensureBinding(localSessionID: binding.localSessionID, force: true)
                    guard let refreshedToken = try await credentials.token(account: refreshed.credentialAccount) else {
                        throw failure
                    }
                    try await api.endSession(
                        serverSessionID: refreshed.serverSessionID,
                        ingestToken: refreshedToken,
                        request: EndRunSessionRequest(lastSequence: binding.lastSequence)
                    )
                    try await queue.markBindingEnded(localSessionID: binding.localSessionID, at: now())
                    try await credentials.remove(account: refreshed.credentialAccount)
                } catch {
                    state.lastErrorCode = (error as? APIClientFailure)?.code ?? "END_FAILED"
                    finalizationNeedsRetry = true
                }
            } catch {
                state.lastErrorCode = (error as? APIClientFailure)?.code ?? "END_FAILED"
                finalizationNeedsRetry = true
            }
        }
    }

    private func refreshSummaryAndSchedule() async {
        guard let summary = try? await queue.pendingSummary(now: now()) else { return }
        state.terminalCount = summary.terminal
        state.nextRetryAt = summary.nextAttemptAt
        publish()
        retryTask?.cancel()
        guard summary.retryable > 0 || finalizationNeedsRetry else { return }
        let next = summary.nextAttemptAt ?? now().addingTimeInterval(finalizationNeedsRetry ? 30 : 0)
        retryTask = Task { [weak self] in
            let delay = max(0, next.timeIntervalSince(now()))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.trigger()
        }
    }

    private func isSessionEnded(_ packet: TransportPacket) throws -> Bool {
        guard packet.kind == .event else { return false }
        return try SafeRunJSON.makeDecoder().decode(EventEnvelope.self, from: packet.envelopeData).payload.eventType == .sessionEnded
    }

    private func publish() { onDiagnostics?(state) }
}

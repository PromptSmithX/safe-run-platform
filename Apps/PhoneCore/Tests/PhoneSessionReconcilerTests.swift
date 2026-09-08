import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunPhoneCore

final class PhoneSessionReconcilerTests: XCTestCase {
    func testEndedSessionRemovesCredentialAndTerminalizesPendingPacket() async throws {
        let fixture = try await makeFixture(status: .ended)
        try await fixture.reconciler.reconcile(now: fixture.now)
        let token = try await fixture.credentials.token(account: fixture.binding.credentialAccount)
        let summary = try await fixture.queue.pendingSummary()
        let binding = try await fixture.queue.binding(for: fixture.binding.localSessionID)
        XCTAssertNil(token)
        XCTAssertEqual(summary.terminal, 1)
        XCTAssertEqual(binding?.state, .ended)
    }

    func testMissingMappingRemovesStaleBinding() async throws {
        let fixture = try await makeFixture(status: nil)
        try await fixture.reconciler.reconcile(now: fixture.now)
        let binding = try await fixture.queue.binding(for: fixture.binding.localSessionID)
        XCTAssertNil(binding)
    }

    private func makeFixture(status: RunSessionServerStatus?) async throws -> ReconcileFixture {
        let now = Date(timeIntervalSince1970: 100)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let queue = try SQLiteGatewayQueue(databaseURL: directory.appendingPathComponent("gateway.sqlite"))
        let binding = SessionBinding(localSessionID: "11111111-1111-4111-8111-111111111111", serverSessionID: "22222222-2222-4222-8222-222222222222", credentialAccount: "session.test", expiresAt: now.addingTimeInterval(3600), state: .active, lastSequence: 1)
        try await queue.saveBinding(binding)
        let envelope = TelemetryEnvelope(sessionID: binding.localSessionID, sequence: 2, watchTimestamp: now, payload: TelemetryPayload(elapsedSeconds: 2))
        try await queue.accept(TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope)))
        let credentials = ReconcileCredentials(); try await credentials.save(token: "secret", account: binding.credentialAccount)
        let api = ReconcileAPI(item: status.map { ReconciledRunSession(clientSessionID: binding.localSessionID, serverSessionID: binding.serverSessionID, status: $0, lastSequence: 1) })
        return ReconcileFixture(now: now, queue: queue, binding: binding, credentials: credentials, reconciler: PhoneSessionReconciler(queue: queue, api: api, auth: ReconcileAuth(), credentials: credentials))
    }
}

private struct ReconcileFixture { let now: Date; let queue: SQLiteGatewayQueue; let binding: SessionBinding; let credentials: ReconcileCredentials; let reconciler: PhoneSessionReconciler }
private struct ReconcileAuth: UserIDTokenProviding { func idToken(forceRefresh: Bool) async throws -> String { "user" }; func signOut() async throws {} }
private actor ReconcileCredentials: IngestCredentialStoring {
    var values: [String: String] = [:]
    func save(token: String, account: String) { values[account] = token }
    func token(account: String) -> String? { values[account] }
    func remove(account: String) { values.removeValue(forKey: account) }
    func removeAll() { values.removeAll() }
}
private actor ReconcileAPI: SafeRunAPIClientProtocol {
    let item: ReconciledRunSession?; init(item: ReconciledRunSession?) { self.item = item }
    func reconcileSessions(_ request: SessionReconciliationRequest, userToken: String) async throws -> SessionReconciliationResponse { .init(sessions: item.map { [$0] } ?? []) }
    func createSession(_ request: CreateRunSessionRequest, userToken: String) async throws -> CreateRunSessionResponse { try SafeRunJSON.makeDecoder().decode(CreateRunSessionResponse.self, from: Data("{\"session_id\":\"22222222-2222-4222-8222-222222222222\",\"ingest_token\":\"rotated\",\"expires_at\":\"2030-01-01T00:00:00Z\",\"server_time\":\"2026-01-01T00:00:00Z\"}".utf8)) }
    func ingest(_ packet: TransportPacket, serverSessionID: String, ingestToken: String) async throws -> IngestResponse { throw APIClientFailure(statusCode: 500, code: "unused", retryable: false) }
    func endSession(serverSessionID: String, ingestToken: String, request: EndRunSessionRequest) async throws {}
}

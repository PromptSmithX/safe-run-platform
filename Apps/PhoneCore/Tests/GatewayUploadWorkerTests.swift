import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunPhoneCore

final class GatewayUploadWorkerTests: XCTestCase {
    func testSuccessfulUploadMapsSessionAndAcknowledgesQueue() async throws {
        let fixture = try await makeFixture(apiFailure: nil)
        await fixture.worker.trigger()
        let summary = try await fixture.queue.pendingSummary()
        let uploaded = await fixture.api.uploadedPackets
        XCTAssertEqual(summary.retryable, 0)
        XCTAssertEqual(uploaded.first?.sessionID, fixture.serverSessionID)
        XCTAssertEqual(uploaded.first?.packetID, fixture.packetID)
    }

    func testRetryableFailureSchedulesBackoff() async throws {
        let failure = APIClientFailure(statusCode: 500, code: "INTERNAL", retryable: true)
        let fixture = try await makeFixture(apiFailure: failure)
        await fixture.worker.trigger()
        let summary = try await fixture.queue.pendingSummary()
        XCTAssertEqual(summary.retryable, 1)
        XCTAssertEqual(summary.terminal, 0)
        XCTAssertEqual(summary.nextAttemptAt, Date(timeIntervalSince1970: 102))
    }

    func testPermanentFailureIsRetainedAsTerminal() async throws {
        let failure = APIClientFailure(statusCode: 400, code: "INVALID_SCHEMA", retryable: false)
        let fixture = try await makeFixture(apiFailure: failure)
        await fixture.worker.trigger()
        let summary = try await fixture.queue.pendingSummary()
        XCTAssertEqual(summary.retryable, 0)
        XCTAssertEqual(summary.terminal, 1)
    }

    private func makeFixture(apiFailure: APIClientFailure?) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let queue = try SQLiteGatewayQueue(databaseURL: directory.appendingPathComponent("gateway.sqlite"))
        let envelope = TelemetryEnvelope(
            sessionID: "11111111-1111-4111-8111-111111111111", sequence: 1,
            watchTimestamp: Date(timeIntervalSince1970: 100), payload: TelemetryPayload(elapsedSeconds: 1)
        )
        let packet = try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(envelope))
        try await queue.accept(packet, at: Date(timeIntervalSince1970: 100))
        let serverSessionID = "22222222-2222-4222-8222-222222222222"
        let api = FakeAPI(serverSessionID: serverSessionID, failure: apiFailure)
        let worker = GatewayUploadWorker(
            queue: queue, api: api, auth: FakeAuth(), credentials: MemoryCredentials(),
            now: { Date(timeIntervalSince1970: 100) }, random: { 1 }
        )
        return Fixture(worker: worker, queue: queue, api: api, packetID: packet.packetID, serverSessionID: serverSessionID)
    }
}

private struct Fixture {
    let worker: GatewayUploadWorker
    let queue: SQLiteGatewayQueue
    let api: FakeAPI
    let packetID: UUID
    let serverSessionID: String
}

private actor FakeAPI: SafeRunAPIClientProtocol {
    let serverSessionID: String
    let failure: APIClientFailure?
    private(set) var uploadedPackets: [TransportPacket] = []
    init(serverSessionID: String, failure: APIClientFailure?) { self.serverSessionID = serverSessionID; self.failure = failure }
    func createSession(_ request: CreateRunSessionRequest, userToken: String) async throws -> CreateRunSessionResponse {
        let data = Data("{\"session_id\":\"\(serverSessionID)\",\"ingest_token\":\"secret\",\"expires_at\":\"2030-01-01T00:00:00Z\",\"server_time\":\"2026-01-01T00:00:00Z\"}".utf8)
        return try SafeRunJSON.makeDecoder().decode(CreateRunSessionResponse.self, from: data)
    }
    func ingest(_ packet: TransportPacket, serverSessionID: String, ingestToken: String) async throws -> IngestResponse {
        if let failure { throw failure }
        uploadedPackets.append(packet)
        return try SafeRunJSON.makeDecoder().decode(IngestResponse.self, from: Data("{\"accepted\":true}".utf8))
    }
    func endSession(serverSessionID: String, ingestToken: String, request: EndRunSessionRequest) async throws {}
    func reconcileSessions(_ request: SessionReconciliationRequest, userToken: String) async throws -> SessionReconciliationResponse {
        SessionReconciliationResponse(sessions: [])
    }
}

private struct FakeAuth: UserIDTokenProviding {
    func idToken(forceRefresh: Bool) async throws -> String { "firebase-token" }
    func signOut() async throws {}
}

private actor MemoryCredentials: IngestCredentialStoring {
    var values: [String: String] = [:]
    func save(token: String, account: String) async throws { values[account] = token }
    func token(account: String) async throws -> String? { values[account] }
    func remove(account: String) async throws { values.removeValue(forKey: account) }
    func removeAll() async throws { values.removeAll() }
}

import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunPhoneCore

final class APIClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testTelemetryUsesMappedEnvelopeAndIdempotencyHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = SafeRunAPIClient(
            baseURL: URL(string: "https://safe-run.test/")!,
            session: URLSession(configuration: configuration)
        )
        let original = TelemetryEnvelope(
            sessionID: "local", sequence: 3, watchTimestamp: Date(),
            payload: TelemetryPayload(elapsedSeconds: 10)
        )
        let packet = try TransportPacket.decodeEnvelope(SafeRunJSON.makeEncoder().encode(original))
        let mapped = try packet.replacingSessionID(with: "11111111-1111-4111-8111-111111111111")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), packet.packetID.uuidString)
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try SafeRunJSON.makeDecoder().decode(TelemetryEnvelope.self, from: body)
            XCTAssertEqual(decoded.sessionID, "11111111-1111-4111-8111-111111111111")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"accepted\":true}".utf8))
        }
        let response = try await client.ingest(mapped, serverSessionID: mapped.sessionID, ingestToken: "secret")
        XCTAssertTrue(response.accepted)
    }

    func testCaregiverDeviceRegistrationUsesUserBearerAndSnakeCaseBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = SafeRunAPIClient(
            baseURL: URL(string: "https://safe-run.test/")!,
            session: URLSession(configuration: configuration)
        )
        let deviceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/devices")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
            let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
            XCTAssertEqual(object?["device_id"] as? String, deviceID.uuidString)
            XCTAssertEqual(object?["fcm_token"] as? String, "fake-token-value")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"registered\":true,\"device_id\":\"\(deviceID.uuidString)\"}".utf8))
        }

        let result = try await client.registerDevice(
            DeviceRegistrationRequest(deviceID: deviceID, role: .caregiver, fcmToken: "fake-token-value", appVersion: "0.1.0"),
            userToken: "user-token"
        )
        XCTAssertTrue(result.registered)
        XCTAssertEqual(result.deviceID, deviceID)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler?(request) ?? { throw URLError(.badServerResponse) }()
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

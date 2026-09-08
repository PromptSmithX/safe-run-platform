import Foundation
import XCTest
@testable import SafeRunDomain

final class EnvelopeCodableTests: XCTestCase {
    func testTelemetryFixtureRoundTripsWithoutChangingIdentity() throws {
        let original = try SafeRunJSON.makeDecoder().decode(
            TelemetryEnvelope.self,
            from: fixture(named: "telemetry-v1")
        )

        let encoded = try SafeRunJSON.makeEncoder().encode(original)
        let decoded = try SafeRunJSON.makeDecoder().decode(TelemetryEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.packetID.uuidString.lowercased(), "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(decoded.sessionID, "local-session-001")
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.kind, .telemetry)
        XCTAssertEqual(decoded.payload.motionState, .running)
        XCTAssertEqual(decoded.payload.transport?.phoneReachable, true)
    }

    func testEventFixtureRoundTripsWithoutChangingIdentity() throws {
        let original = try SafeRunJSON.makeDecoder().decode(
            EventEnvelope.self,
            from: fixture(named: "event-v1")
        )

        let encoded = try SafeRunJSON.makeEncoder().encode(original)
        let decoded = try SafeRunJSON.makeDecoder().decode(EventEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.sequence, 43)
        XCTAssertEqual(decoded.payload.eventType, .manualSOS)
        XCTAssertEqual(decoded.payload.severity, .critical)
        XCTAssertEqual(
            decoded.payload.incidentID?.uuidString.lowercased(),
            "44444444-4444-4444-8444-444444444444"
        )
    }

    func testEncodedTelemetryUsesContractKeys() throws {
        let envelope = try SafeRunJSON.makeDecoder().decode(
            TelemetryEnvelope.self,
            from: fixture(named: "telemetry-v1")
        )
        let encoded = try SafeRunJSON.makeEncoder().encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])

        XCTAssertNotNil(object["schema_version"])
        XCTAssertNotNil(object["packet_id"])
        XCTAssertNotNil(object["session_id"])
        XCTAssertNotNil(object["watch_timestamp"])
        XCTAssertNotNil(payload["heart_rate_bpm"])
        XCTAssertNotNil(payload["elapsed_s"])
    }

    func testDecoderRejectsUnsupportedSchemaVersion() throws {
        let data = try modifiedFixture(
            named: "telemetry-v1",
            replacing: "\"schema_version\": 1",
            with: "\"schema_version\": 2"
        )

        XCTAssertThrowsError(
            try SafeRunJSON.makeDecoder().decode(TelemetryEnvelope.self, from: data)
        )
    }

    func testDecoderRejectsZeroSequence() throws {
        let data = try modifiedFixture(
            named: "telemetry-v1",
            replacing: "\"seq\": 42",
            with: "\"seq\": 0"
        )

        XCTAssertThrowsError(
            try SafeRunJSON.makeDecoder().decode(TelemetryEnvelope.self, from: data)
        )
    }

    func testDecoderRejectsEnvelopeKindMismatch() throws {
        let data = try modifiedFixture(
            named: "telemetry-v1",
            replacing: "\"kind\": \"telemetry\"",
            with: "\"kind\": \"event\""
        )

        XCTAssertThrowsError(
            try SafeRunJSON.makeDecoder().decode(TelemetryEnvelope.self, from: data)
        )
    }

    func testDecoderAcceptsTimestampWithoutFractionalSeconds() throws {
        let data = try modifiedFixture(
            named: "telemetry-v1",
            replacing: "2026-09-07T14:12:03.123Z",
            with: "2026-09-07T14:12:03Z"
        )

        XCTAssertNoThrow(
            try SafeRunJSON.makeDecoder().decode(TelemetryEnvelope.self, from: data)
        )
    }

    func testEventPayloadEncodesNullIncidentIDAsRequiredKey() throws {
        let payload = EventPayload(
            eventType: .sessionStarted,
            severity: .info
        )
        let encoded = try SafeRunJSON.makeEncoder().encode(payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertTrue(object.keys.contains("incident_id"))
        XCTAssertTrue(object["incident_id"] is NSNull)
    }

    func testEventPayloadRejectsMissingIncidentIDKey() throws {
        let json = """
        {
          "event_id": "33333333-3333-4333-8333-333333333333",
          "event_type": "session_started",
          "severity": "info"
        }
        """

        XCTAssertThrowsError(
            try SafeRunJSON.makeDecoder().decode(
                EventPayload.self,
                from: Data(json.utf8)
            )
        )
    }

    func testCancellationRequiresCriticalSeverityAndIncidentID() throws {
        let json = """
        {
          "event_id": "33333333-3333-4333-8333-333333333333",
          "event_type": "manual_sos_cancelled",
          "severity": "info",
          "incident_id": null
        }
        """
        XCTAssertThrowsError(
            try SafeRunJSON.makeDecoder().decode(EventPayload.self, from: Data(json.utf8))
        )
    }

    private func fixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    private func modifiedFixture(
        named name: String,
        replacing original: String,
        with replacement: String
    ) throws -> Data {
        let data = try fixture(named: name)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(original), "Fixture did not contain expected token.")
        return Data(text.replacingOccurrences(of: original, with: replacement).utf8)
    }
}

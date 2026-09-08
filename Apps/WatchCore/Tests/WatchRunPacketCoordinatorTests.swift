import Foundation
import SafeRunDomain
import XCTest
@testable import SafeRunWatchCore

@MainActor
final class WatchRunPacketCoordinatorTests: XCTestCase {
    func testLifecycleAndTelemetryUseOneMonotonicSequence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingWatchTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let coordinator = WatchRunPacketCoordinator(
            transport: transport,
            sessionStore: LocalRunSessionStore(
                fileURL: directory.appendingPathComponent("session.json")
            ),
            telemetryInterval: 3_600,
            now: { now },
            sample: {
                RunTelemetrySample(
                    startedAt: now.addingTimeInterval(-10),
                    heartRateBPM: 130,
                    heartRateSampleDate: now,
                    location: nil
                )
            }
        )

        await coordinator.runDidStart()
        try await coordinator.sendTelemetry()
        await coordinator.runDidEnd()

        XCTAssertEqual(transport.packets.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(Set(transport.packets.map(\.sessionID)).count, 1)
        XCTAssertEqual(transport.packets.map(\.priority), [.lifecycle, .telemetry, .lifecycle])
    }

    func testStaleHeartRateIsOmitted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingWatchTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let coordinator = WatchRunPacketCoordinator(
            transport: transport,
            sessionStore: LocalRunSessionStore(fileURL: directory.appendingPathComponent("session.json")),
            now: { now },
            sample: {
                RunTelemetrySample(
                    startedAt: now.addingTimeInterval(-10),
                    heartRateBPM: 190,
                    heartRateSampleDate: now.addingTimeInterval(-6),
                    location: nil
                )
            }
        )

        try await coordinator.sendTelemetry()
        let packet = try XCTUnwrap(transport.packets.last)
        let envelope = try SafeRunJSON.makeDecoder().decode(
            TelemetryEnvelope.self,
            from: packet.envelopeData
        )
        XCTAssertNil(envelope.payload.heartRateBPM)
        XCTAssertNil(envelope.payload.heartRateSampleAgeMilliseconds)
    }

    func testSOSAndCancellationAreP0AndShareIncidentIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingWatchTransport()
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let identifiers = [
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        ]
        var index = 0
        let coordinator = WatchRunPacketCoordinator(
            transport: transport,
            sessionStore: LocalRunSessionStore(fileURL: directory.appendingPathComponent("session.json")),
            now: { now },
            makeUUID: { defer { index += 1 }; return identifiers[index] },
            sample: {
                RunTelemetrySample(
                    startedAt: now.addingTimeInterval(-60), heartRateBPM: 170,
                    heartRateSampleDate: now.addingTimeInterval(-6),
                    location: LocationReading(
                        latitude: 10, longitude: 106, horizontalAccuracyMeters: 10,
                        timestamp: now.addingTimeInterval(-21), speedMetersPerSecond: 2
                    )
                )
            }
        )

        let sos = try await coordinator.queueManualSOS()
        let cancellation = try await coordinator.queueManualSOSCancellation(incidentID: sos.incidentID)

        XCTAssertEqual(transport.packets.map(\.priority), [.critical, .critical])
        XCTAssertEqual(transport.packets.map(\.sequence), [1, 2])
        let first = try SafeRunJSON.makeDecoder().decode(EventEnvelope.self, from: transport.packets[0].envelopeData)
        let second = try SafeRunJSON.makeDecoder().decode(EventEnvelope.self, from: transport.packets[1].envelopeData)
        XCTAssertEqual(first.payload.eventType, .manualSOS)
        XCTAssertEqual(second.payload.eventType, .manualSOSCancelled)
        XCTAssertEqual(first.payload.incidentID, second.payload.incidentID)
        XCTAssertEqual(cancellation.incidentID, sos.incidentID)
        XCTAssertNil(first.payload.context?.heartRateBPM)
        XCTAssertNil(first.payload.context?.lastLocation)
    }
}

@MainActor
private final class RecordingWatchTransport: WatchTransporting {
    var diagnostics = WatchTransportDiagnostics(isReachable: true)
    var packets: [TransportPacket] = []

    func activate() {}
    func enqueue(_ packet: TransportPacket) async throws { packets.append(packet) }
}

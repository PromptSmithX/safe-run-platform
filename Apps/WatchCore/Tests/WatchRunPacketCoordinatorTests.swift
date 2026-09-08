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
}

@MainActor
private final class RecordingWatchTransport: WatchTransporting {
    var diagnostics = WatchTransportDiagnostics(isReachable: true)
    var packets: [TransportPacket] = []

    func activate() {}
    func enqueue(_ packet: TransportPacket) async throws { packets.append(packet) }
}

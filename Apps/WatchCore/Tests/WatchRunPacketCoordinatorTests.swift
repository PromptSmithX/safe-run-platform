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
        let persistence = WatchRunPersistence(fileURL: directory.appendingPathComponent("watch-run-v2.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let coordinator = WatchRunPacketCoordinator(
            transport: transport,
            persistence: persistence,
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

        let packets = await persistence.queuedPackets()
        XCTAssertEqual(packets.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(Set(packets.map(\.sessionID)).count, 1)
        XCTAssertEqual(packets.map(\.priority), [.lifecycle, .telemetry, .lifecycle])
    }

    func testStaleHeartRateIsOmitted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingWatchTransport()
        let persistence = WatchRunPersistence(fileURL: directory.appendingPathComponent("watch-run-v2.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let coordinator = WatchRunPacketCoordinator(
            transport: transport,
            persistence: persistence,
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

        await coordinator.runDidStart()
        try await coordinator.sendTelemetry()
        let queued = await persistence.queuedPackets()
        let packet = try XCTUnwrap(queued.last)
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
        let persistence = WatchRunPersistence(fileURL: directory.appendingPathComponent("watch-run-v2.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_010)
        let identifiers = [
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        ]
        var index = 0
        let coordinator = WatchRunPacketCoordinator(
            transport: transport,
            persistence: persistence,
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

        await coordinator.runDidStart()
        let sos = try await coordinator.queueManualSOS()
        let cancellation = try await coordinator.queueManualSOSCancellation(incidentID: sos.incidentID)

        let packets = await persistence.queuedPackets()
        XCTAssertEqual(packets.map(\.priority), [.lifecycle, .critical, .critical])
        XCTAssertEqual(packets.map(\.sequence), [1, 2, 3])
        let first = try SafeRunJSON.makeDecoder().decode(EventEnvelope.self, from: packets[1].envelopeData)
        let second = try SafeRunJSON.makeDecoder().decode(EventEnvelope.self, from: packets[2].envelopeData)
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
    func activate() {}
    func outboxDidChange() async {}
}

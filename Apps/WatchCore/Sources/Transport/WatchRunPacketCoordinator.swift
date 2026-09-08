import Foundation
import SafeRunDomain

public struct RunTelemetrySample: Equatable, Sendable {
    public let startedAt: Date
    public let heartRateBPM: Double?
    public let heartRateSampleDate: Date?
    public let location: LocationReading?

    public init(
        startedAt: Date,
        heartRateBPM: Double?,
        heartRateSampleDate: Date?,
        location: LocationReading?
    ) {
        self.startedAt = startedAt
        self.heartRateBPM = heartRateBPM
        self.heartRateSampleDate = heartRateSampleDate
        self.location = location
    }
}

@MainActor
public final class WatchRunPacketCoordinator {
    public var onSessionProgress: ((String, Int) -> Void)?
    private let transport: any WatchTransporting
    private let sessionStore: LocalRunSessionStore
    private let telemetryInterval: TimeInterval
    private let staleHeartRateSeconds: TimeInterval
    private let sample: () -> RunTelemetrySample?
    private let now: () -> Date
    private var telemetryTask: Task<Void, Never>?

    public init(
        transport: any WatchTransporting,
        sessionStore: LocalRunSessionStore,
        telemetryInterval: TimeInterval = 10,
        staleHeartRateSeconds: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        sample: @escaping () -> RunTelemetrySample?
    ) {
        self.transport = transport
        self.sessionStore = sessionStore
        self.telemetryInterval = telemetryInterval
        self.staleHeartRateSeconds = staleHeartRateSeconds
        self.now = now
        self.sample = sample
    }

    public func runDidStart() async {
        do {
            _ = try await sessionStore.begin()
            try await enqueueEvent(.sessionStarted)
            startTelemetryTimer()
        } catch { /* surfaced by transport diagnostics on the next enqueue */ }
    }

    public func runDidEnd() async {
        telemetryTask?.cancel()
        telemetryTask = nil
        do {
            try await enqueueEvent(.sessionEnded)
            try await sessionStore.end()
        } catch { }
    }

    public func sendTelemetry() async throws {
        guard let sample = sample() else { return }
        let issued = try await sessionStore.issueNext()
        onSessionProgress?(issued.sessionID, issued.sequence)
        let date = now()
        let heartRateAge = sample.heartRateSampleDate.map { date.timeIntervalSince($0) }
        let heartRateIsFresh = heartRateAge.map { $0 >= 0 && $0 <= staleHeartRateSeconds } ?? false
        let locationAge = sample.location.map { date.timeIntervalSince($0.timestamp) }
        let locationIsFresh = locationAge.map { $0 >= 0 && $0 <= 20 } ?? false
        let location = locationIsFresh ? sample.location : nil

        let payload = TelemetryPayload(
            heartRateBPM: heartRateIsFresh ? sample.heartRateBPM : nil,
            heartRateSampleAgeMilliseconds: heartRateIsFresh
                ? heartRateAge.map { Int($0 * 1_000) }
                : nil,
            elapsedSeconds: max(0, Int(date.timeIntervalSince(sample.startedAt))),
            speedMetersPerSecond: location?.speedMetersPerSecond,
            location: location.map {
                TelemetryLocation(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    horizontalAccuracyMeters: $0.horizontalAccuracyMeters,
                    ageMilliseconds: Int(date.timeIntervalSince($0.timestamp) * 1_000)
                )
            },
            transport: TransportSnapshot(phoneReachable: transport.diagnostics.isReachable)
        )
        let envelope = TelemetryEnvelope(
            sessionID: issued.sessionID,
            sequence: issued.sequence,
            watchTimestamp: date,
            payload: payload
        )
        let data = try SafeRunJSON.makeEncoder().encode(envelope)
        try await transport.enqueue(TransportPacket.decodeEnvelope(data))
    }

    private func enqueueEvent(_ type: SafetyEventType) async throws {
        let issued = try await sessionStore.issueNext()
        onSessionProgress?(issued.sessionID, issued.sequence)
        let date = now()
        let currentSample = sample()
        let envelope = EventEnvelope(
            sessionID: issued.sessionID,
            sequence: issued.sequence,
            watchTimestamp: date,
            payload: EventPayload(
                eventType: type,
                severity: .info,
                context: EventContext(
                    heartRateBPM: currentSample?.heartRateBPM,
                    lastLocation: currentSample?.location.map {
                        LastKnownLocation(latitude: $0.latitude, longitude: $0.longitude)
                    },
                    elapsedSeconds: currentSample.map { max(0, Int(date.timeIntervalSince($0.startedAt))) }
                )
            )
        )
        let data = try SafeRunJSON.makeEncoder().encode(envelope)
        try await transport.enqueue(TransportPacket.decodeEnvelope(data))
    }

    private func startTelemetryTimer() {
        telemetryTask?.cancel()
        telemetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(telemetryInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                try? await sendTelemetry()
            }
        }
    }
}

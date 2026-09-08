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

public struct ManualSOSReceipt: Equatable, Sendable {
    public let eventID: UUID
    public let incidentID: UUID
    public let queuedAt: Date

    public init(eventID: UUID, incidentID: UUID, queuedAt: Date) {
        self.eventID = eventID
        self.incidentID = incidentID
        self.queuedAt = queuedAt
    }
}

@MainActor
public protocol ManualSOSDispatching: AnyObject {
    func queueManualSOS() async throws -> ManualSOSReceipt
    func queueManualSOSCancellation(incidentID: UUID) async throws -> ManualSOSReceipt
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
    private let makeUUID: () -> UUID
    private var telemetryTask: Task<Void, Never>?

    public init(
        transport: any WatchTransporting,
        sessionStore: LocalRunSessionStore,
        telemetryInterval: TimeInterval = 10,
        staleHeartRateSeconds: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        sample: @escaping () -> RunTelemetrySample?
    ) {
        self.transport = transport
        self.sessionStore = sessionStore
        self.telemetryInterval = telemetryInterval
        self.staleHeartRateSeconds = staleHeartRateSeconds
        self.now = now
        self.makeUUID = makeUUID
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

    public func queueManualSOS() async throws -> ManualSOSReceipt {
        let eventID = makeUUID()
        let incidentID = makeUUID()
        let date = now()
        try await enqueueEvent(
            .manualSOS,
            severity: .critical,
            eventID: eventID,
            incidentID: incidentID,
            at: date
        )
        return ManualSOSReceipt(eventID: eventID, incidentID: incidentID, queuedAt: date)
    }

    public func queueManualSOSCancellation(incidentID: UUID) async throws -> ManualSOSReceipt {
        let eventID = makeUUID()
        let date = now()
        try await enqueueEvent(
            .manualSOSCancelled,
            severity: .critical,
            eventID: eventID,
            incidentID: incidentID,
            at: date
        )
        return ManualSOSReceipt(eventID: eventID, incidentID: incidentID, queuedAt: date)
    }

    private func enqueueEvent(
        _ type: SafetyEventType,
        severity: IncidentSeverity = .info,
        eventID: UUID = UUID(),
        incidentID: UUID? = nil,
        at date: Date? = nil,
        ruleID: String? = nil,
        evaluation: RuleEvaluationSnapshot? = nil
    ) async throws {
        let issued = try await sessionStore.issueNext()
        onSessionProgress?(issued.sessionID, issued.sequence)
        let date = date ?? now()
        let envelope = EventEnvelope(
            sessionID: issued.sessionID,
            sequence: issued.sequence,
            watchTimestamp: date,
            payload: EventPayload(
                eventID: eventID,
                eventType: type,
                severity: severity,
                ruleID: ruleID,
                incidentID: incidentID,
                context: eventContext(at: date, evaluation: evaluation)
            )
        )
        let data = try SafeRunJSON.makeEncoder().encode(envelope)
        try await transport.enqueue(TransportPacket.decodeEnvelope(data))
    }

    private func eventContext(at date: Date, evaluation: RuleEvaluationSnapshot? = nil) -> EventContext? {
        guard let current = sample() else {
            return evaluation.map { EventContext(ruleEvaluation: $0) }
        }
        let heartRateAge = current.heartRateSampleDate.map { date.timeIntervalSince($0) }
        let heartRateIsFresh = heartRateAge.map { $0 >= 0 && $0 <= staleHeartRateSeconds } ?? false
        let locationAge = current.location.map { date.timeIntervalSince($0.timestamp) }
        let locationIsFresh = locationAge.map { $0 >= 0 && $0 <= 20 } ?? false
        return EventContext(
            heartRateBPM: heartRateIsFresh ? current.heartRateBPM : nil,
            lastLocation: locationIsFresh ? current.location.map {
                LastKnownLocation(latitude: $0.latitude, longitude: $0.longitude)
            } : nil,
            elapsedSeconds: max(0, Int(date.timeIntervalSince(current.startedAt))),
            ruleEvaluation: evaluation
        )
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

extension WatchRunPacketCoordinator: ManualSOSDispatching {}

extension WatchRunPacketCoordinator: CheckInEventDispatching {
    public func queueCheckInEvent(_ type: SafetyEventType, severity: IncidentSeverity, incidentID: UUID, evaluation: RuleEvaluationSnapshot?) async throws {
        try await enqueueEvent(type, severity: severity, incidentID: incidentID, ruleID: "high_hr_sustained_v1", evaluation: evaluation)
    }
}

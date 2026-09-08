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
    private let persistence: WatchRunPersistence
    private let telemetryInterval: TimeInterval
    private let staleHeartRateSeconds: TimeInterval
    private let sample: () -> RunTelemetrySample?
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let chaos: DebugChaosController
    private var telemetryTask: Task<Void, Never>?

    public init(
        transport: any WatchTransporting,
        persistence: WatchRunPersistence,
        telemetryInterval: TimeInterval = 10,
        staleHeartRateSeconds: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        sample: @escaping () -> RunTelemetrySample?,
        chaos: DebugChaosController = DebugChaosController()
    ) {
        self.transport = transport
        self.persistence = persistence
        self.telemetryInterval = telemetryInterval
        self.staleHeartRateSeconds = staleHeartRateSeconds
        self.now = now
        self.makeUUID = makeUUID
        self.sample = sample
        self.chaos = chaos
    }

    public func runDidStart(configuration: RunnerSafetyConfigurationEnvelope? = nil) async {
        do {
            let packet = try await persistence.beginRunAndEnqueueStarted(at: now(), configuration: configuration)
            onSessionProgress?(packet.sessionID, packet.sequence)
            await transport.outboxDidChange()
            startTelemetryTimer()
        } catch { /* surfaced by transport diagnostics on the next enqueue */ }
    }

    public func runDidEnd() async {
        telemetryTask?.cancel()
        telemetryTask = nil
        do {
            let date = now()
            let packet = try await persistence.enqueueSessionEndedAndComplete(at: date, context: eventContext(at: date))
            onSessionProgress?(packet.sessionID, packet.sequence)
            await transport.outboxDidChange()
        } catch { }
    }

    public func sendTelemetry() async throws {
        guard let sample = sample() else { return }
        if chaos.shouldDropTelemetry() { return }
        let date = now()
        let heartRateDate = chaos.configuration.staleHeartRate ? sample.heartRateSampleDate?.addingTimeInterval(-60) : sample.heartRateSampleDate
        let locationReading = chaos.configuration.staleGPS ? sample.location.map { LocationReading(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracyMeters: $0.horizontalAccuracyMeters, timestamp: $0.timestamp.addingTimeInterval(-60), speedMetersPerSecond: $0.speedMetersPerSecond) } : sample.location
        let heartRateAge = heartRateDate.map { date.timeIntervalSince($0) }
        let heartRateIsFresh = heartRateAge.map { $0 >= 0 && $0 <= staleHeartRateSeconds } ?? false
        let locationAge = locationReading.map { date.timeIntervalSince($0.timestamp) }
        let locationIsFresh = locationAge.map { $0 >= 0 && $0 <= 20 } ?? false
        let location = locationIsFresh ? locationReading : nil

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
        let packet = try await persistence.enqueueTelemetry(payload, at: date)
        onSessionProgress?(packet.sessionID, packet.sequence)
        await transport.outboxDidChange()
    }

    public func queueManualSOS() async throws -> ManualSOSReceipt {
        let eventID = makeUUID()
        let incidentID = makeUUID()
        let date = now()
        let packet = try await persistence.supersedeCheckInAndEnqueueSOS(eventID: eventID, incidentID: incidentID, at: date, context: eventContext(at: date))
        onSessionProgress?(packet.sessionID, packet.sequence)
        await transport.outboxDidChange()
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
        let date = date ?? now()
        let packet = try await persistence.enqueueEvent(
            EventPayload(
                eventID: eventID,
                eventType: type,
                severity: severity,
                ruleID: ruleID,
                incidentID: incidentID,
                context: eventContext(at: date, evaluation: evaluation)
            ), at: date
        )
        onSessionProgress?(packet.sessionID, packet.sequence)
        await transport.outboxDidChange()
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

    public func recoverySnapshot() async -> WatchRunRecoverySnapshot? { await persistence.recover() }

    public func recoverRun(startedAt: Date) async -> WatchRunRecoverySnapshot? {
        let snapshot: WatchRunRecoverySnapshot
        if await persistence.recover() != nil {
            guard let aligned = try? await persistence.alignRecoveredStartDate(startedAt) else { return nil }
            snapshot = aligned
        }
        else {
            guard let created = try? await persistence.beginRecoveredRun(at: startedAt, configuration: nil) else { return nil }
            snapshot = created
        }
        do {
            if let packet = try await persistence.enqueueRecoveryStateSyncIfNeeded(at: now()) {
                onSessionProgress?(packet.sessionID, packet.sequence)
            }
            await transport.outboxDidChange()
            startTelemetryTimer()
        } catch { }
        return snapshot
    }
}

extension WatchRunPacketCoordinator: ManualSOSDispatching {}

extension WatchRunPacketCoordinator: CheckInEventDispatching {
    public func startPersistentCheckIn(_ snapshot: PersistentCheckInSnapshot, evaluation: RuleEvaluationSnapshot, at date: Date) async throws {
        let enriched = PersistentCheckInSnapshot(incidentID: snapshot.incidentID, startedEventID: snapshot.startedEventID, deadline: snapshot.deadline, context: eventContext(at: date, evaluation: evaluation))
        let packet = try await persistence.saveCheckInAndEnqueueStarted(enriched, evaluation: evaluation, at: date)
        onSessionProgress?(packet.sessionID, packet.sequence)
        await transport.outboxDidChange()
    }

    public func resolvePersistentCheckIn(_ type: SafetyEventType, severity: IncidentSeverity, eventID: UUID, at date: Date) async throws {
        let packet = try await persistence.resolveCheckInAndEnqueueEvent(type: type, severity: severity, eventID: eventID, at: date, context: eventContext(at: date))
        onSessionProgress?(packet.sessionID, packet.sequence)
        await transport.outboxDidChange()
    }
}

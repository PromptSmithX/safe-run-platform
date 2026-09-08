import Combine
import Foundation
import SafeRunDomain

public struct CheckInContext: Equatable, Sendable {
    public let incidentID: UUID; public let reason: CheckInReason; public let startedAt: Date; public let deadline: Date
    public let evidence: RuleEvaluationSnapshot
}
public enum CheckInState: Equatable, Sendable { case idle, active(CheckInContext), resolving, resolved, escalated }
public enum CheckInResolution: Equatable, Sendable { case ok, help, timeout, superseded }

@MainActor public protocol CheckInEventDispatching: AnyObject {
    func startPersistentCheckIn(_ snapshot: PersistentCheckInSnapshot, evaluation: RuleEvaluationSnapshot, at date: Date) async throws
    func resolvePersistentCheckIn(_ type: SafetyEventType, severity: IncidentSeverity, eventID: UUID, at date: Date) async throws
}

@MainActor
public final class CheckInCoordinator: ObservableObject {
    @Published public private(set) var state: CheckInState = .idle
    public var onResolved: ((CheckInResolution) -> Void)?
    private let dispatcher: any CheckInEventDispatching
    private let makeUUID: () -> UUID
    private let now: () -> Date
    public init(dispatcher: any CheckInEventDispatching, makeUUID: @escaping () -> UUID = UUID.init, now: @escaping () -> Date = Date.init) { self.dispatcher = dispatcher; self.makeUUID = makeUUID; self.now = now }

    public func startCheckIn(reason: CheckInReason, evaluation: RuleEvaluationSnapshot, timeoutSeconds: Int, at date: Date) async {
        guard state == .idle || state == .resolved || state == .escalated else { return }
        let context = CheckInContext(incidentID: makeUUID(), reason: reason, startedAt: date, deadline: date.addingTimeInterval(TimeInterval(timeoutSeconds)), evidence: evaluation)
        state = .active(context)
        let snapshot = PersistentCheckInSnapshot(incidentID: context.incidentID, startedEventID: makeUUID(), deadline: context.deadline, context: EventContext(ruleEvaluation: evaluation))
        do { try await dispatcher.startPersistentCheckIn(snapshot, evaluation: evaluation, at: date) }
        catch { state = .idle }
    }
    public func userOK() async { await resolve(.ok) }
    public func userRequestsHelp() async { await resolve(.help) }
    public func tick(at date: Date) async { if case .active(let context) = state, date >= context.deadline { await resolve(.timeout) } }
    public func supersedeWithManualSOS() { guard case .active = state else { return }; state = .resolved; onResolved?(.superseded) }
    public func resetForRun() { state = .idle }

    public func restore(_ snapshot: PersistentCheckInSnapshot, at date: Date) async {
        guard snapshot.terminalOutcome == nil, state == .idle || state == .resolved || state == .escalated else { return }
        let evidence = snapshot.context?.ruleEvaluation ?? RuleEvaluationSnapshot(
            thresholdBPM: 0, windowSeconds: 0, sampleCount: 0, minimumBPM: 0, maximumBPM: 0, averageBPM: 0
        )
        let context = CheckInContext(incidentID: snapshot.incidentID, reason: .sustainedHighHeartRate, startedAt: snapshot.deadline.addingTimeInterval(-20), deadline: snapshot.deadline, evidence: evidence)
        state = .active(context)
        if date >= snapshot.deadline { await resolve(.timeout) }
    }

    private func resolve(_ resolution: CheckInResolution) async {
        guard case .active(let context) = state else { return }
        state = .resolving
        let event: (SafetyEventType, IncidentSeverity) = resolution == .ok ? (.checkInOK, .info) : (resolution == .help ? .checkInHelpRequested : .checkInTimeout, .critical)
        do {
            try await dispatcher.resolvePersistentCheckIn(event.0, severity: event.1, eventID: makeUUID(), at: now())
            state = resolution == .ok ? .resolved : .escalated; onResolved?(resolution)
        } catch { state = .active(context) }
    }
}

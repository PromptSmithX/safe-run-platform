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
    func queueCheckInEvent(_ type: SafetyEventType, severity: IncidentSeverity, incidentID: UUID, evaluation: RuleEvaluationSnapshot?) async throws
}

@MainActor
public final class CheckInCoordinator: ObservableObject {
    @Published public private(set) var state: CheckInState = .idle
    public var onResolved: ((CheckInResolution) -> Void)?
    private let dispatcher: any CheckInEventDispatching
    private let makeUUID: () -> UUID
    public init(dispatcher: any CheckInEventDispatching, makeUUID: @escaping () -> UUID = UUID.init) { self.dispatcher = dispatcher; self.makeUUID = makeUUID }

    public func startCheckIn(reason: CheckInReason, evaluation: RuleEvaluationSnapshot, timeoutSeconds: Int, at date: Date) async {
        guard state == .idle || state == .resolved || state == .escalated else { return }
        let context = CheckInContext(incidentID: makeUUID(), reason: reason, startedAt: date, deadline: date.addingTimeInterval(TimeInterval(timeoutSeconds)), evidence: evaluation)
        state = .active(context)
        do { try await dispatcher.queueCheckInEvent(.checkInStarted, severity: .warning, incidentID: context.incidentID, evaluation: evaluation) }
        catch { state = .idle }
    }
    public func userOK() async { await resolve(.ok) }
    public func userRequestsHelp() async { await resolve(.help) }
    public func tick(at date: Date) async { if case .active(let context) = state, date >= context.deadline { await resolve(.timeout) } }
    public func supersedeWithManualSOS() { guard case .active = state else { return }; state = .resolved; onResolved?(.superseded) }
    public func resetForRun() { state = .idle }

    private func resolve(_ resolution: CheckInResolution) async {
        guard case .active(let context) = state else { return }
        state = .resolving
        let event: (SafetyEventType, IncidentSeverity) = resolution == .ok ? (.checkInOK, .info) : (resolution == .help ? .checkInHelpRequested : .checkInTimeout, .critical)
        do {
            try await dispatcher.queueCheckInEvent(event.0, severity: event.1, incidentID: context.incidentID, evaluation: context.evidence)
            state = resolution == .ok ? .resolved : .escalated; onResolved?(resolution)
        } catch { state = .active(context) }
    }
}

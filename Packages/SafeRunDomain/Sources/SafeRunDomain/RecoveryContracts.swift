import Foundation

public enum RunSessionServerStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case ended
    case abandoned
}

public struct SessionReconciliationRequest: Codable, Equatable, Sendable {
    public let clientSessionIDs: [String]

    public init(clientSessionIDs: [String]) { self.clientSessionIDs = clientSessionIDs }

    private enum CodingKeys: String, CodingKey { case clientSessionIDs = "client_session_ids" }
}

public struct ReconciledRunSession: Codable, Equatable, Sendable {
    public let clientSessionID: String
    public let serverSessionID: String
    public let status: RunSessionServerStatus
    public let lastSequence: Int
    public let incidentIDs: [String]

    public init(clientSessionID: String, serverSessionID: String, status: RunSessionServerStatus, lastSequence: Int, incidentIDs: [String] = []) {
        self.clientSessionID = clientSessionID
        self.serverSessionID = serverSessionID
        self.status = status
        self.lastSequence = lastSequence
        self.incidentIDs = incidentIDs
    }

    private enum CodingKeys: String, CodingKey {
        case clientSessionID = "client_session_id"
        case serverSessionID = "server_session_id"
        case status
        case lastSequence = "last_seq"
        case incidentIDs = "incident_ids"
    }
}

public struct SessionReconciliationResponse: Codable, Equatable, Sendable {
    public let sessions: [ReconciledRunSession]
    public init(sessions: [ReconciledRunSession]) { self.sessions = sessions }
}

public struct PersistentCheckInSnapshot: Codable, Equatable, Sendable {
    public let incidentID: UUID
    public let startedEventID: UUID
    public let deadline: Date
    public let context: EventContext?
    public let terminalEventID: UUID?
    public let terminalOutcome: String?

    public init(incidentID: UUID, startedEventID: UUID, deadline: Date, context: EventContext? = nil, terminalEventID: UUID? = nil, terminalOutcome: String? = nil) {
        self.incidentID = incidentID
        self.startedEventID = startedEventID
        self.deadline = deadline
        self.context = context
        self.terminalEventID = terminalEventID
        self.terminalOutcome = terminalOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case incidentID = "incident_id", startedEventID = "started_event_id", deadline, context
        case terminalEventID = "terminal_event_id", terminalOutcome = "terminal_outcome"
    }
}

public struct WatchRunRecoverySnapshot: Codable, Equatable, Sendable {
    public let localSessionID: String
    public let startedAt: Date
    public let lastIssuedSequence: Int
    public let appliedConfiguration: RunnerSafetyConfigurationEnvelope?
    public let checkIn: PersistentCheckInSnapshot?

    public init(localSessionID: String, startedAt: Date, lastIssuedSequence: Int, appliedConfiguration: RunnerSafetyConfigurationEnvelope? = nil, checkIn: PersistentCheckInSnapshot? = nil) {
        self.localSessionID = localSessionID
        self.startedAt = startedAt
        self.lastIssuedSequence = lastIssuedSequence
        self.appliedConfiguration = appliedConfiguration
        self.checkIn = checkIn
    }

    private enum CodingKeys: String, CodingKey {
        case localSessionID = "local_session_id", startedAt = "started_at"
        case lastIssuedSequence = "last_issued_sequence", appliedConfiguration = "applied_configuration"
        case checkIn = "check_in"
    }
}

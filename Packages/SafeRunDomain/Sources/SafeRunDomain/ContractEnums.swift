import Foundation

public enum SafeRunContract {
    public static let schemaVersion = 1
}

public enum RunState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case preparing
    case active
    case paused
    case recovering
    case ending
    case ended
    case failed
}

public enum EnvelopeKind: String, Codable, Equatable, Sendable {
    case telemetry
    case event
}

public enum IncidentSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case critical
}

public enum MotionState: String, Codable, Equatable, Sendable {
    case running
    case walking
    case stationary
    case unknown
}

public enum SafetyEventType: String, Codable, CaseIterable, Equatable, Sendable {
    case sessionStarted = "session_started"
    case sessionPaused = "session_paused"
    case sessionResumed = "session_resumed"
    case sessionEnded = "session_ended"
    case checkInStarted = "check_in_started"
    case checkInOK = "check_in_ok"
    case checkInHelpRequested = "check_in_help_requested"
    case checkInTimeout = "check_in_timeout"
    case manualSOS = "manual_sos"
    case autoAnomalyTriggered = "auto_anomaly_triggered"
    case connectionDegraded = "connection_degraded"
    case stateSync = "state_sync"
}


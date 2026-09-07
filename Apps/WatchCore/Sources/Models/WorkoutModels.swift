import Foundation
import SafeRunDomain

public struct WorkoutSnapshot: Equatable, Sendable {
    public let state: RunState
    public let startedAt: Date?
    public let heartRateBPM: Double?
    public let heartRateSampleDate: Date?

    public init(
        state: RunState,
        startedAt: Date? = nil,
        heartRateBPM: Double? = nil,
        heartRateSampleDate: Date? = nil
    ) {
        self.state = state
        self.startedAt = startedAt
        self.heartRateBPM = heartRateBPM
        self.heartRateSampleDate = heartRateSampleDate
    }
}

public struct WorkoutSummary: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let savedWorkoutID: UUID?

    public init(startedAt: Date, endedAt: Date, savedWorkoutID: UUID?) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.savedWorkoutID = savedWorkoutID
    }
}

public enum WorkoutProviderError: Error, Equatable, LocalizedError {
    case healthDataUnavailable
    case workoutAuthorizationDenied
    case workoutAlreadyActive
    case noActiveWorkout
    case collectionFailed
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is unavailable on this device."
        case .workoutAuthorizationDenied:
            return "Permission to save workouts was not granted."
        case .workoutAlreadyActive:
            return "A workout is already active."
        case .noActiveWorkout:
            return "There is no active workout to stop."
        case .collectionFailed:
            return "Workout data collection could not start or stop."
        case .saveFailed:
            return "The workout ended but could not be saved."
        }
    }
}


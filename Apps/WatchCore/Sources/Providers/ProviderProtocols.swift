import Foundation

@MainActor
public protocol WorkoutDataProviding: AnyObject {
    var onSnapshot: ((WorkoutSnapshot) -> Void)? { get set }

    func requestAuthorization() async throws
    func startWorkout(at date: Date) async throws
    func stopWorkout(at date: Date) async throws -> WorkoutSummary
}

@MainActor
public protocol LocationDataProviding: AnyObject {
    var onLocation: ((LocationReading) -> Void)? { get set }

    func requestAuthorization() async throws
    func startUpdatingLocation()
    func stopUpdatingLocation()
}


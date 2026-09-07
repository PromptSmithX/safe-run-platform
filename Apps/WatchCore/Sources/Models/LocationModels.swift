import Foundation

public struct LocationCandidate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double
    public let timestamp: Date
    public let speedMetersPerSecond: Double

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double,
        timestamp: Date,
        speedMetersPerSecond: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
    }
}

public struct LocationReading: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double
    public let timestamp: Date
    public let speedMetersPerSecond: Double?

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double,
        timestamp: Date,
        speedMetersPerSecond: Double?
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
    }
}

public struct LocationQualityPolicy: Equatable, Sendable {
    public let maximumAge: TimeInterval
    public let maximumHorizontalAccuracyMeters: Double

    public init(
        maximumAge: TimeInterval = 20,
        maximumHorizontalAccuracyMeters: Double = 50
    ) {
        self.maximumAge = maximumAge
        self.maximumHorizontalAccuracyMeters = maximumHorizontalAccuracyMeters
    }

    public func normalize(_ candidate: LocationCandidate, now: Date) -> LocationReading? {
        let age = now.timeIntervalSince(candidate.timestamp)
        guard age >= 0, age <= maximumAge else {
            return nil
        }
        guard candidate.horizontalAccuracyMeters >= 0,
              candidate.horizontalAccuracyMeters <= maximumHorizontalAccuracyMeters else {
            return nil
        }
        guard (-90...90).contains(candidate.latitude),
              (-180...180).contains(candidate.longitude) else {
            return nil
        }

        return LocationReading(
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            horizontalAccuracyMeters: candidate.horizontalAccuracyMeters,
            timestamp: candidate.timestamp,
            speedMetersPerSecond: candidate.speedMetersPerSecond >= 0
                ? candidate.speedMetersPerSecond
                : nil
        )
    }
}

public enum LocationDisplayStatus: Equatable, Sendable {
    case unavailable
    case waiting
    case fresh
    case stale
}

public enum LocationProviderError: Error, Equatable, LocalizedError {
    case servicesDisabled
    case authorizationDenied
    case authorizationRestricted

    public var errorDescription: String? {
        switch self {
        case .servicesDisabled:
            return "Location services are disabled."
        case .authorizationDenied:
            return "Location permission was denied."
        case .authorizationRestricted:
            return "Location access is restricted on this device."
        }
    }
}


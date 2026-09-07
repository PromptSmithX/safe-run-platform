import CoreLocation
import Foundation

@MainActor
public final class WatchLocationProvider: NSObject, LocationDataProviding {
    public var onLocation: ((LocationReading) -> Void)?

    private let manager: CLLocationManager
    private let qualityPolicy: LocationQualityPolicy
    private let now: () -> Date
    private var authorizationContinuation: CheckedContinuation<Void, Error>?

    public init(
        manager: CLLocationManager = CLLocationManager(),
        qualityPolicy: LocationQualityPolicy = LocationQualityPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.manager = manager
        self.qualityPolicy = qualityPolicy
        self.now = now
        super.init()

        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    public func requestAuthorization() async throws {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationProviderError.servicesDisabled
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .denied:
            throw LocationProviderError.authorizationDenied
        case .restricted:
            throw LocationProviderError.authorizationRestricted
        case .notDetermined:
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            throw LocationProviderError.authorizationDenied
        }
    }

    public func startUpdatingLocation() {
        manager.startUpdatingLocation()
    }

    public func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        guard let continuation = authorizationContinuation else {
            return
        }

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationContinuation = nil
            continuation.resume()
        case .denied:
            authorizationContinuation = nil
            continuation.resume(throwing: LocationProviderError.authorizationDenied)
        case .restricted:
            authorizationContinuation = nil
            continuation.resume(throwing: LocationProviderError.authorizationRestricted)
        case .notDetermined:
            break
        @unknown default:
            authorizationContinuation = nil
            continuation.resume(throwing: LocationProviderError.authorizationDenied)
        }
    }

    private func handleCandidate(_ candidate: LocationCandidate) {
        guard let reading = qualityPolicy.normalize(candidate, now: now()) else {
            return
        }
        onLocation?(reading)
    }
}

extension WatchLocationProvider: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleAuthorization(status)
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else {
            return
        }

        let candidate = LocationCandidate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            timestamp: location.timestamp,
            speedMetersPerSecond: location.speed
        )

        Task { @MainActor [weak self] in
            self?.handleCandidate(candidate)
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {}
}


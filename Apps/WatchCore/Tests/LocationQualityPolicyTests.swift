import Foundation
import XCTest
@testable import SafeRunWatchCore

final class LocationQualityPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = LocationQualityPolicy(
        maximumAge: 20,
        maximumHorizontalAccuracyMeters: 50
    )

    func testAcceptsFreshAccurateCandidate() throws {
        let reading = try XCTUnwrap(
            policy.normalize(candidate(age: 5, accuracy: 8, speed: 2.5), now: now)
        )

        XCTAssertEqual(reading.latitude, 10.7765)
        XCTAssertEqual(reading.longitude, 106.7009)
        XCTAssertEqual(reading.speedMetersPerSecond, 2.5)
    }

    func testRejectsStaleCandidate() {
        XCTAssertNil(
            policy.normalize(candidate(age: 21, accuracy: 8, speed: 2.5), now: now)
        )
    }

    func testRejectsFutureCandidate() {
        XCTAssertNil(
            policy.normalize(candidate(age: -1, accuracy: 8, speed: 2.5), now: now)
        )
    }

    func testRejectsNegativeAccuracy() {
        XCTAssertNil(
            policy.normalize(candidate(age: 5, accuracy: -1, speed: 2.5), now: now)
        )
    }

    func testRejectsAccuracyAboveMaximum() {
        XCTAssertNil(
            policy.normalize(candidate(age: 5, accuracy: 51, speed: 2.5), now: now)
        )
    }

    func testConvertsNegativeSpeedToUnavailable() throws {
        let reading = try XCTUnwrap(
            policy.normalize(candidate(age: 5, accuracy: 8, speed: -1), now: now)
        )

        XCTAssertNil(reading.speedMetersPerSecond)
    }

    private func candidate(
        age: TimeInterval,
        accuracy: Double,
        speed: Double
    ) -> LocationCandidate {
        LocationCandidate(
            latitude: 10.7765,
            longitude: 106.7009,
            horizontalAccuracyMeters: accuracy,
            timestamp: now.addingTimeInterval(-age),
            speedMetersPerSecond: speed
        )
    }
}


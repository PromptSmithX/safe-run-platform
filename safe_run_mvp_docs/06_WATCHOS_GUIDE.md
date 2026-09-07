# 06 — watchOS Implementation Guide

## 1. Target responsibilities

The Watch app owns:

- workout lifecycle;
- HealthKit HR stream;
- Watch GPS/location;
- safety rule engine;
- check-in UI/haptics;
- manual SOS;
- transport to iPhone;
- short durable retry buffer.

It should **not** own cloud auth or family membership.

## 2. Xcode capabilities / plist

Watch target:

- HealthKit capability.
- Background Modes → `Workout processing`.
- Background Modes → `Location updates` if CoreLocation runs continuously in background.
- `NSHealthShareUsageDescription`.
- `NSHealthUpdateUsageDescription` if saving workout.
- `NSLocationWhenInUseUsageDescription`.
- correct `WKCompanionAppBundleIdentifier`.

Future only:

- Fall Detection entitlement + `NSFallDetectionUsageDescription`.

## 3. HealthKit authorization

Minimal example:

```swift
let healthStore = HKHealthStore()
let heartRate = HKQuantityType(.heartRate)
let workout = HKObjectType.workoutType()

let toRead: Set<HKObjectType> = [heartRate]
let toShare: Set<HKSampleType> = [workout]

try await healthStore.requestAuthorization(toShare: toShare, read: toRead)
```

If you also save distance/energy/route, extend permissions intentionally. Do not request broad health access “just in case”.

## 4. Workout manager skeleton

```swift
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    let healthStore = HKHealthStore()
    var session: HKWorkoutSession?
    var builder: HKLiveWorkoutBuilder?

    @Published var state: RunState = .idle
    @Published var heartRateBPM: Double?

    func start() async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        let session = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: config
        )
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: config
        )
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder

        let start = Date()
        try await session.startMirroringToCompanionDevice()
        session.startActivity(with: start)
        try await builder.beginCollection(at: start)
    }
}
```

Exact signatures can evolve; let Xcode autocomplete against your deployment SDK. Keep the design, not the snippet, as source of truth.

## 5. Reading heart rate

In `HKLiveWorkoutBuilderDelegate`, when statistics update:

```swift
let hrType = HKQuantityType(.heartRate)
if types.contains(hrType),
   let stats = builder.statistics(for: hrType),
   let q = stats.mostRecentQuantity() {
    let unit = HKUnit.count().unitDivided(by: .minute())
    let bpm = q.doubleValue(for: unit)
    // Feed latest HR to UI + rolling rule engine.
}
```

Store along with sample timestamp/freshness. A stale HR value must not be treated as a fresh physiological reading.

## 6. CoreLocation

Recommended MVP:

- `CLLocationManager` on Watch.
- desired accuracy suitable for fitness rather than navigation-level precision.
- discard locations with poor accuracy or negative/invalid age.
- store only latest usable point plus optional route ring buffer.

Do not make “no GPS fix” itself a medical alert.

## 7. WatchConnectivity transport

### Setup

```swift
final class WatchTransport: NSObject, WCSessionDelegate {
    private let session = WCSession.default

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }
}
```

### Immediate message

Encode your envelope to `Data` and use `sendMessageData` when reachable.

```swift
func sendImmediate(_ data: Data) {
    guard session.activationState == .activated,
          session.isReachable else {
        enqueueForRetry(data)
        return
    }

    session.sendMessageData(data, replyHandler: { reply in
        self.handleAck(reply)
    }, errorHandler: { error in
        self.enqueueForRetry(data)
    })
}
```

Important behavior from Apple docs:

- `sendMessage`/`sendMessageData` is for immediate live messaging.
- Watch → iPhone call while Watch extension is active can wake the iOS app in background.
- counterpart must be reachable; otherwise error handler fires.

### Cadence

- Do not send every HR sample.
- Aggregate latest state and emit about every 10 s.
- Critical event bypasses cadence and sends immediately.

## 8. Local queue

Persist to disk a bounded queue, for example:

```text
max normal telemetry: 120 packets (~20 minutes at 10s)
critical events: retained until ACK / session reconciliation
```

Coalesce telemetry during prolonged disconnect:

- keep newest point every ~30 s;
- keep all critical/lifecycle events.

## 9. Safety rule engine interface

```swift
struct SafetySample {
    let at: Date
    let heartRateBPM: Double?
    let speedMps: Double?
    let locationFresh: Bool
    let motionState: MotionState
}

enum SafetyDecision {
    case none
    case requestCheckIn(rule: RuleSnapshot)
    case critical(event: SafetyEvent)
}

protocol SafetyRule {
    func evaluate(window: SampleWindow, config: RunnerSafetyConfig) -> RuleResult
}
```

Keep rules pure where possible so unit tests can replay recorded/fake timelines.

## 10. Check-in UX

Pseudo logic:

```text
rule trigger
-> freeze incident_id
-> play strong haptic
-> show check-in screen 20s
-> runner OK => emit check_in_ok, cooldown
-> runner Help => emit help_requested critical
-> timeout => emit check_in_timeout critical
```

Manual SOS:

- should be accessible from active-run screen;
- should not depend on fresh HR or location;
- create event immediately with latest available context.

## 11. Mirrored workout

Call `startMirroringToCompanionDevice` so iPhone can recover the workout lifecycle and be launched for mirrored session start.

Do **not** send the critical alert solely via `sendDataToRemoteWorkoutSession`, because iOS delivery can be cached/batched when suspended.

## 12. Watch app debug tools

Behind a debug menu:

- Inject HR = 180 for 40 s.
- Inject “no HR sample”.
- Inject no movement.
- Trigger fake SOS.
- Force WCSession send failure.
- Show seq, queue length, last phone ACK, session id.

Without these tools, end-to-end testing will be painfully slow.

# 12 — Vibe Coding Prompt Pack

Paste one milestone at a time into your coding agent. Require it to show changed files and tests before continuing.

## Prompt 0 — Repository bootstrap

```text
Create an Xcode workspace for an iOS companion app + watchOS app named SafeRun.
Use SwiftUI and Swift Concurrency.
Create shared Codable domain models in a Swift package/Shared target:
RunState, TelemetryEnvelope, TelemetryPayload, EventPayload, SafetyEventType,
IncidentSeverity, RunnerSafetyConfig.
Do not implement networking yet.
Add unit tests for JSON encode/decode and sequence IDs.
Return project tree and any manual Xcode capability steps I must click.
```

## Prompt 1 — Watch HealthKit workout

```text
Implement WorkoutManager on watchOS using HKWorkoutSession and HKLiveWorkoutBuilder
for outdoor running. Request minimum HealthKit permission needed to read heart rate
and save the workout. Show live heart rate and elapsed time in a simple SwiftUI screen.
Enable workout processing background mode. Keep the API behind protocols so I can mock it.
Add a debug fake HealthDataProvider for simulator tests.
Do not implement alert rules or backend yet.
```

## Prompt 2 — Watch GPS

```text
Add a watchOS LocationService using CoreLocation.
Expose latest location, horizontal accuracy, age, speed and freshness.
Reject obviously stale/poor samples in a pure helper with unit tests.
Do not store full route yet. Add location permission strings/capability instructions.
```

## Prompt 3 — WatchConnectivity transport

```text
Implement WCSession-based transport from Watch to iPhone.
Use sendMessageData for immediate messages when reachable.
Envelope fields: schema_version, packet_id, session_id, seq, watch_timestamp, kind, payload.
On error/unreachable, persist packet to a bounded local retry queue.
Critical events must have higher priority and never be silently evicted.
On iPhone, persist received packet before replying ACK.
Add a debug screen on both devices showing reachability, last seq, queue size and last error.
No server yet: iPhone only writes received packets to local log/storage.
```

## Prompt 4 — Mirrored workout lifecycle

```text
Add HealthKit workout mirroring from Watch to companion iPhone.
On iPhone register workoutSessionMirroringStartHandler as early as possible.
Treat mirrored sessions as lifecycle/recovery only; do not route critical alert data solely through mirrored session messages.
Handle reconnect where the iPhone can receive multiple mirrored HKWorkoutSession instances.
Add logs and tests for state reconciliation.
```

## Prompt 5 — iPhone durable gateway queue

```text
Implement a durable serial GatewayQueue on iOS using SQLite/GRDB or SwiftData.
Fields: local_id, packet_id unique, session_id, priority, payload, enqueued_at,
attempt_count, next_attempt_at, server_acked_at.
The WCSession receiver must persist transactionally before ACK.
Implement priority P0 critical, P1 lifecycle, P2 sync, P3 telemetry.
Add unit tests for restart recovery, dedupe and priority ordering.
```

## Prompt 6 — Backend skeleton

```text
Create a Firebase backend in TypeScript (Cloud Functions 2nd gen or Cloud Run + Firestore).
Implement endpoints from openapi.yaml:
POST /v1/run-sessions
POST /v1/run-sessions/{id}/telemetry
POST /v1/run-sessions/{id}/events
POST /v1/run-sessions/{id}/end
POST /v1/devices
POST /v1/incidents/{id}/acknowledge
Use Firebase Auth for user endpoints and a high-entropy session-scoped ingest token for telemetry/events.
Store only the token hash server-side.
Make packet_id/event_id/incident_id idempotent.
Write emulator tests proving duplicate critical event sends only one incident/fanout marker.
```

## Prompt 7 — iPhone uploader

```text
Connect the iOS GatewayQueue to the backend HTTPS API using URLSession and Swift Concurrency.
Process P0 before lower priorities. Add retry with jittered exponential backoff.
Do not retry non-retryable 4xx forever.
At run start exchange Firebase user auth for session_id + short-lived ingest token and store token in Keychain.
Telemetry cadence from Watch is about 10 seconds; uploader must not generate duplicate requests.
Add network failure injection in debug builds.
```

## Prompt 8 — Manual SOS end-to-end

```text
Implement manual SOS on Watch as the first real critical path.
Use a large accessible action on active-run screen with accidental-tap protection that does not create a long delay.
Generate event_id + incident_id on Watch, send immediately through WCSession, queue/retry as P0,
backend creates idempotent incident and sends FCM push to caregiver iPhones.
Family app opens an IncidentDetailView showing reason, event time, last known HR/location and a call button.
Do not implement automatic HR alerts yet.
Add an end-to-end debug trigger and logging timestamps at every hop.
```

## Prompt 9 — Check-in coordinator

```text
Implement a Watch CheckInCoordinator independent of medical rules.
API: startCheckIn(reason, context, timeoutSeconds), userOK(), userRequestsHelp(), timeout().
Use haptics and a SwiftUI countdown screen.
OK emits noncritical check_in_ok.
Help or timeout emits a critical event using the existing SOS pipeline.
Only one check-in can be active at once.
Add unit tests with a controllable clock.
```

## Prompt 10 — First auto rule

```text
Implement only a configurable sustained-high-heart-rate rule.
The threshold is user-configured and optional; if absent the rule is disabled.
Require fresh HR samples and sustained duration; ignore one-off spikes.
The rule may only request CheckInCoordinator, never directly claim AF or stroke.
Add warm-up grace, cooldown and hysteresis as configurable engineering parameters.
Create deterministic unit tests with synthetic timelines.
```

## Prompt 11 — Dead-man monitor

```text
Add a scheduled backend function running every minute.
For active sessions whose server last_seen_at exceeds a configurable stale threshold,
create one connection-loss warning incident/event on the state transition healthy->stale.
Do not resend every scheduler tick. Resolve it on telemetry recovery.
If a critical incident was already unresolved before connection loss, preserve the critical state.
Add emulator tests.
```

## Prompt 12 — Hardening

```text
Audit the SafeRun codebase for the critical path Watch -> iPhone -> backend -> caregiver push.
List every place data can be lost or duplicated.
Add explicit idempotency, durable persistence, timeout, retry, structured logs and recovery tests.
Ensure no health/location payload or ingest token is logged in release builds.
Produce a failure-mode table and fix the highest-severity issues first.
```

# 02 — Technical Architecture

## 1. High-level architecture

```mermaid
flowchart LR
    W[Apple Watch\nHealthKit + GPS + Rule Engine] -->|WCSession sendMessage| P[Runner iPhone\nGateway + Queue]
    P -->|HTTPS| B[Backend API]
    B --> D[(Firestore)]
    B -->|FCM/APNs| F1[Family iPhone A]
    B -->|FCM/APNs| F2[Family iPhone B]
    W -. lifecycle/recovery .->|HealthKit workout mirroring| P
```

## 2. Why this architecture

### WatchConnectivity for near-realtime

`WCSession.sendMessage` requires counterpart reachability. Apple documents that when called from an active Watch app, it can wake the corresponding iOS app in the background. During a workout, the Watch extension is high-priority, which is a good fit for this path.

Use it for:

- 10-second telemetry summaries;
- manual SOS;
- check-in response;
- alert trigger;
- session start/end commands.

### Workout mirroring for lifecycle, not alert transport

HealthKit’s mirrored workout is still useful because the iOS companion can be launched when a remote workout starts and the system handles reconnect behavior. However, Apple explicitly notes that if iOS is suspended, remote workout data can be cached and delivered periodically, potentially minutes apart.

Therefore:

- Use mirroring to know a workout exists, reconnect, control pause/resume, and recover state.
- Do **not** make it the only channel for emergency events.

### iPhone as gateway

GPS-only Watch is paired to the runner’s iPhone. The iPhone has the reliable cellular connection and can perform the server HTTPS request after WatchConnectivity wakes it.

This also avoids making backend reliability dependent on watchOS background networking behavior.

## 3. Components

### Watch app

`WorkoutManager`
- owns `HKWorkoutSession`, `HKLiveWorkoutBuilder`;
- streams HR metrics;
- owns workout state.

`LocationManager`
- CoreLocation updates;
- produces latest position, accuracy, speed.

`SafetyRuleEngine`
- receives normalized samples;
- maintains rolling windows;
- outputs `SafetyDecision`.

`CheckInCoordinator`
- haptics, countdown, user response.

`WatchTransport`
- `WCSession` immediate message;
- local retry queue;
- sequence numbering.

`SessionStore`
- persisted active session metadata for restart/recovery.

### Runner iPhone app

`WatchBridge`
- WCSession delegate;
- receives raw packets;
- replies ACK quickly.

`GatewayQueue`
- durable disk queue for unsent packets/events.

`SessionAPIClient`
- start/end session;
- ingest telemetry/events.

`GatewayWorker`
- serializes network writes;
- retry with exponential backoff;
- prioritizes critical events over telemetry.

`RemoteWorkoutCoordinator`
- `HKHealthStore.workoutSessionMirroringStartHandler`;
- tracks mirrored workout state.

### Backend

`Auth / Session service`
- family membership;
- runner identity;
- short-lived ingest token.

`Ingestion service`
- validates token/session;
- checks `seq` and idempotency key;
- updates live snapshot;
- persists selected samples/events.

`Incident service`
- creates alert incident once;
- state transitions;
- caregiver acknowledgement.

`Notification service`
- FCM/APNs fan-out;
- dedupe;
- notification audit.

`Dead-man monitor`
- checks active sessions whose `last_seen_at` exceeds threshold;
- emits connection-loss warning.

### Family iPhone app

`FamilySessionView`
- active runner state;
- last HR/location/time.

`PushHandler`
- opens incident detail.

`IncidentDetailView`
- reason/severity;
- map pin;
- HR snapshot;
- call runner action;
- caregiver acknowledgement.

## 4. Data path

### Normal telemetry

```text
Watch HR/GPS -> normalize -> every 10s create packet
-> WCSession sendMessageData
-> iPhone receives
-> append durable queue
-> POST /telemetry
-> backend update last_seen + snapshot
-> ACK local queue
```

### Critical event

```text
Watch rule/SOS
-> create EventPacket priority=critical
-> WCSession immediate send
-> iPhone puts at HEAD of queue
-> POST /events
-> backend idempotently creates Incident
-> FCM to all active caregiver device tokens
-> audit push result
```

## 5. Reliability rules

- Every packet has `packet_id` UUID + monotonically increasing `seq` per session.
- Event has separate `event_id` UUID.
- Backend stores highest accepted sequence and accepts out-of-order packets without re-triggering incidents.
- Critical events are retried until explicit server ACK or session is ended/resolved.
- Telemetry queue can drop oldest normal packets after a bounded limit; critical event must never be dropped silently.
- Watch and iPhone clocks are not trusted for ordering alone; sequence is authoritative within a session.
- Server writes `received_at` separately from `watch_timestamp`.

## 6. Suggested cadence

- HR sample input: as HealthKit provides it during workout.
- UI refresh: 1 s max, using latest statistics.
- telemetry uplink: 10 s.
- location included when fresh (<20 s) and accuracy acceptable.
- critical event: immediately.
- periodic full snapshot: 30–60 s.
- backend dead-man check: every 1 minute, warning after configurable 120–180 s without telemetry.

These are engineering defaults, not medical thresholds.

## 7. Deployment targets

The mirrored workout APIs originate from iOS 17/watchOS 10-era APIs. The target devices in this use case are significantly newer, so you can choose a modern minimum deployment target for simplicity. Still, keep API availability checks around mirrored-workout calls if family/runner devices may vary.

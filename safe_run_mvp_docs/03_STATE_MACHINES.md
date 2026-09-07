# 03 — State Machines

## 1. Run session state

```text
IDLE
  -> PREPARING
  -> ACTIVE
  -> PAUSED
  -> ACTIVE
  -> ENDING
  -> ENDED

PREPARING -> FAILED
ACTIVE/PREPARING -> RECOVERING -> ACTIVE or FAILED
```

### State meanings

- `IDLE`: no active session.
- `PREPARING`: permissions + workout + transport bootstrapping.
- `ACTIVE`: workout collecting and safety monitoring enabled.
- `PAUSED`: workout manually/system paused; safety logic should reduce or suspend exercise-specific rules.
- `RECOVERING`: app/process/connectivity restarted while a previously active session may still exist.
- `ENDING`: flush queues and finish HealthKit workout.
- `ENDED`: immutable final state.
- `FAILED`: cannot continue safely.

## 2. Incident state

```text
NONE
  -> CHECK_IN
      -> RESOLVED_OK
      -> ESCALATING
  -> ESCALATING  (manual SOS skips CHECK_IN)
      -> ALERTED
      -> CANCELLED_BY_RUNNER
  ALERTED
      -> ACKNOWLEDGED_BY_FAMILY
      -> RESOLVED
```

### Rules

- Only one active auto-check-in incident at a time.
- Manual SOS always supersedes an auto incident.
- A resolved auto incident starts a configurable cooldown before same rule can fire again.
- Incident IDs are generated on Watch before transmission so retries remain idempotent.

## 3. Connectivity state

```text
HEALTHY
  -> WATCH_PHONE_UNREACHABLE
  -> RECOVERING
  -> HEALTHY

HEALTHY
  -> PHONE_SERVER_OFFLINE
  -> QUEUING
  -> FLUSHING
  -> HEALTHY
```

Do not conflate these failures:

- Watch cannot reach iPhone: local Watch problem/path.
- iPhone can hear Watch but cannot reach server: Internet/backend problem.
- Backend alive but family push failed: notification path problem.

Each needs separate logging and UI.

## 4. Source-of-truth ownership

| State | Source of truth |
|---|---|
| Workout active | Watch `HKWorkoutSession` |
| Local incident/check-in | Watch |
| Packet delivery queue | iPhone gateway + Watch retry fallback |
| Backend active session | Server |
| Family incident acknowledgement | Server |
| Notification delivery attempt | Server |

## 5. Recovery algorithm after app restart

### Watch restart/relaunch

1. Read persisted `active_session_stub`.
2. Ask HealthKit/workout state whether an active workout is recoverable.
3. Reactivate WCSession.
4. Send `STATE_SYNC` with last local seq and incident state.
5. iPhone/server return known session state.
6. Choose highest consistent session state; never create a second incident for same `incident_id`.

### iPhone restart/relaunch

1. Activate WCSession immediately.
2. Register `workoutSessionMirroringStartHandler` early in app lifecycle.
3. Restore durable GatewayQueue.
4. Flush critical events first.
5. Query backend session snapshot if auth is available.
6. Reconcile `last_uploaded_seq`.

## 6. Alert arbitration

Priority ordering:

1. `MANUAL_SOS`
2. `NO_RESPONSE_AFTER_CHECKIN`
3. `AUTO_ANOMALY_CONFIRMED`
4. `CONNECTION_LOSS_WITH_PRIOR_RISK`
5. `CONNECTION_LOSS`
6. informational telemetry state

Higher-priority incidents can replace/lift lower-priority ones, but should preserve history.

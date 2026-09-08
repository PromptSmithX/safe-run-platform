# 04 — Data Contracts

## 1. Common envelope

Every Watch → iPhone packet uses a versioned envelope.

```json
{
  "schema_version": 1,
  "packet_id": "uuid",
  "session_id": "uuid-or-local-temp-id",
  "seq": 42,
  "watch_timestamp": "2026-09-07T14:12:03.123Z",
  "kind": "telemetry",
  "payload": {}
}
```

### Constraints

- `packet_id`: globally unique.
- `session_id`: stable for run. Before server ACK, local temp ID is allowed, then map to server ID.
- `seq`: integer starting at 1; increment for every envelope emitted by Watch.
- `schema_version`: use integer for migration.
- `watch_timestamp`: diagnostic only; not sole ordering mechanism.

## 2. Telemetry payload

```json
{
  "heart_rate_bpm": 134.0,
  "heart_rate_sample_age_ms": 680,
  "elapsed_s": 812,
  "distance_m": 1840.2,
  "speed_mps": 2.55,
  "location": {
    "lat": 10.7765,
    "lon": 106.7009,
    "horizontal_accuracy_m": 7.8,
    "age_ms": 2100
  },
  "motion_state": "running",
  "watch_battery": 0.72,
  "transport": {
    "phone_reachable": true
  }
}
```

Fields can be `null` when sensor value is unavailable/stale.

## 3. Event payload

```json
{
  "event_id": "uuid",
  "event_type": "manual_sos",
  "severity": "critical",
  "rule_id": null,
  "incident_id": "uuid",
  "context": {
    "heart_rate_bpm": 152,
    "last_location": {"lat": 10.7765, "lon": 106.7009},
    "elapsed_s": 813
  }
}
```

Recommended `event_type` enum:

- `session_started`
- `session_paused`
- `session_resumed`
- `session_ended`
- `check_in_started`
- `check_in_ok`
- `check_in_help_requested`
- `check_in_timeout`
- `manual_sos`
- `manual_sos_cancelled` — P0 update with a new `event_id` and the original manual-SOS `incident_id`.
- `auto_anomaly_triggered`
- `connection_degraded`
- `state_sync`

Milestone E check-in events use one stable, non-null `incident_id` and
`rule_id = high_hr_sustained_v1`. `check_in_started` is warning severity,
`check_in_ok` is info severity, and help/timeout are critical P0 events. A rule
evaluation snapshot may be attached under `context.rule_evaluation`; it records configured evidence only
and is not a medical diagnosis.

Future:
- `fall_detected`

## 4. Rule evaluation snapshot

Keep this local and optionally attach to auto-alert event for debugging.

```json
{
  "rule_id": "high_hr_sustained_v1",
  "rule_version": 1,
  "threshold_bpm": 165,
  "window_seconds": 30,
  "sample_count": 4,
  "minimum_bpm": 167,
  "maximum_bpm": 176,
  "average_bpm": 171.2
}
```

Never call a field `af_detected` unless a future validated medical algorithm and regulatory basis exists.

## 5. Server session snapshot

```json
{
  "session_id": "uuid",
  "runner_uid": "firebase-uid",
  "family_id": "uuid",
  "status": "active",
  "started_at": "server timestamp",
  "last_seen_at": "server timestamp",
  "last_watch_timestamp": "timestamp",
  "last_seq": 153,
  "latest": {
    "heart_rate_bpm": 136,
    "lat": 10.7765,
    "lon": 106.7009,
    "speed_mps": 2.4
  },
  "active_incident_id": null
}
```

## 6. Incident document

```json
{
  "incident_id": "uuid",
  "session_id": "uuid",
  "type": "no_response_after_checkin",
  "severity": "critical",
  "status": "alerted",
  "created_at": "server timestamp",
  "runner_event_at": "watch timestamp",
  "latest_context": {
    "heart_rate_bpm": 168,
    "lat": 10.7765,
    "lon": 106.7009
  },
  "notification_fanout_started_at": "server timestamp",
  "acknowledged_by": null,
  "acknowledged_at": null
}
```

## 7. Dedupe and idempotency

Backend must enforce:

- unique `packet_id` per accepted envelope;
- unique `event_id`;
- unique `incident_id`;
- do not send a second push fan-out for an incident already in `alerted|acknowledged|resolved` unless it is an explicit escalation update.
- a `manual_sos_cancelled` event idempotently transitions its matching manual-SOS incident to `cancelled`; it never creates a second incident.

## 8. Queue priority

```text
P0: critical event / SOS / timeout
P1: session lifecycle
P2: state sync
P3: normal telemetry
```

When storage pressure occurs, only P3 may be coalesced/dropped.

# 08 — Backend Blueprint (Firebase-first)

## 1. Why Firebase for MVP

This is not the only valid backend. It is convenient for a family-scale prototype because it gives:

- Firebase Auth;
- Firestore;
- Cloud Functions / Cloud Run;
- FCM for iOS push;
- Crashlytics/Analytics if desired.

The ingestion API should still be explicit HTTP, not direct unvalidated Firestore writes from Watch telemetry.

## 2. Firestore collections

```text
users/{uid}
  display_name
  default_family_id

families/{familyId}
  name
  created_at

families/{familyId}/members/{uid}
  role: runner|caregiver|admin
  status: active|invited

users/{uid}/devices/{deviceId}
  fcm_token
  role
  active
  app_version
  updated_at

runSessions/{sessionId}
  runner_uid
  family_id
  status
  started_at
  ended_at
  last_seen_at
  last_seq
  latest_hr
  latest_lat
  latest_lon
  active_incident_id
  client_session_id

runSessions/{sessionId}/samples/{sampleId}
  at
  hr
  lat
  lon
  speed
  seq

runSessions/{sessionId}/events/{eventId}
  type
  severity
  watch_at
  received_at
  payload

incidents/{incidentId}
  session_id
  family_id
  runner_uid
  type
  severity
  status
  created_at
  acknowledged_by
  acknowledged_at
  context

incidentNotifications/{incidentId}/attempts/{attemptId}
  device_id
  fcm_message_id
  status
  created_at
```

## 3. Ingest token storage

Do not store raw ingest secret in Firestore. Store a hash:

```text
runSessions/{id}.ingest_token_hash
runSessions/{id}.ingest_token_expires_at
```

Token should be high entropy random bytes, not guessable session ID.

## 4. Cloud Functions

Suggested functions:

```text
createRunSession (HTTPS)
ingestTelemetry (HTTPS)
ingestEvent (HTTPS)
endRunSession (HTTPS)
registerDevice (HTTPS)
ackIncident (HTTPS)
checkStaleSessions (scheduled every minute)
```

## 5. Telemetry write strategy

At 10-second cadence, one runner generates ~360 packets/hour. For MVP this is trivial, but avoid unnecessary storage:

- update `runSessions/{id}` live snapshot for each accepted packet;
- persist historical sample only every 30 s or when materially changed;
- always persist incident-adjacent samples for forensic/debugging window.

Future optimization: batch/time-series store.

## 6. Transaction logic for event → incident

Pseudo code:

```ts
await db.runTransaction(async tx => {
  const eventRef = ...eventId
  if (event already exists) return existing result

  tx.create(eventRef, event)

  if (event.severity === 'critical') {
    const incidentRef = ...incidentId
    if (!incident exists) {
      tx.create(incidentRef, makeIncident(event))
      tx.update(sessionRef, {active_incident_id: incidentId})
    }
  }
})

// outside transaction: notification fan-out protected by notification state
```

Push should be idempotent too. Store `fanout_started_at` / per-device attempt.

## 7. Dead-man monitor

Scheduled every minute:

```text
query runSessions status=active
where last_seen_at < now - stale_threshold
```

State should be edge-triggered:

- first transition healthy → stale: create one warning incident/event;
- do not send every minute;
- on telemetry recovery: mark connection warning resolved and optionally send a low-priority recovery notification.

Recommended starting engineering threshold: 120–180 seconds, configurable. This is about connectivity, not physiology.

## 8. FCM fan-out

For each active caregiver device:

- send notification with incident ID;
- keep lock-screen body privacy-preserving;
- put full details behind authenticated API/read.

If a token is invalid/unregistered, mark device token inactive.

## 9. Firestore security rules principle

- clients can read only families they belong to;
- caregiver cannot write runner telemetry;
- telemetry/events enter via trusted server endpoint;
- device token owner can register/update own token;
- incident acknowledgement only allowed for family member.

## 10. Environments

Create separate Firebase projects:

- `safe-run-dev`
- `safe-run-staging`
- `safe-run-prod`

Never test alert fan-out against production family members from debug builds.

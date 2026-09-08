# 05 — Backend API Specification

Machine-readable version: `openapi.yaml`.

## 1. Authentication model

Two auth modes:

### User auth

Used for account/family/session creation and reads.

```text
Authorization: Bearer <Firebase ID token>
```

### Session ingest token

At run start, backend returns an opaque token valid only for the single run session and short TTL (for example 4 hours).

Advantages:

- iPhone gateway does not need to refresh a full user token on every 10-second packet;
- token scope is tiny;
- token can be invalidated when run ends.

Store token in iPhone Keychain, never in logs.

## 2. Start session

`POST /v1/run-sessions`

Request:

```json
{
  "client_session_id": "watch-generated-uuid",
  "watch_model": "Apple Watch Series 10",
  "app_version": "0.1.0",
  "config_version": 3
}
```

Response `201`:

```json
{
  "session_id": "server-uuid",
  "ingest_token": "opaque-secret",
  "expires_at": "2026-09-07T18:00:00Z",
  "server_time": "2026-09-07T14:00:00Z"
}
```

Idempotency: `client_session_id` must return the same active session if retried.

## 2.1 Restart reconciliation

`POST /v1/run-sessions/reconcile` uses Firebase user auth and accepts at most 50
`client_session_ids`. It returns only mappings owned by that runner, including
client/server session IDs, `active|ended|abandoned`, `last_seq`, and related
incident IDs. It never returns ingest tokens, heart rate, location, or phone data.

## 3. Telemetry ingestion

`POST /v1/run-sessions/{session_id}/telemetry`

Headers:

```text
Authorization: Bearer <ingest_token>
Idempotency-Key: <packet_id>
Content-Type: application/json
```

Body is the telemetry envelope.

Response:

```json
{
  "accepted": true,
  "last_seq": 42,
  "server_time": "..."
}
```

Backend behavior:

- validate token scope + expiry;
- dedupe packet;
- update `last_seen_at` using server time;
- update latest snapshot;
- optionally persist one historical sample every 30 s instead of all 10 s packets;
- never trigger medical diagnosis from telemetry endpoint.

## 4. Event ingestion

`POST /v1/run-sessions/{session_id}/events`

Body: event envelope.

`check_in_started` creates a `check_in` incident without push, and `check_in_ok`
resolves that incident without fan-out. `check_in_timeout` and
`check_in_help_requested` promote the same incident to `alerted` and create one
logical push fan-out. Because critical P0 packets may overtake lifecycle P1
packets, an escalation may create the alerted incident before its start event;
the late start event must never downgrade it. `manual_sos` creates an alerted
incident and supersedes an active automatic check-in.

`manual_sos_cancelled` is a critical-priority state update with a new `event_id` and the original `incident_id`. It can only cancel a matching manual-SOS incident in the same session. It never creates a new incident; if alert fan-out has already begun, it creates one idempotent cancellation update fan-out.

Response:

```json
{
  "accepted": true,
  "incident_id": "uuid",
  "incident_status": "alerted"
}
```

## 5. End session

`POST /v1/run-sessions/{session_id}/end`

Body:

```json
{
  "reason": "user_stopped",
  "last_seq": 260
}
```

Effects:

- mark session ended;
- revoke ingest token;
- close non-critical connection-loss incidents;
- preserve unresolved critical incident.

An active session with no valid packet for 180 seconds moves once from
`healthy` to `stale`. A valid packet resolves that connection warning without a
recovery push. A session continuously stale for 24 hours becomes `abandoned`
and rejects future ingest with `SESSION_INACTIVE`.

## 6. Device token registration

`POST /v1/devices`

User-authenticated.

```json
{
  "platform": "ios",
  "role": "caregiver",
  "fcm_token": "...",
  "app_version": "0.1.0"
}
```

Backend should support token rotation and soft-delete invalid tokens after FCM feedback.

Milestone D requires a stable client-generated `device_id`. Re-registering the same ID rotates its token. `DELETE /v1/devices/{device_id}` soft-deactivates it and removes the stored token. A caregiver registration is accepted only for an active caregiver family member.

## 7. Read active family session

`GET /v1/families/{family_id}/active-run`

Returns only if requester is an authorized family member.

## 8. Get incident

`GET /v1/incidents/{incident_id}`

Includes latest context and acknowledgement state.
It may include the provisioned runner display name and E.164 phone number, but only after server-side family membership authorization.

## 9. Acknowledge incident

`POST /v1/incidents/{incident_id}/acknowledge`

```json
{
  "action": "seen"
}
```

Possible future actions:

- `calling_runner`
- `going_to_runner`
- `resolved`

The Milestone D implementation accepts only `seen`, preserves the first acknowledgement, and treats retries idempotently.

## 10. HTTP error model

```json
{
  "error": {
    "code": "SESSION_TOKEN_EXPIRED",
    "message": "Ingest token expired",
    "retryable": false,
    "request_id": "uuid"
  }
}
```

Common codes:

- `UNAUTHORIZED`
- `FORBIDDEN`
- `SESSION_NOT_FOUND`
- `SESSION_ENDED`
- `SESSION_TOKEN_EXPIRED`
- `DUPLICATE_PACKET`
- `INVALID_SCHEMA`
- `RATE_LIMITED`
- `INTERNAL`

## 11. Rate limits

For family-scale MVP:

- telemetry: allow at least 12 requests/min/session;
- events: low volume, burst allowed;
- reads: standard authenticated limits.

Server should reject pathological 1 Hz telemetry if client bug occurs, but never rate-limit a critical event merely because telemetry was excessive. Keep separate buckets.

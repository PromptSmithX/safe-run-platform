# 10 — Security & Privacy

## 1. Data classification

Treat as highly sensitive:

- heart rate;
- precise location;
- run history;
- incident history;
- family relationships.

## 2. Data minimization

MVP should collect only what it needs for safety:

- HR latest/short trend;
- location during active run;
- session timestamps;
- alert events;
- device delivery metadata.

Avoid collecting unrelated HealthKit data.

## 3. Encryption

- TLS for all client-server traffic.
- Firebase/Cloud provider encryption at rest.
- iPhone ingest token in Keychain.
- no secrets in UserDefaults, logs, crash breadcrumbs, analytics events.

## 4. Authentication/authorization

- Firebase Auth for people.
- family membership checked server-side.
- short-lived ingest token scoped to exactly one run session.
- caregiver read permissions only for families they belong to.

## 5. Push notification privacy

Lock screen may be visible to others. Prefer:

`Safe Run: cần kiểm tra. Mở ứng dụng để xem chi tiết.`

instead of:

`HR 178, vị trí chính xác..., nghi rung nhĩ`.

## 6. Retention suggestion

For early MVP:

- latest live snapshot: overwritten continuously;
- raw/coalesced telemetry: 24–72 h for debugging, then delete;
- incident context: retain longer only with clear family/user expectation;
- logs: redact tokens and precise health payloads.

Make retention configurable before any wider release.

## 7. Threat model

### Stolen caregiver account

Risk: attacker sees location/health status.

Mitigation:

- platform auth + secure session;
- re-auth for sensitive family management;
- remove device tokens on sign-out.

### Forged telemetry

Risk: fake alerts or hiding real state.

Mitigation:

- session-scoped high-entropy token;
- server validates runner/session ownership;
- rate limiting;
- idempotency.

### Notification spam

Risk: duplicate incidents.

Mitigation:

- incident ID dedupe;
- edge-triggered transitions;
- per-incident notification state.

### Sensitive logs

Risk: health/location leakage.

Mitigation:

- structured logs with packet/event IDs but no exact payload by default;
- debug payload logging only on development builds.

## 8. Product/legal boundary

For family/internal prototype, present the system as a safety communication tool. Before public commercialization or making claims that it detects arrhythmia, predicts stroke, or substitutes clinical monitoring, obtain appropriate medical/regulatory/legal review for the markets where it will be offered.

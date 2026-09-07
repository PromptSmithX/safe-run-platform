# 13 — Roadmap

## Milestone A — Local Watch prototype

Deliver:

- outdoor workout starts/stops;
- HR live;
- GPS latest;
- fake-data mode;
- no backend.

Exit: 60-minute physical-device workout works.

## Milestone B — Watch → iPhone transport

Deliver:

- WCSession immediate packet;
- durable queue/ACK;
- debug diagnostics;
- mirrored workout lifecycle.

Exit: iPhone locked still receives packet during real workout.

## Milestone C — Backend ingestion

Deliver:

- auth/session;
- telemetry/events;
- Firestore snapshot;
- idempotency;
- staging environment.

Exit: 1-hour run does not create missing/duplicate sequence anomalies beyond intentionally dropped/retried packets.

## Milestone D — Manual SOS

Deliver:

- Watch SOS;
- backend incident;
- caregiver push + incident detail.

Exit: repeated end-to-end physical tests under normal network are consistently delivered.

## Milestone E — Check-in + simple rule

Deliver:

- CheckInCoordinator;
- configured sustained-high-HR rule;
- cooldown;
- no-response escalation.

Exit: synthetic and real safe tests show acceptable false-positive behavior.

## Milestone F — Reliability beta

Deliver:

- dead-man monitor;
- reconnect recovery;
- crash recovery;
- production privacy/logging hardening;
- TestFlight family beta.

## Phase 2 candidates

### Fall Detection integration

Requires Apple entitlement for `CMFallDetectionManager`.

### Critical Alerts

Requires Apple Critical Alerts entitlement. Use only when entitlement and product justification are approved.

### Better location sharing

- route trail;
- safe-zone / remote-area indicators;
- caregiver navigation link.

### Personalized anomaly engine

Only after collecting enough safe test data and defining appropriate validation. Keep diagnostic claims out unless independently validated and reviewed.

### Cellular Watch support

If runner later upgrades to GPS + Cellular:

- add a Watch→backend direct fallback path;
- still keep iPhone gateway when available;
- test background/network routing on real devices thoroughly.

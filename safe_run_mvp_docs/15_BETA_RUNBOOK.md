# Safe Run beta runbook

## Provisioning

Use a Firebase staging project with billing, Cloud Scheduler API, Firestore TTL, APNs key and signed runner/caregiver builds. Provision family membership and test E.164 phone data through the trusted admin process. Never run the emulator seed outside a `demo-*` project.

## Before each TestFlight build

Run `bash Scripts/verify-f.sh`, review Firestore indexes/TTL, verify standard (not Critical Alert) notification capability, and confirm Release contains no failure-injection launch behavior. Inspect logs and support export for tokens, HR, GPS, phone numbers, FCM tokens and family relationships.

## Device matrix

Complete five runs of at least 60 minutes, including one 120-minute run. Cover locked iPhone, Bluetooth loss for two minutes, Internet loss/recovery, Watch/iPhone relaunch, stale-session simulation, SOS, check-in OK and timeout. Repeat the D matrix of 20 normal-network SOS events and compare hop timestamps.

## No-network limitation

The Watch has no direct cloud fallback. An event remains in its durable outbox until the runner iPhone is reachable; the iPhone then retains it until Internet returns. UI wording must say queued, never delivered, until backend evidence exists.

## Incident troubleshooting and rollback

Check IDs and state transitions only—never raw payloads. Inspect Watch persistence diagnostics, iPhone DB integrity/queue counts, backend request/error IDs, marker phase and delivery attempt status. If a release regresses durability or privacy, stop beta distribution, roll back to the last verified TestFlight build, preserve affected databases/log IDs, revoke staging tokens, and do not mark incidents safe automatically.

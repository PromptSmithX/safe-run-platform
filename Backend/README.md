# Safe Run Firebase backend

This directory contains the emulator-first Milestone C backend. It does not deploy or create Firebase projects.

Requirements: Node.js 22, npm, and a Java JDK supported by Firebase Emulator Suite. From the repository root run:

```powershell
./Scripts/verify-c-backend.ps1
```

The fixed local project ID is `demo-safe-run`. Real project aliases are examples only in `.firebaserc.example`; copy that file to the ignored `.firebaserc` and replace IDs before any explicit deployment. Never commit `GoogleService-Info.plist`, ingest tokens, Firebase service-account keys, or emulator exports containing real health/location data.

The backend exposes only session creation, telemetry/event ingestion, and session end. A critical event creates a pending fan-out marker but Milestone C intentionally sends no push notification.
# Milestone D caregiver provisioning and push

The public API does not create family relationships. For Emulator testing, create the
runner and caregiver with Auth Emulator first, then run:

```text
npm run seed:caregiver -- --runner=<runner-uid> --caregiver=<caregiver-uid> --phone=+84901234567
```

The command refuses non-`demo-*` projects and requires `FIRESTORE_EMULATOR_HOST`.
Staging and production membership plus `users/{runnerUid}.phone_e164` must be provisioned
through a trusted administrator process.

The Firestore emulator uses a fake push sender and writes privacy-safe messages to
`debugPushOutbox`. It is not evidence of APNs/FCM delivery. Real-device testing requires
a Firebase Apple app, `GoogleService-Info.plist`, an uploaded APNs authentication key,
the FCM API, signing, and deployed `api` plus `fanoutIncident` functions.

Only standard notifications are used. Do not add the Apple Critical Alerts entitlement.

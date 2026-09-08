# Safe Run Firebase backend

This directory contains the emulator-first Milestone C backend. It does not deploy or create Firebase projects.

Requirements: Node.js 22, npm, and a Java JDK supported by Firebase Emulator Suite. From the repository root run:

```powershell
./Scripts/verify-c-backend.ps1
```

The fixed local project ID is `demo-safe-run`. Real project aliases are examples only in `.firebaserc.example`; copy that file to the ignored `.firebaserc` and replace IDs before any explicit deployment. Never commit `GoogleService-Info.plist`, ingest tokens, Firebase service-account keys, or emulator exports containing real health/location data.

The backend exposes only session creation, telemetry/event ingestion, and session end. A critical event creates a pending fan-out marker but Milestone C intentionally sends no push notification.

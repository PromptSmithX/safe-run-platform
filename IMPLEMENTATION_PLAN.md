# Safe Run — Implementation Control Plan

> Operational handoff for implementation work. This file tracks execution state and
> decisions; product requirements, architecture, API contracts, and test details remain
> authoritative in `safe_run_mvp_docs/`.

## AI start here

Before making any implementation change:

1. Read this file from top to bottom, then read the **Read first** documents for the current milestone.
2. Inspect the actual workspace, working tree, source, and tests. Treat the repository as the truth for what has already been implemented.
3. Work only on the current milestone. Do not begin a later milestone until the current milestone's exit criteria are verified.
4. Preserve the locked decisions below. Record any approved change in the decision log before relying on it.
5. After implementation, update the milestone status and add a handoff entry only when the listed verification has actually passed.

### Status vocabulary

- `not_started` — no implementation work has begun.
- `in_progress` — implementation is underway; the exit criteria are not yet all verified.
- `blocked` — progress needs an external decision, account, entitlement, device, or environment change.
- `complete` — all deliverables and exit criteria have been verified.

## Current snapshot

| Field | Value |
| --- | --- |
| Repository maturity | M0 scaffold, Milestone A Watch prototype, and Milestone B reliable Watch-to-iPhone transport source exist. Apple builds/tests and physical-device validation are pending. |
| Current milestone | `B — Watch-to-iPhone transport (at risk; M0/A verification deferred)` |
| Current status | `blocked` |
| Exact next action | On macOS with XcodeGen/Xcode installed, run `bash Scripts/verify-b.sh`; resolve all generation/build/test failures, then execute the M0/A/B physical-device test matrices before changing any milestone to complete. |
| Known implementation prerequisite | Build and device validation require macOS with a current Xcode/watchOS SDK plus physical Apple Watch and iPhone. |
| Known blockers | The current Windows host has no Swift, XcodeGen, or Xcode, so the generated project and Swift tests cannot be verified here. |

## Locked MVP decisions

- Apple Watch owns workout lifecycle, HealthKit heart-rate collection, GPS collection, local safety-rule evaluation, check-in UX, and manual SOS creation.
- WatchConnectivity immediate messaging is the near-realtime Watch-to-iPhone path. Workout mirroring is only for lifecycle and recovery; it is never the sole critical-event transport.
- The runner's iPhone is the internet gateway: it durably accepts Watch packets before ACKing, prioritizes critical events, and uploads to the backend.
- Firebase Auth, Firestore, Cloud Functions/Cloud Run, and FCM are the MVP backend baseline. Telemetry and events enter through authenticated HTTPS ingestion rather than direct client Firestore writes.
- Packet, event, and incident IDs must remain idempotent. Critical events are retained and retried; only normal telemetry may be coalesced or dropped under bounded storage pressure.
- Telemetry target cadence is about 10 seconds; critical events bypass the cadence and send immediately.
- The product is a safety communication tool, not a medical device or diagnostic. Do not claim AF detection, stroke detection, or emergency-service dispatch.
- Fall Detection, Critical Alerts, ECG streaming, AI/ML diagnosis, Android caregiver support, and direct cellular-Watch backend fallback are outside the MVP unless explicitly approved as a later phase.

## Milestone plan

### M0 — Repository bootstrap

- Status: `blocked`
- Read first: [Prompt 0](safe_run_mvp_docs/12_VIBE_CODING_PROMPTS.md), [project tree](safe_run_mvp_docs/PROJECT_TREE.md), [data contracts](safe_run_mvp_docs/04_DATA_CONTRACTS.md), and [test plan](safe_run_mvp_docs/11_TEST_PLAN.md).
- Deliver: `SafeRun.xcworkspace`; iOS companion and watchOS app targets; shared Swift domain target/package; Codable models for run state, telemetry/event envelopes and payloads, safety events, severity, and runner configuration; JSON serialization and sequence-ID tests.
- Do not implement: HealthKit collection, WatchConnectivity, networking, Firebase, alert rules, or production UI.
- Verify: workspace and all targets build on macOS/Xcode; shared-model tests cover valid encode/decode, invalid/mismatched schema versions, and stable packet/sequence identity.
- Exit: project structure matches the agreed tree closely enough to start the Watch prototype without moving domain types later.

### A — Local Watch prototype

- Status: `blocked`
- Read first: [roadmap](safe_run_mvp_docs/13_ROADMAP.md), [watchOS guide](safe_run_mvp_docs/06_WATCHOS_GUIDE.md), [state machines](safe_run_mvp_docs/03_STATE_MACHINES.md), and Prompts 1–2 in [prompt pack](safe_run_mvp_docs/12_VIBE_CODING_PROMPTS.md).
- Deliver: outdoor running workout lifecycle; minimum HealthKit and location authorization; live HR and elapsed-time Watch UI; latest usable GPS/speed data; debug fake-health and fake-location providers.
- Do not implement: Watch-to-iPhone transport, cloud access, caregiver screens, or automatic alerts.
- Verify: unit tests cover sensor freshness/quality helpers and fake providers; a physical-device workout runs for at least 60 minutes with expected HR, elapsed time, and location behavior.
- Exit: the Watch can safely collect and display local data through a real workout without relying on a phone or backend.

### B — Watch-to-iPhone transport

- Status: `blocked` (source implemented at risk; Apple toolchain and device verification pending)
- Read first: [architecture](safe_run_mvp_docs/02_ARCHITECTURE.md), [watchOS guide](safe_run_mvp_docs/06_WATCHOS_GUIDE.md), [iOS gateway guide](safe_run_mvp_docs/07_IOS_GATEWAY_GUIDE.md), [state machines](safe_run_mvp_docs/03_STATE_MACHINES.md), and Prompts 3–5 in [prompt pack](safe_run_mvp_docs/12_VIBE_CODING_PROMPTS.md).
- Deliver: versioned envelopes with monotonic sequence numbers; Watch retry queue; immediate `WCSession` messaging; iPhone durable gateway queue; persist-before-ACK semantics; priority ordering; mirrored-workout lifecycle/recovery; diagnostics on both devices.
- Do not implement: backend upload, Firebase auth, caregiver push, or automatic health rules.
- Verify: unit tests cover serialization, queue recovery, dedupe, and P0-before-P3 ordering; physical tests prove an iPhone with a locked screen receives packets, and a forced disconnect/reconnect flushes queues without duplicate events.
- Exit: Watch-to-iPhone packets remain recoverable through normal connectivity loss, iPhone restarts, and duplicated sends.

### C — Backend ingestion and iPhone uploader

- Status: `not_started`
- Read first: [API specification](safe_run_mvp_docs/05_API_SPEC.md), [OpenAPI](safe_run_mvp_docs/openapi.yaml), [schemas](safe_run_mvp_docs/schemas/), [Firebase blueprint](safe_run_mvp_docs/08_BACKEND_FIREBASE.md), [security/privacy](safe_run_mvp_docs/10_SECURITY_PRIVACY.md), and Prompts 6–7 in [prompt pack](safe_run_mvp_docs/12_VIBE_CODING_PROMPTS.md).
- Deliver: Firebase environments; user-authenticated session creation; session-scoped hashed ingest tokens; telemetry/event/end ingestion; idempotency; Firestore live snapshots; iPhone HTTPS upload worker with priority, retry, backoff, and Keychain token storage.
- Do not implement: caregiver notification fan-out, manual SOS UI, auto-alert rules, or Phase 2 features.
- Verify: emulator/backend tests prove idempotent session creation and duplicate event safety; iPhone queue handles retryable failures and stops retrying permanent auth/schema errors; a staged one-hour run has no unexplained sequence loss or duplicate processing.
- Exit: the backend accepts and reconciles real Watch-originated data through the iPhone gateway with a fresh server-side session snapshot.

### D — Manual SOS end to end

- Status: `not_started`
- Read first: [PRD](safe_run_mvp_docs/01_PRD_MVP.md), [alert engine](safe_run_mvp_docs/09_ALERT_ENGINE.md), [iOS gateway guide](safe_run_mvp_docs/07_IOS_GATEWAY_GUIDE.md), [Firebase blueprint](safe_run_mvp_docs/08_BACKEND_FIREBASE.md), and Prompt 8 in [prompt pack](safe_run_mvp_docs/12_VIBE_CODING_PROMPTS.md).
- Deliver: guarded but quick Watch SOS interaction; Watch-generated event and incident IDs; P0 transmission/retry; idempotent incident creation; caregiver device registration, standard push, and incident detail with last known context and call action.
- Do not implement: automatic physiological alerts, Critical Alerts entitlement, or emergency-service calling.
- Verify: backend tests prove duplicate critical events create one incident and one fan-out marker; repeat physical end-to-end SOS tests on a normal network capture timestamps at Watch, iPhone, backend, push send, and caregiver display.
- Exit: manual SOS is consistently delivered once to each active caregiver under normal connectivity and exposes only privacy-appropriate lock-screen content.

### E — Check-in and first automatic rule

- Status: `not_started`
- Read first: [alert engine](safe_run_mvp_docs/09_ALERT_ENGINE.md), [state machines](safe_run_mvp_docs/03_STATE_MACHINES.md), [data contracts](safe_run_mvp_docs/04_DATA_CONTRACTS.md), and Prompts 9–10 in [prompt pack](safe_run_mvp_docs/12_VIBE_CODING_PROMPTS.md).
- Deliver: single-active check-in coordinator with haptics/countdown; OK/help/timeout events; optional configured sustained-high-HR rule; freshness gates; warm-up grace; cooldown; hysteresis; deterministic rule-test timelines.
- Do not implement: medical diagnoses, inferred population-based HR thresholds, additional auto rules, or AI/ML classification.
- Verify: unit tests cover noisy spikes, stale HR, sustained threshold crossing, single active check-in, OK cooldown, help, timeout, and duplicate upload behavior; safe physical tests show conservative false-positive behavior.
- Exit: only a user-configured, adequately sampled, sustained condition can request a check-in, and a timeout or help response uses the established SOS incident path exactly once.

### F — Reliability beta

- Status: `not_started`
- Read first: [test plan](safe_run_mvp_docs/11_TEST_PLAN.md), [security/privacy](safe_run_mvp_docs/10_SECURITY_PRIVACY.md), [backend blueprint](safe_run_mvp_docs/08_BACKEND_FIREBASE.md), [architecture](safe_run_mvp_docs/02_ARCHITECTURE.md), and Prompts 11–12 in [prompt pack](safe_run_mvp_docs/12_VIBE_CODING_PROMPTS.md).
- Deliver: edge-triggered stale-session monitor; recovery/reconciliation after app or connectivity restart; failure-injection controls; redacted release logging; retention configuration; TestFlight-ready diagnostics and operations notes.
- Do not implement: Phase 2 entitlements or unvalidated medical capabilities.
- Verify: automated tests cover stale-to-warning transition, recovery, incident preservation, authorization, idempotency, and queue recovery; physical-device E2E tests cover locked iPhone, Bluetooth loss, internet loss, restart/relaunch where supported, SOS, check-in OK, and timeout.
- Exit: several real-world runs complete without unexplained session loss; manual SOS behavior and no-network limitations are documented; privacy/logging review confirms no health payload or token leaks in release logs.

## Phase 2 boundary

Phase 2 candidates are not part of any MVP milestone: Fall Detection entitlement, Critical Alerts entitlement, richer location sharing, personalized anomaly logic, regulatory review for medical claims, and direct cellular-Watch backend fallback. Create a new approved milestone before starting any of them.

## Decision log

| Date | Decision | Rationale | Source |
| --- | --- | --- | --- |
| 2026-09-07 | Use this file as the execution control plane; keep `safe_run_mvp_docs/` authoritative for specifications. | Future chats need current state without duplicating or drifting from technical contracts. | This plan |
| 2026-09-07 | Start at M0 and implement one milestone at a time. | The architecture depends on tested foundations, especially the Watch-to-iPhone critical path. | [Roadmap](safe_run_mvp_docs/13_ROADMAP.md) |
| 2026-09-08 | Allow Milestone A source work at risk while M0 remains blocked. | The user chose to defer macOS validation without falsely marking M0 complete. | User direction |
| 2026-09-08 | Declare workout and location background modes with `WKBackgroundModes=workout-processing` and `UIBackgroundModes=location`. | Apple assigns workout processing and continuous location to separate plist keys. | Apple platform requirements |
| 2026-09-08 | Allow Milestone B source work at risk while M0/A remain blocked. | The user explicitly requested the next implementation step while preserving evidence-based completion status. | User direction |
| 2026-09-08 | Use an atomic JSON retry queue on Watch and system SQLite on iPhone. | This keeps Watch persistence small and dependency-free while giving the gateway transactional dedupe and durable ordering. | Milestone B plan |
| 2026-09-08 | Restrict workout mirroring to lifecycle and recovery. | WatchConnectivity remains the durable packet and critical-event path; iPhone does not control the workout in B. | Locked architecture |

## Handoff log

Add a new entry after each completed or blocked implementation session. Do not claim a milestone is complete without the verification evidence named above.

### 2026-09-08: M0 scaffold prepared; macOS verification pending

- Milestone/status: `M0 — blocked`
- Completed: Added the XcodeGen project specification and workspace; minimal iOS/watchOS SwiftUI targets; local `SafeRunDomain` package; versioned telemetry/event contracts; packet sequencing; JSON coding; fixtures and unit tests; macOS bootstrap/verification scripts.
- Changed files: `project.yml`, `SafeRun.xcworkspace`, `Apps/`, `Packages/SafeRunDomain/`, `Scripts/`, and `.gitignore`.
- Verification run: Parsed both JSON fixtures with Node.js; parsed and checked the workspace XML reference; checked all expected scaffold files; scanned implementation paths for post-M0 frameworks/services.
- Verification result: Static checks passed. Swift tests, XcodeGen generation, and iOS/watchOS simulator builds were not run because this host lacks Swift/XcodeGen/Xcode.
- Decisions recorded: XcodeGen 2.46.0+; iOS 17/watchOS 10; placeholder IDs `com.saferun.mvp.ios` and `com.saferun.mvp.ios.watchkitapp`; generated `SafeRun.xcodeproj` remains untracked.
- Open risks or blockers: `project.yml` and Swift source still require compilation on macOS; signing is intentionally unset.
- Exact next action: Run `bash Scripts/verify-m0.sh` on macOS, resolve all failures, then mark M0 complete and move the current milestone to A.

### 2026-09-08: Milestone A Watch prototype source prepared

- Milestone/status: `A — blocked (implemented at risk; M0 also blocked)`
- Completed: Added WatchCore and WatchCoreTests targets; HealthKit workout authorization/start/HR/stop/save flow; Core Location authorization and quality filtering; fake workout/location providers; run-session view model; Watch start/active/end/error UI; background modes, usage descriptions, HealthKit entitlement, and A verification script.
- Changed files: `project.yml`, `Apps/Watch/`, `Apps/WatchCore/`, `Scripts/verify-a.sh`, and this plan.
- Verification run: Checked expected source/test files and project target declarations; confirmed separate workout/location background plist keys; found 11 WatchCore unit-test cases; scanned Watch implementation for WatchConnectivity, Firebase, mirroring, SOS, and safety-rule code.
- Verification result: Static structure and scope checks passed. Swift compilation, XcodeGen validation, unit tests, simulator builds, and physical-device tests were not run because this host lacks the Apple toolchain.
- Decisions recorded: Location quality defaults to 20 seconds/50 meters with a 5-meter distance filter; location denial is nonfatal; Debug simulator or `-SafeRunFakeData` selects fake providers; HR older than five seconds is hidden as stale.
- Open risks or blockers: M0 and A may still expose compiler/project-generation issues on macOS; signing and real HealthKit/location behavior are unverified; the required 60-minute Watch test remains outstanding.
- Exact next action: Run `bash Scripts/verify-a.sh` on macOS, resolve every failure, then perform the authorization, background, workout-save, GPS, and 60-minute Apple Watch test matrix before marking M0/A complete.

### 2026-09-08: Milestone B reliable transport source prepared

- Milestone/status: `B — blocked (implemented at risk; M0/A also blocked)`
- Completed: Added transport contracts and ACK semantics; atomic Watch retry/session queues; priority drain and bounded telemetry retention; local run lifecycle/10-second telemetry packet generation; immediate WatchConnectivity bridge; transactional SQLite iPhone gateway with dedupe and persist-before-ACK; lifecycle-only workout mirroring; diagnostics on both apps; Domain, WatchCore, and PhoneCore tests; and the B verification script.
- Changed files: `project.yml`, `Packages/SafeRunDomain/`, `Apps/Watch/`, `Apps/WatchCore/`, `Apps/iOS/`, `Apps/PhoneCore/`, `Scripts/verify-b.sh`, and this plan.
- Verification run: Inspected all new source paths and target declarations; confirmed WatchConnectivity/HealthKit/SQLite dependencies; confirmed persist-before-send and commit-before-ACK code paths; scanned app source for Firebase/network uploader/check-in/automatic-rule implementation; checked this Windows host for Swift, XcodeGen, and Xcode.
- Verification result: Static structure and scope checks passed. Swift compilation, XcodeGen generation, unit tests, simulator builds, locked-iPhone transport, disconnect/reconnect, restart recovery, and physical workout mirroring were not run because this host has no Apple toolchain or paired devices.
- Decisions recorded: JSON Watch queue capped at 120 P3 packets; SQLite gateway capped at 10,000 pending P3 packets; P0-P2 are not pressure-evicted; 15-second ACK timeout; local UUID session IDs; SQLite WAL plus FULL synchronous commits; complete-until-first-user-authentication file protection.
- Open risks or blockers: New Swift concurrency annotations, WatchConnectivity delegate signatures, HealthKit mirroring APIs, SQLite module linkage, generated entitlements, and simulator destinations require macOS compilation; background delivery and recovery semantics require a paired Watch/iPhone; M0/A verification remains outstanding.
- Exact next action: Run `bash Scripts/verify-b.sh` on macOS, fix every generation/build/test failure, then execute the M0/A/B physical-device test matrices before marking any blocked milestone complete.

### Template — YYYY-MM-DD: concise session title

- Milestone/status: `M? — not_started|in_progress|blocked|complete`
- Completed: 
- Changed files: 
- Verification run: 
- Verification result: 
- Decisions recorded: 
- Open risks or blockers: 
- Exact next action: 

## Reusable prompt for a new chat

```text
Read IMPLEMENTATION_PLAN.md first. Then read every “Read first” document for the
current milestone, inspect the actual repository and tests, and reconcile the plan
with the code before changing anything. Continue only the exact next action in the
current milestone. Preserve locked decisions, do not start a later milestone until
the current exit criteria are verified, and update IMPLEMENTATION_PLAN.md with
evidence-based status plus a handoff entry when the session ends.
```

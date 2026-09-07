# 07 — iOS Gateway + Family App Guide

You can ship one iOS app with two roles: `runner` and `caregiver`. The runner’s iPhone acts as Watch gateway; caregiver devices mainly receive alerts and show status.

## 1. Runner iPhone responsibilities

- activate WCSession at app startup;
- receive Watch messages in background;
- durable queue before network upload;
- create backend run session;
- hold short-lived ingest token in Keychain;
- upload critical events ahead of telemetry;
- register mirrored workout handler early;
- expose diagnostics.

## 2. WCSession receiver

```swift
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    let gateway: GatewayWorker

    func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        Task {
            let result = await gateway.acceptFromWatch(messageData)
            replyHandler(result.ackData)
        }
    }
}
```

Important principle: **persist first, ACK second**.

The ACK means “iPhone safely accepted this packet”, not necessarily “server already committed it”. This prevents Watch from retrying excessively while iPhone can handle later server retry.

For P0 critical event, optionally return a second semantic state in the ACK (`queued` vs `server_accepted`) if Watch UI needs it.

## 3. Durable GatewayQueue

Implementation options:

- SQLite/GRDB;
- SwiftData/Core Data;
- simple append-only JSON files for first prototype.

Recommended fields:

```text
local_id
packet_id
session_id
priority
payload_blob
enqueued_at
attempt_count
next_attempt_at
server_acked_at
```

Atomicity matters more than elegance.

## 4. Upload worker

Rules:

- single serial actor/queue;
- always process priority P0 before P3;
- use `URLSession` small HTTPS requests;
- retry retryable 5xx/timeouts with exponential backoff + jitter;
- do not retry 4xx schema/auth failures forever;
- on ingest-token expiry, refresh session auth once or mark session needs reconciliation.

Example backoff:

```text
1s, 2s, 5s, 10s, 30s, 60s cap
```

Critical events may retry more aggressively than telemetry.

## 5. Background execution behavior

Apple documents that Watch `sendMessage` can wake the corresponding iOS app in background. The receiver should do minimal work:

1. decode;
2. persist;
3. schedule/start a small upload;
4. return ACK.

Avoid heavy UI/model computation in the delegate callback.

## 6. Mirrored workout handler

Set as soon as app initializes:

```swift
healthStore.workoutSessionMirroringStartHandler = { mirroredSession in
    mirroredSession.delegate = self
    self.remoteSession = mirroredSession
}
```

This helps lifecycle/reconnect. Expect multiple callbacks after disconnect/reconnect; never assume one immutable instance for the whole run.

## 7. Family push setup

Caregiver app:

- ask notification permission during onboarding with context;
- register APNs/FCM token;
- POST token to `/v1/devices`;
- handle token refresh;
- deep-link notification to incident detail.

Normal MVP push: standard notification sound. Critical Alerts require Apple entitlement and are Phase 2.

## 8. Notification payload concept

```json
{
  "title": "Safe Run: cần kiểm tra",
  "body": "Không phản hồi sau check-in. Nhấn để xem vị trí gần nhất.",
  "incident_id": "...",
  "session_id": "...",
  "severity": "critical"
}
```

Do not include unnecessary health details in lock-screen text. HR/location can be shown after app unlocks.

## 9. Family live screen

Suggested cards:

- Runner status: `Đang chạy / Đã kết thúc / Mất cập nhật`.
- Last seen: relative + absolute timestamp.
- HR latest.
- Map pin last location.
- Current incident banner.
- Buttons: `Gọi`, `Đã xem`.

If data is stale, display `Dữ liệu cuối lúc 21:03` instead of pretending it is live.

## 10. Runner phone diagnostics screen

Show:

- Watch reachable yes/no.
- Active session id.
- last Watch seq received.
- gateway queue count by priority.
- last backend success/error.
- current network reachability.
- FCM/APNs registration state.

This screen is essential during TestFlight.

# 11 — Test Plan

## 1. Golden rule

Test the critical path on **physical Apple Watch + physical iPhone**. Apple’s watch networking documentation explicitly recommends real-device testing because simulator behavior can differ.

## 2. Test environments

Minimum matrix:

- Apple Watch Series 10 GPS + runner iPhone.
- iPhone locked, screen off.
- Watch screen off during run.
- cellular good / weak / no data.
- Bluetooth on/off from Settings for intentional disconnect tests.
- app foreground/background/terminated scenarios where supported.

## 3. Unit tests — Watch

### Rule engine

- sustained high HR trigger.
- noisy single spike ignored.
- stale HR ignored.
- cooldown.
- incident priority.
- user OK / help / timeout.

### Serialization

- TelemetryEnvelope encode/decode.
- schema version mismatch.
- packet ID/seq stability after retry.

### Queue

- FIFO within same priority.
- P0 jumps ahead of P3.
- critical event never evicted.

## 4. Unit tests — iPhone

- WC message persisted before ACK.
- duplicate packet does not duplicate queue row.
- network retry behavior.
- auth/session token expiry.
- queue recovery after app restart.

## 5. Backend tests

- idempotent session creation by `client_session_id`.
- duplicate packet accepted without side effect.
- duplicate critical event produces one Incident.
- duplicate Incident produces one fan-out.
- unauthorized family read rejected.
- ended session rejects new normal telemetry.
- stale session creates one warning, not one per scheduler run.

## 6. End-to-end test cases

### E2E-01 Normal 30-minute run

Expected:

- HR/GPS visible.
- backend last_seen remains fresh.
- no alert.
- no queue growth over time.

### E2E-02 iPhone locked

Start run, lock iPhone, place in bag.

Expected:

- Watch packets continue reaching backend.
- manual SOS still reaches family.

### E2E-03 Bluetooth disconnect

During run, disable Bluetooth/Wi-Fi on runner iPhone from Settings to force WatchConnectivity failure.

Expected:

- Watch queue grows.
- UI shows degraded connection.
- reconnect flushes queue.
- no duplicate alert.

### E2E-04 iPhone loses Internet but Watch reachable

Expected:

- iPhone accepts/ACKs Watch packet after persisting.
- gateway queue grows.
- reconnect Internet flushes.

### E2E-05 Manual SOS

Repeat 20 times across good-network runs.

Capture:

- watch event timestamp;
- iPhone receive timestamp;
- backend receive timestamp;
- push send timestamp;
- caregiver display timestamp if instrumented.

Goal: characterize latency distribution; do not claim a medical SLA.

### E2E-06 Auto check-in OK

Inject threshold condition.

Expected:

- Watch asks check-in.
- tap OK.
- no critical push.
- cooldown prevents immediate re-trigger.

### E2E-07 Auto check-in timeout

Expected:

- one critical incident;
- all caregiver devices receive push;
- incident shows last known location/HR.

### E2E-08 App process restart

Kill/relaunch runner iOS app during active run where testing permits.

Expected:

- WCSession/mirrored session re-establishes;
- durable queue not lost;
- backend session remains same.

## 7. Chaos / failure injection switches

Debug builds should support:

- network artificial delay 2/5/15 s;
- server forced 500;
- token expired;
- packet duplication;
- packet reorder;
- 10% telemetry drop;
- fake stale GPS;
- fake stale HR;
- fake WC unreachable.

## 8. Metrics to log

Watch:

- session id / seq.
- HR freshness.
- WC reachable.
- local queue size.
- rule transitions.

Runner iPhone:

- message receive latency.
- queue depth.
- upload latency/retries.

Backend:

- ingest latency.
- duplicate rate.
- active session last_seen age.
- incident fan-out latency.

## 9. Beta exit criteria

Before family relies on it for real runs:

- at least several long real-world test runs in common routes;
- no unexplained session loss;
- manual SOS consistently delivered under normal network;
- known behavior documented for no-network zones;
- false-positive auto rules tuned conservatively or disabled until validated.

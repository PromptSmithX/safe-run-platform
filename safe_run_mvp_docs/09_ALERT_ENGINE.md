# 09 — Safety / Alert Engine

## 1. Design principle

The engine detects **conditions worth checking**, not a diagnosis.

Bad naming:

```text
afibDetected = true
strokeRisk = high
```

Better:

```text
highHeartRateSustained
unexpectedStopWithElevatedHR
noResponseAfterCheckIn
manualSOS
```

## 2. Configuration model

```swift
struct RunnerSafetyConfig: Codable {
    var highHRThresholdBPM: Double?
    var highHRSustainedSeconds: TimeInterval
    var checkInSeconds: Int
    var ruleCooldownSeconds: Int
    var staleHeartRateSeconds: Int
    var telemetryIntervalSeconds: Int
}
```

`highHRThresholdBPM` should be explicitly configured for the person, ideally discussed with their clinician. Do not infer a medical threshold solely from age inside MVP.

## 3. Rule 0 — Manual SOS

Trigger: user action.

Action:

- immediate critical incident;
- no check-in delay;
- include freshest HR/GPS available;
- retry aggressively.

This is the most deterministic and important alert.

## 4. Rule 1 — Sustained high HR

Example engineering logic:

```text
IF configured threshold exists
AND HR sample freshness < 5s
AND HR >= threshold for N consecutive seconds
THEN request check-in
```

Use a rolling window rather than one sample. Require enough valid samples.

MVP defaults should leave threshold unset until onboarding config is completed.

## 5. Rule 2 — Unexpected stop + concerning context

Potential trigger:

```text
was moving/running
then speed near zero for >= 30–60s
AND HR remains above configured concern threshold or recently spiked
THEN request check-in
```

This should be disabled or conservative in early beta because normal stops at traffic lights can cause many false positives.

## 6. Rule 3 — No response after check-in

Once any auto rule has legitimately opened a check-in:

- countdown 20 s (configurable);
- if user taps OK: resolve;
- if user taps help: critical;
- timeout: critical.

This is a strong escalation signal because it combines sensor concern + lack of response.

## 7. Rule 4 — Connectivity stale

Server-side, not Watch physiological rule.

- `last_seen` stale > threshold → warning.
- severity can increase only if there was already an unresolved local risk/incident before telemetry stopped.

## 8. Sensor quality gates

Rules must not evaluate blindly when:

- HR is stale;
- insufficient samples;
- GPS accuracy is poor;
- workout paused;
- user just started run and HR is ramping normally.

Add a warm-up grace period, e.g. first 2–3 minutes, for rules that depend on exercise dynamics. This is an engineering anti-noise measure, not a medical recommendation.

## 9. Cooldown / hysteresis

After `Tôi ổn`:

- same rule cannot re-open instantly;
- require HR to drop below threshold by a hysteresis margin or cooldown time.

Example concept:

```text
trigger at configured_threshold
re-arm only after HR < threshold - margin for 30s
```

Do not hard-code the margin as a clinical value; treat it as tunable product behavior.

## 10. Rule engine test vectors

### A — single noisy spike

```text
130, 132, 178, 133, 131
```

Expected: no incident.

### B — sustained high HR above configured threshold

Expected: one check-in, not repeated check-ins.

### C — user OK

Expected: event `check_in_ok`; incident resolved; cooldown active.

### D — timeout

Expected: exactly one critical incident and one notification fan-out.

### E — stale HR

Expected: do not trigger high-HR rule using old value.

### F — duplicate event upload

Expected: backend returns existing incident; no duplicate push.

## 11. Future research path

Only after telemetry and incident pipeline are stable:

- personalized baselines;
- pace/HR coupling anomaly;
- motion/fall entitlement;
- clinician-reviewed rule packs;
- regulatory assessment if marketed with medical claims.

import assert from "node:assert/strict";
import test from "node:test";
import { getApps, initializeApp } from "firebase-admin/app";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { RetentionSweeper, StaleSessionMonitor } from "../../maintenance";

const projectID = "demo-safe-run";
if (getApps().length === 0) initializeApp({ projectId: projectID });
const db = getFirestore();

test("stale monitor is edge-triggered, preserves critical incident and abandons after 24h", async () => {
  await fetch(`http://127.0.0.1:8080/emulator/v1/projects/${projectID}/databases/(default)/documents`, { method: "DELETE" });
  const now = new Date("2026-01-02T00:00:00Z");
  const session = db.collection("runSessions").doc("11111111-1111-4111-8111-111111111111");
  await session.set({ runner_uid: "runner", family_id: "family", client_session_id: "22222222-2222-4222-8222-222222222222", status: "active", connection_state: "healthy", active_incident_id: "critical-existing", last_seen_at: Timestamp.fromMillis(now.getTime() - 181_000), ingest_token_hash: "hash" });
  const monitor = new StaleSessionMonitor(undefined, 180);
  assert.deepEqual(await monitor.run(now), { stale: 1, abandoned: 0 });
  assert.deepEqual(await monitor.run(now), { stale: 0, abandoned: 0 });
  const stale = await session.get();
  assert.equal(stale.get("active_incident_id"), "critical-existing");
  assert.equal((await db.collection("incidents").where("session_id", "==", session.id).get()).size, 1);
  assert.equal((await db.collection("incidentFanoutMarkers").get()).size, 1);
  await session.update({ connection_stale_since: Timestamp.fromMillis(now.getTime() - 24 * 60 * 60 * 1000 - 1) });
  assert.deepEqual(await monitor.run(now), { stale: 0, abandoned: 1 });
  const abandoned = await session.get();
  assert.equal(abandoned.get("status"), "abandoned");
  assert.equal(abandoned.get("ingest_token_hash"), undefined);
});

test("privacy sweep removes expired mapping and scrubs ended latest data", async () => {
  const now = new Date("2026-02-01T00:00:00Z");
  const session = db.collection("runSessions").doc("33333333-3333-4333-8333-333333333333");
  await session.set({ status: "ended", last_seen_at: Timestamp.fromMillis(now.getTime() - 73 * 60 * 60 * 1000), latest_hr: 180, latest_lat: 10, latest_lon: 106 });
  const mapping = db.collection("clientRunSessions").doc("expired");
  await mapping.set({ expire_at: Timestamp.fromMillis(now.getTime() - 1) });
  await new RetentionSweeper().run(now);
  assert.equal((await session.get()).get("latest_hr"), undefined);
  assert.equal((await mapping.get()).exists, false);
});

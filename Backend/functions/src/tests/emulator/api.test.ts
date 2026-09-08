import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { assertFails, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc } from "firebase/firestore";
import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const projectID = "demo-safe-run";
const apiBase = `http://127.0.0.1:5001/${projectID}/asia-southeast1/api`;

async function anonymousUser(): Promise<{ idToken: string; localId: string }> {
  const response = await fetch("http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ returnSecureToken: true }),
  });
  assert.equal(response.status, 200);
  return await response.json() as { idToken: string; localId: string };
}

async function waitFor<T>(load: () => Promise<T | undefined>, timeoutMillis = 8_000): Promise<T> {
  const deadline = Date.now() + timeoutMillis;
  while (Date.now() < deadline) {
    const value = await load();
    if (value !== undefined) return value;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error("Timed out waiting for emulator side effect");
}

test("session and telemetry are authenticated and idempotent", async () => {
  await fetch(`http://127.0.0.1:8080/emulator/v1/projects/${projectID}/databases/(default)/documents`, { method: "DELETE" });
  const unauthorized = await fetch(`${apiBase}/v1/run-sessions`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_session_id: crypto.randomUUID() }),
  });
  assert.equal(unauthorized.status, 401);
  const user = await anonymousUser();
  const clientSessionID = crypto.randomUUID();
  const create = () => fetch(`${apiBase}/v1/run-sessions`, {
    method: "POST",
    headers: { authorization: `Bearer ${user.idToken}`, "content-type": "application/json" },
    body: JSON.stringify({ client_session_id: clientSessionID, app_version: "test" }),
  });
  const first = await create();
  assert.equal(first.status, 201);
  const firstSession = await first.json() as { session_id: string; ingest_token: string };
  const second = await create();
  assert.equal(second.status, 201);
  const rotated = await second.json() as { session_id: string; ingest_token: string };
  assert.equal(rotated.session_id, firstSession.session_id);
  assert.notEqual(rotated.ingest_token, firstSession.ingest_token);

  const packetID = crypto.randomUUID();
  const envelope = {
    schema_version: 1, packet_id: packetID, session_id: rotated.session_id, seq: 1,
    watch_timestamp: new Date().toISOString(), kind: "telemetry", payload: { elapsed_s: 1 },
  };
  const upload = () => fetch(`${apiBase}/v1/run-sessions/${rotated.session_id}/telemetry`, {
    method: "POST",
    headers: { authorization: `Bearer ${rotated.ingest_token}`, "idempotency-key": envelope.packet_id, "content-type": "application/json" },
    body: JSON.stringify(envelope),
  });
  const oldTokenResponse = await fetch(`${apiBase}/v1/run-sessions/${rotated.session_id}/telemetry`, {
    method: "POST",
    headers: { authorization: `Bearer ${firstSession.ingest_token}`, "idempotency-key": packetID, "content-type": "application/json" },
    body: JSON.stringify(envelope),
  });
  assert.equal(oldTokenResponse.status, 403);
  const accepted = await upload();
  const duplicate = await upload();
  assert.equal(accepted.status, 200);
  assert.equal((await duplicate.json() as { duplicate: boolean }).duplicate, true);

  envelope.packet_id = crypto.randomUUID();
  envelope.seq = 4;
  assert.equal((await upload()).status, 200);
  envelope.packet_id = crypto.randomUUID();
  envelope.seq = 3;
  assert.equal((await upload()).status, 200);
  if (getApps().length === 0) initializeApp({ projectId: projectID });
  const adminDB = getFirestore();
  assert.equal((await adminDB.collection("runSessions").doc(rotated.session_id).get()).get("last_seq"), 4);

  const caregiver = await anonymousUser();
  await Promise.all([
    adminDB.collection("users").doc(user.localId).set({ phone_e164: "+84901234567" }, { merge: true }),
    adminDB.collection("users").doc(caregiver.localId).set({
      display_name: "Caregiver", default_family_id: user.localId,
    }, { merge: true }),
    adminDB.collection("families").doc(user.localId).collection("members").doc(caregiver.localId).set({
      role: "caregiver", status: "active",
    }),
  ]);
  const caregiverDeviceID = crypto.randomUUID();
  const registration = await fetch(`${apiBase}/v1/devices`, {
    method: "POST",
    headers: { authorization: `Bearer ${caregiver.idToken}`, "content-type": "application/json" },
    body: JSON.stringify({
      device_id: caregiverDeviceID, platform: "ios", role: "caregiver",
      fcm_token: "fake-emulator-token", app_version: "0.1.0",
    }),
  });
  assert.equal(registration.status, 200);

  const eventID = crypto.randomUUID();
  const incidentID = crypto.randomUUID();
  const eventPacketID = crypto.randomUUID();
  const event = {
    schema_version: 1, packet_id: eventPacketID, session_id: rotated.session_id, seq: 2,
    watch_timestamp: new Date().toISOString(), kind: "event",
    payload: { event_id: eventID, event_type: "manual_sos", severity: "critical", incident_id: incidentID },
  };
  const eventUpload = () => fetch(`${apiBase}/v1/run-sessions/${rotated.session_id}/events`, {
    method: "POST", headers: { authorization: `Bearer ${rotated.ingest_token}`, "content-type": "application/json" },
    body: JSON.stringify(event),
  });
  assert.equal((await eventUpload()).status, 200);
  assert.equal((await eventUpload()).status, 200);
  assert.equal((await adminDB.collection("incidents").where("session_id", "==", rotated.session_id).get()).size, 1);
  assert.equal((await adminDB.collection("incidentFanoutMarkers").get()).size, 1);
  const push = await waitFor(async () => {
    const outbox = await adminDB.collection("debugPushOutbox").where("incident_id", "==", incidentID).get();
    return outbox.empty ? undefined : outbox.docs[0]?.data();
  });
  assert.equal(push?.body, "Safe Run: cần kiểm tra. Mở ứng dụng để xem chi tiết.");
  assert.equal(JSON.stringify(push).includes("+84901234567"), false);
  assert.equal(JSON.stringify(push).includes("heart_rate"), false);

  const incidentRead = await fetch(`${apiBase}/v1/incidents/${incidentID}`, {
    headers: { authorization: `Bearer ${caregiver.idToken}` },
  });
  assert.equal(incidentRead.status, 200);
  const detail = await incidentRead.json() as { runner_phone_e164: string; status: string };
  assert.equal(detail.runner_phone_e164, "+84901234567");
  assert.equal(detail.status, "alerted");

  const acknowledged = await fetch(`${apiBase}/v1/incidents/${incidentID}/acknowledge`, {
    method: "POST", headers: { authorization: `Bearer ${caregiver.idToken}`, "content-type": "application/json" },
    body: JSON.stringify({ action: "seen" }),
  });
  assert.equal(acknowledged.status, 200);
  assert.equal((await acknowledged.json() as { status: string }).status, "acknowledged");

  const outsider = await anonymousUser();
  assert.equal((await fetch(`${apiBase}/v1/incidents/${incidentID}`, {
    headers: { authorization: `Bearer ${outsider.idToken}` },
  })).status, 403);

  const cancellation = {
    schema_version: 1, packet_id: crypto.randomUUID(), session_id: rotated.session_id, seq: 5,
    watch_timestamp: new Date().toISOString(), kind: "event",
    payload: {
      event_id: crypto.randomUUID(), event_type: "manual_sos_cancelled",
      severity: "critical", incident_id: incidentID,
    },
  };
  const cancellationResponse = await fetch(`${apiBase}/v1/run-sessions/${rotated.session_id}/events`, {
    method: "POST", headers: { authorization: `Bearer ${rotated.ingest_token}`, "content-type": "application/json" },
    body: JSON.stringify(cancellation),
  });
  assert.equal(cancellationResponse.status, 200);
  assert.equal((await cancellationResponse.json() as { incident_status: string }).incident_status, "cancelled");
  assert.equal((await adminDB.collection("incidents").doc(incidentID).get()).get("status"), "cancelled");

  const deactivated = await fetch(`${apiBase}/v1/devices/${caregiverDeviceID}`, {
    method: "DELETE", headers: { authorization: `Bearer ${caregiver.idToken}` },
  });
  assert.equal(deactivated.status, 200);
  assert.equal((await adminDB.collection("users").doc(caregiver.localId).collection("devices").doc(caregiverDeviceID).get()).get("active"), false);

  const ended = await fetch(`${apiBase}/v1/run-sessions/${rotated.session_id}/end`, {
    method: "POST", headers: { authorization: `Bearer ${rotated.ingest_token}`, "content-type": "application/json" },
    body: JSON.stringify({ reason: "user_stopped", last_seq: 2 }),
  });
  assert.equal(ended.status, 200);
  envelope.packet_id = crypto.randomUUID();
  envelope.seq = 3;
  const afterEnd = await fetch(`${apiBase}/v1/run-sessions/${rotated.session_id}/telemetry`, {
    method: "POST",
    headers: { authorization: `Bearer ${rotated.ingest_token}`, "idempotency-key": envelope.packet_id, "content-type": "application/json" },
    body: JSON.stringify(envelope),
  });
  assert.equal(afterEnd.status, 409);

  const rules = await initializeTestEnvironment({
    projectId: projectID,
    firestore: { rules: readFileSync(resolve(process.cwd(), "../../firestore.rules"), "utf8") },
  });
  const client = rules.authenticatedContext(user.localId).firestore();
  assert.equal((await getDoc(doc(client, "runSessions", rotated.session_id))).exists(), true);
  await assertFails(setDoc(doc(client, "runSessions", rotated.session_id), { status: "forged" }));
  await rules.cleanup();
});

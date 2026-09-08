import { getMessaging } from "firebase-admin/messaging";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { DeviceRepository } from "./devices";

const db = getFirestore();
const leaseMillis = 60_000;
const devices = new DeviceRepository();

export type FanoutPhase = "alert" | "cancelled";
export type SafePushPayload = {
  incidentID: string;
  sessionID: string;
  phase: FanoutPhase;
  title: string;
  body: string;
};

export interface PushSending {
  send(token: string, deviceID: string, payload: SafePushPayload): Promise<string>;
}

class FirebasePushSender implements PushSending {
  async send(token: string, _deviceID: string, payload: SafePushPayload): Promise<string> {
    return getMessaging().send({
      token,
      notification: { title: payload.title, body: payload.body },
      data: {
        type: "incident",
        incident_id: payload.incidentID,
        session_id: payload.sessionID,
        incident_status: payload.phase === "cancelled" ? "cancelled" : "alerted",
      },
      apns: {
        headers: { "apns-priority": "10", "apns-collapse-id": payload.incidentID },
        payload: { aps: { sound: payload.phase === "alert" ? "default" : undefined } },
      },
    });
  }
}

class EmulatorPushSender implements PushSending {
  async send(_token: string, deviceID: string, payload: SafePushPayload): Promise<string> {
    const messageID = `fake-${crypto.randomUUID()}`;
    await db.collection("debugPushOutbox").add({
      device_id: deviceID,
      incident_id: payload.incidentID,
      session_id: payload.sessionID,
      phase: payload.phase,
      title: payload.title,
      body: payload.body,
      fcm_message_id: messageID,
      created_at: FieldValue.serverTimestamp(),
    });
    return messageID;
  }
}

function senderForEnvironment(): PushSending {
  return process.env.FIRESTORE_EMULATOR_HOST ? new EmulatorPushSender() : new FirebasePushSender();
}

function permanentTokenFailure(code: string): boolean {
  return code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token";
}

export async function processFanoutMarker(markerID: string, sender: PushSending = senderForEnvironment()): Promise<void> {
  const markerRef = db.collection("incidentFanoutMarkers").doc(markerID);
  const claimID = crypto.randomUUID();
  const claimed = await db.runTransaction(async transaction => {
    const marker = await transaction.get(markerRef);
    if (!marker.exists || ["complete", "no_targets", "superseded"].includes(String(marker.get("status")))) return false;
    const lease = marker.get("leased_until") as Timestamp | undefined;
    if (marker.get("status") === "processing" && lease?.toMillis() && lease.toMillis() > Date.now()) return false;
    transaction.update(markerRef, {
      status: "processing", claim_id: claimID,
      leased_until: Timestamp.fromMillis(Date.now() + leaseMillis),
      started_at: FieldValue.serverTimestamp(),
    });
    return true;
  });
  if (!claimed) return;

  const marker = await markerRef.get();
  if (!marker.exists || marker.get("claim_id") !== claimID) return;
  const incidentID = String(marker.get("incident_id"));
  const phase = marker.get("phase") as FanoutPhase;
  const familyID = String(marker.get("family_id"));
  const incident = await db.collection("incidents").doc(incidentID).get();
  if (!incident.exists) throw new Error("incident_missing");

  if (phase === "alert" && incident.get("status") === "cancelled") {
    await markerRef.update({ status: "superseded", completed_at: FieldValue.serverTimestamp() });
    return;
  }

  const targets = await devices.activeCaregiverTargets(familyID);

  if (targets.length === 0) {
    await markerRef.update({ status: "no_targets", completed_at: FieldValue.serverTimestamp() });
    return;
  }

  const payload: SafePushPayload = {
    incidentID,
    sessionID: String(incident.get("session_id")),
    phase,
    title: phase === "alert" ? "Safe Run: cần kiểm tra" : "Safe Run: cảnh báo đã được hủy",
    body: phase === "alert"
      ? "Safe Run: cần kiểm tra. Mở ứng dụng để xem chi tiết."
      : "Người chạy đã hủy cảnh báo. Mở ứng dụng để xem trạng thái.",
  };
  let transientFailure = false;
  for (const target of targets) {
    const attemptID = `${phase}_${target.uid}_${target.deviceID}`;
    const attemptRef = db.collection("incidentNotifications").doc(incidentID).collection("attempts").doc(attemptID);
    const attempt = await attemptRef.get();
    if (attempt.exists && ["sent", "permanent_failure"].includes(String(attempt.get("status")))) continue;
    try {
      await attemptRef.set({
        device_id: target.deviceID, caregiver_uid: target.uid, phase, status: "sending",
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });
      const messageID = await sender.send(target.token, target.deviceID, payload);
      await attemptRef.set({
        status: "sent", fcm_message_id: messageID, sent_at: FieldValue.serverTimestamp(),
      }, { merge: true });
    } catch (error) {
      const code = typeof error === "object" && error && "code" in error ? String(error.code) : "messaging/unknown";
      if (permanentTokenFailure(code)) {
        await Promise.all([
          devices.invalidate(target, code),
          attemptRef.set({ status: "permanent_failure", error_code: code, updated_at: FieldValue.serverTimestamp() }, { merge: true }),
        ]);
      } else {
        transientFailure = true;
        await attemptRef.set({ status: "retryable_failure", error_code: code, updated_at: FieldValue.serverTimestamp() }, { merge: true });
      }
    }
  }

  if (transientFailure) {
    await markerRef.update({ status: "retryable", leased_until: FieldValue.delete(), updated_at: FieldValue.serverTimestamp() });
    throw new Error("push_retryable_failure");
  }
  await markerRef.update({ status: "complete", completed_at: FieldValue.serverTimestamp() });
}

export const fanoutIncident = onDocumentCreated({
  document: "incidentFanoutMarkers/{markerID}", region: "asia-southeast1", retry: true,
}, async event => {
  if (event.params.markerID) await processFanoutMarker(event.params.markerID);
});

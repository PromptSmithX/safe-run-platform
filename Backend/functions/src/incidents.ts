import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import { APIError } from "./errors";
import { requireActiveFamilyMember } from "./membership";

const db = getFirestore();

export class IncidentService {
  async detail(uid: string, incidentID: string): Promise<Record<string, unknown>> {
    const incident = await db.collection("incidents").doc(incidentID).get();
    if (!incident.exists) throw new APIError(404, "INCIDENT_NOT_FOUND", "Incident not found");
    await requireActiveFamilyMember(uid, String(incident.get("family_id")));
    const runner = await db.collection("users").doc(String(incident.get("runner_uid"))).get();
    const timestamp = (value: unknown): string | null => value instanceof Timestamp ? value.toDate().toISOString() : null;
    return {
      incident_id: incidentID, session_id: incident.get("session_id"), type: incident.get("type"),
      severity: incident.get("severity"), status: incident.get("status"),
      created_at: timestamp(incident.get("created_at")), runner_event_at: incident.get("runner_event_at") ?? null,
      context: incident.get("context") ?? null, acknowledged_by: incident.get("acknowledged_by") ?? null,
      acknowledged_at: timestamp(incident.get("acknowledged_at")),
      runner_display_name: runner.get("display_name") ?? null, runner_phone_e164: runner.get("phone_e164") ?? null,
    };
  }

  async acknowledge(uid: string, incidentID: string): Promise<Record<string, unknown>> {
    const ref = db.collection("incidents").doc(incidentID);
    const existing = await ref.get();
    if (!existing.exists) throw new APIError(404, "INCIDENT_NOT_FOUND", "Incident not found");
    const member = await requireActiveFamilyMember(uid, String(existing.get("family_id")));
    if (member.role !== "caregiver") throw new APIError(403, "FORBIDDEN", "Caregiver membership required");
    await db.runTransaction(async transaction => {
      const incident = await transaction.get(ref);
      if (incident.get("status") === "alerted") {
        transaction.update(ref, {
          status: "acknowledged", acknowledged_by: uid, acknowledged_at: FieldValue.serverTimestamp(),
        });
      }
    });
    const updated = await ref.get();
    const acknowledgedAt = updated.get("acknowledged_at") as Timestamp | undefined;
    return {
      incident_id: incidentID, status: updated.get("status"),
      acknowledged_by: updated.get("acknowledged_by") ?? null,
      acknowledged_at: acknowledgedAt?.toDate().toISOString() ?? null,
    };
  }
}

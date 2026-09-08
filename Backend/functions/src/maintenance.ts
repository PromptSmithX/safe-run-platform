import { FieldValue, Timestamp, getFirestore, type Firestore } from "firebase-admin/firestore";
import { randomUUID } from "node:crypto";
import { retention } from "./privacy";

export class StaleSessionMonitor {
  constructor(private readonly db: Firestore = getFirestore(), private readonly staleSeconds = 180) {}

  async run(now: Date): Promise<{ stale: number; abandoned: number }> {
    const cutoff = Timestamp.fromMillis(now.getTime() - this.staleSeconds * 1000);
    const snapshots = await this.db.collection("runSessions").where("status", "==", "active")
      .where("connection_state", "in", ["healthy", "stale"])
      .where("last_seen_at", "<=", cutoff).get();
    let stale = 0; let abandoned = 0;
    for (const candidate of snapshots.docs) {
      const result = await this.db.runTransaction(async transaction => {
        const session = await transaction.get(candidate.ref);
        if (!session.exists || session.get("status") !== "active") return "none";
        const lastSeen = session.get("last_seen_at") as Timestamp | undefined;
        if (!lastSeen || lastSeen.toMillis() > cutoff.toMillis()) return "none";
        const staleSince = session.get("connection_stale_since") as Timestamp | undefined;
        if (staleSince && now.getTime() - staleSince.toMillis() >= 24 * 60 * 60 * 1000) {
          transaction.update(candidate.ref, {
            status: "abandoned", abandoned_at: Timestamp.fromDate(now), ingest_token_hash: FieldValue.delete(),
            ingest_token_expires_at: FieldValue.delete(), expire_at: Timestamp.fromMillis(now.getTime() + retention.incidentMillis),
          });
          return "abandoned";
        }
        if (session.get("connection_state") === "stale") return "none";
        const incidentID = randomUUID();
        const eventID = randomUUID();
        const incidentRef = this.db.collection("incidents").doc(incidentID);
        transaction.update(candidate.ref, {
          connection_state: "stale", connection_incident_id: incidentID, connection_stale_since: Timestamp.fromDate(now),
        });
        transaction.create(candidate.ref.collection("events").doc(eventID), {
          type: "connection_degraded", severity: "warning", backend_at: Timestamp.fromDate(now),
          expire_at: Timestamp.fromMillis(now.getTime() + retention.incidentMillis),
        });
        transaction.create(incidentRef, {
          session_id: candidate.id, family_id: session.get("family_id"), runner_uid: session.get("runner_uid"),
          type: "connection_degraded", severity: "warning", status: "alerted", created_at: Timestamp.fromDate(now),
          context: null, acknowledged_by: null, acknowledged_at: null,
          expire_at: Timestamp.fromMillis(now.getTime() + retention.incidentMillis),
        });
        transaction.create(this.db.collection("incidentFanoutMarkers").doc(`${incidentID}__alert`), {
          incident_id: incidentID, family_id: session.get("family_id"), phase: "alert", status: "pending",
          created_at: Timestamp.fromDate(now), expire_at: Timestamp.fromMillis(now.getTime() + retention.operationalMillis),
        });
        return "stale";
      });
      if (result === "stale") stale += 1;
      if (result === "abandoned") abandoned += 1;
    }
    return { stale, abandoned };
  }
}

export class RetentionSweeper {
  constructor(private readonly db: Firestore = getFirestore()) {}

  async run(now: Date): Promise<number> {
    const cutoff = Timestamp.fromMillis(now.getTime() - retention.telemetryMillis);
    const sessions = await this.db.collection("runSessions").where("status", "in", ["ended", "abandoned"])
      .where("last_seen_at", "<=", cutoff).get();
    let updated = 0;
    for (const session of sessions.docs) {
      await session.ref.update({
        latest_hr: FieldValue.delete(), latest_lat: FieldValue.delete(), latest_lon: FieldValue.delete(),
        latest_speed: FieldValue.delete(), ingest_token_hash: FieldValue.delete(), ingest_token_expires_at: FieldValue.delete(),
        privacy_swept_at: Timestamp.fromDate(now),
      });
      updated += 1;
    }
    return updated;
  }
}

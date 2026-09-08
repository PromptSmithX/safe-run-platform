import { FieldValue, Timestamp, getFirestore, type Firestore } from "firebase-admin/firestore";
import { randomUUID } from "node:crypto";
import { retention } from "./privacy";

export type StaleTransition = "none" | "stale" | "abandoned";
export interface MaintenanceRepository {
  staleCandidateIDs(now: Date, staleSeconds: number): Promise<string[]>;
  transitionCandidate(sessionID: string, now: Date, staleSeconds: number): Promise<StaleTransition>;
  sweep(now: Date): Promise<number>;
}

export class FirestoreMaintenanceRepository implements MaintenanceRepository {
  constructor(private readonly db: Firestore = getFirestore()) {}

  async staleCandidateIDs(now: Date, staleSeconds: number): Promise<string[]> {
    const cutoff = Timestamp.fromMillis(now.getTime() - staleSeconds * 1000);
    const result = await this.db.collection("runSessions").where("status", "==", "active")
      .where("connection_state", "in", ["healthy", "stale"]).where("last_seen_at", "<=", cutoff).get();
    return result.docs.map(value => value.id);
  }

  async transitionCandidate(sessionID: string, now: Date, staleSeconds: number): Promise<StaleTransition> {
    const sessionRef = this.db.collection("runSessions").doc(sessionID);
    return this.db.runTransaction(async transaction => {
      const session = await transaction.get(sessionRef);
      const cutoff = now.getTime() - staleSeconds * 1000;
      const lastSeen = session.get("last_seen_at") as Timestamp | undefined;
      if (!session.exists || session.get("status") !== "active" || !lastSeen || lastSeen.toMillis() > cutoff) return "none";
      const staleSince = session.get("connection_stale_since") as Timestamp | undefined;
      if (staleSince && now.getTime() - staleSince.toMillis() >= 24 * 60 * 60 * 1000) {
        const mappingID = Buffer.from(`${session.get("runner_uid")}:${session.get("client_session_id")}`).toString("base64url");
        transaction.update(sessionRef, { status: "abandoned", abandoned_at: Timestamp.fromDate(now), ingest_token_hash: FieldValue.delete(), ingest_token_expires_at: FieldValue.delete() });
        transaction.set(this.db.collection("clientRunSessions").doc(mappingID), { expire_at: Timestamp.fromMillis(now.getTime() + retention.operationalMillis) }, { merge: true });
        return "abandoned";
      }
      if (session.get("connection_state") === "stale") return "none";
      const incidentID = randomUUID(); const eventID = randomUUID();
      transaction.update(sessionRef, { connection_state: "stale", connection_incident_id: incidentID, connection_stale_since: Timestamp.fromDate(now) });
      transaction.create(sessionRef.collection("events").doc(eventID), { type: "connection_degraded", severity: "warning", backend_at: Timestamp.fromDate(now), expire_at: Timestamp.fromMillis(now.getTime() + retention.incidentMillis) });
      transaction.create(this.db.collection("incidents").doc(incidentID), {
        session_id: sessionID, family_id: session.get("family_id"), runner_uid: session.get("runner_uid"), type: "connection_degraded",
        severity: "warning", status: "alerted", created_at: Timestamp.fromDate(now), context: null,
        acknowledged_by: null, acknowledged_at: null, expire_at: Timestamp.fromMillis(now.getTime() + retention.incidentMillis),
      });
      transaction.create(this.db.collection("incidentFanoutMarkers").doc(`${incidentID}__alert`), {
        incident_id: incidentID, family_id: session.get("family_id"), phase: "alert", status: "pending",
        created_at: Timestamp.fromDate(now), expire_at: Timestamp.fromMillis(now.getTime() + retention.operationalMillis),
      });
      return "stale";
    });
  }

  async sweep(now: Date): Promise<number> {
    const cutoff = Timestamp.fromMillis(now.getTime() - retention.telemetryMillis);
    const sessions = await this.db.collection("runSessions").where("status", "in", ["ended", "abandoned"]).where("last_seen_at", "<=", cutoff).get();
    let count = 0;
    for (const session of sessions.docs) {
      await session.ref.update({ latest_hr: FieldValue.delete(), latest_lat: FieldValue.delete(), latest_lon: FieldValue.delete(), latest_speed: FieldValue.delete(), ingest_token_hash: FieldValue.delete(), ingest_token_expires_at: FieldValue.delete(), privacy_swept_at: Timestamp.fromDate(now) });
      count += 1;
    }
    const mappings = await this.db.collection("clientRunSessions").where("expire_at", "<=", Timestamp.fromDate(now)).get();
    for (const mapping of mappings.docs) { await mapping.ref.delete(); count += 1; }
    const incidentCutoff = Timestamp.fromMillis(now.getTime() - retention.incidentMillis);
    const resolved = await this.db.collection("incidents").where("status", "in", ["resolved", "cancelled"]).where("created_at", "<=", incidentCutoff).get();
    for (const incident of resolved.docs) { await incident.ref.update({ context: FieldValue.delete(), context_scrubbed_at: Timestamp.fromDate(now) }); count += 1; }
    return count;
  }
}

export class StaleSessionMonitor {
  constructor(private readonly repository: MaintenanceRepository = new FirestoreMaintenanceRepository(), private readonly staleSeconds = 180) {}
  async run(now: Date): Promise<{ stale: number; abandoned: number }> {
    let stale = 0; let abandoned = 0;
    for (const id of await this.repository.staleCandidateIDs(now, this.staleSeconds)) {
      const result = await this.repository.transitionCandidate(id, now, this.staleSeconds);
      if (result === "stale") stale += 1; else if (result === "abandoned") abandoned += 1;
    }
    return { stale, abandoned };
  }
}

export class RetentionSweeper {
  constructor(private readonly repository: MaintenanceRepository = new FirestoreMaintenanceRepository()) {}
  run(now: Date): Promise<number> { return this.repository.sweep(now); }
}

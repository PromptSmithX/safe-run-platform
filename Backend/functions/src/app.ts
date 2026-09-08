import Ajv2020 from "ajv/dist/2020";
import addFormats from "ajv-formats";
import express, { type NextFunction, type Request, type Response } from "express";
import { randomUUID } from "node:crypto";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import telemetrySchema from "./generated-schemas/telemetry-envelope.schema.json";
import eventSchema from "./generated-schemas/event-envelope.schema.json";
import { APIError, sendError } from "./errors";
import { issueIngestToken, tokenHashesMatch } from "./token";
import { defaultFamilyFor, requireActiveFamilyMember } from "./membership";
import { DeviceRepository } from "./devices";
import { IncidentService } from "./incidents";
import { retention, safeLog } from "./privacy";

const db = getFirestore();
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validateTelemetry = ajv.compile(telemetrySchema);
const validateEvent = ajv.compile(eventSchema);
const tokenTTLMillis = 4 * 60 * 60 * 1000;
const devices = new DeviceRepository();
const incidents = new IncidentService();

type AuthedRequest = Request & { runnerUID?: string; requestID?: string };
type Envelope = {
  schema_version: number; packet_id: string; session_id: string; seq: number;
  watch_timestamp: string; kind: "telemetry" | "event"; payload: Record<string, unknown>;
};

export const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "256kb" }));
app.use((request: AuthedRequest, response, next) => {
  request.requestID = randomUUID();
  response.setHeader("x-request-id", request.requestID);
  next();
});

function bearer(request: Request): string {
  const value = request.header("authorization") ?? "";
  if (!value.startsWith("Bearer ") || value.length <= 7) {
    throw new APIError(401, "UNAUTHORIZED", "Bearer token required");
  }
  return value.slice(7);
}

async function requireUser(request: AuthedRequest, _response: Response, next: NextFunction) {
  try {
    request.runnerUID = (await getAuth().verifyIdToken(bearer(request))).uid;
    next();
  } catch (error) {
    next(error instanceof APIError ? error : new APIError(401, "UNAUTHORIZED", "Invalid Firebase ID token"));
  }
}

function requireUUID(value: unknown, field: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new APIError(400, "INVALID_SCHEMA", `${field} must be a UUID`);
  }
  return value;
}

app.post("/v1/run-sessions", requireUser, async (request: AuthedRequest, response, next) => {
  try {
    const uid = request.runnerUID!;
    const clientSessionID = requireUUID(request.body?.client_session_id, "client_session_id");
    const mappingID = Buffer.from(`${uid}:${clientSessionID}`).toString("base64url");
    const mappingRef = db.collection("clientRunSessions").doc(mappingID);
    const token = issueIngestToken();
    const expiresAt = Timestamp.fromMillis(Date.now() + tokenTTLMillis);
    const sessionID = await db.runTransaction(async transaction => {
      const mapping = await transaction.get(mappingRef);
      const existingID = mapping.exists ? mapping.get("session_id") as string : undefined;
      const chosenID = existingID ?? randomUUID();
      const sessionRef = db.collection("runSessions").doc(chosenID);
      if (!existingID) {
        transaction.set(db.collection("users").doc(uid), {
          display_name: "Safe Run runner", default_family_id: uid, created_at: FieldValue.serverTimestamp(),
        }, { merge: true });
        transaction.set(db.collection("families").doc(uid), {
          name: "Personal Safe Run family", created_at: FieldValue.serverTimestamp(),
        }, { merge: true });
        transaction.set(db.collection("families").doc(uid).collection("members").doc(uid), {
          role: "runner", status: "active", created_at: FieldValue.serverTimestamp(),
        }, { merge: true });
        transaction.create(sessionRef, {
          runner_uid: uid, family_id: uid, client_session_id: clientSessionID, status: "active",
          started_at: FieldValue.serverTimestamp(), last_seen_at: FieldValue.serverTimestamp(), last_seq: 0,
          active_incident_id: null, connection_state: "healthy", connection_incident_id: null,
        });
        transaction.create(mappingRef, { runner_uid: uid, client_session_id: clientSessionID, session_id: chosenID });
      } else {
        const session = await transaction.get(sessionRef);
        if (!session.exists || session.get("runner_uid") !== uid || session.get("status") !== "active") {
          throw new APIError(409, "SESSION_ENDED", "Session is no longer active");
        }
        const defaults: Record<string, unknown> = {};
        if (session.get("connection_state") == null) defaults.connection_state = "healthy";
        if (session.get("connection_incident_id") === undefined) defaults.connection_incident_id = null;
        if (Object.keys(defaults).length) transaction.update(sessionRef, defaults);
      }
      transaction.update(sessionRef, { ingest_token_hash: token.hash, ingest_token_expires_at: expiresAt });
      return chosenID;
    });
    const now = new Date();
    response.status(201).json({
      session_id: sessionID, ingest_token: token.raw,
      expires_at: expiresAt.toDate().toISOString(), server_time: now.toISOString(),
    });
  } catch (error) { next(error); }
});

async function authenticatedSession(request: Request): Promise<{ ref: FirebaseFirestore.DocumentReference; data: FirebaseFirestore.DocumentData }> {
  const sessionID = requireUUID(request.params.session_id, "session_id");
  const ref = db.collection("runSessions").doc(sessionID);
  const snapshot = await ref.get();
  if (!snapshot.exists) throw new APIError(404, "SESSION_NOT_FOUND", "Session not found");
  const data = snapshot.data()!;
  if (data.status === "abandoned") throw new APIError(409, "SESSION_INACTIVE", "Session is inactive");
  const ended = data.status === "ended";
  const expiry = (ended ? data.revoked_ingest_token_expires_at : data.ingest_token_expires_at) as Timestamp | undefined;
  if (!expiry || expiry.toMillis() <= Date.now()) throw new APIError(401, "SESSION_TOKEN_EXPIRED", "Ingest token expired");
  const expectedHash = ended ? data.revoked_ingest_token_hash : data.ingest_token_hash;
  if (typeof expectedHash !== "string" || !tokenHashesMatch(expectedHash, bearer(request))) {
    throw new APIError(403, "FORBIDDEN", "Token is not valid for this session");
  }
  return { ref, data };
}

app.post("/v1/run-sessions/reconcile", requireUser, async (request: AuthedRequest, response, next) => {
  try {
    const ids = request.body?.client_session_ids;
    if (!Array.isArray(ids) || ids.length > 50 || new Set(ids).size !== ids.length || ids.some(value => typeof value !== "string")) {
      throw new APIError(400, "INVALID_SCHEMA", "client_session_ids must contain at most 50 IDs");
    }
    const uid = request.runnerUID!;
    const sessions = [];
    for (const clientID of ids) {
      requireUUID(clientID, "client_session_id");
      const mappingID = Buffer.from(`${uid}:${clientID}`).toString("base64url");
      const mapping = await db.collection("clientRunSessions").doc(mappingID).get();
      if (!mapping.exists || mapping.get("runner_uid") !== uid) continue;
      const serverID = String(mapping.get("session_id"));
      const session = await db.collection("runSessions").doc(serverID).get();
      if (!session.exists || session.get("runner_uid") !== uid) continue;
      const incidentQuery = await db.collection("incidents").where("session_id", "==", serverID).limit(20).get();
      sessions.push({ client_session_id: clientID, server_session_id: serverID, status: session.get("status"), last_seq: Number(session.get("last_seq") ?? 0), incident_ids: incidentQuery.docs.map(value => value.id) });
    }
    response.json({ sessions });
  } catch (error) { next(error); }
});

async function ingest(request: Request, response: Response, kind: "telemetry" | "event") {
  const validate = kind === "telemetry" ? validateTelemetry : validateEvent;
  if (!validate(request.body)) throw new APIError(400, "INVALID_SCHEMA", "Envelope does not match schema");
  const envelope = request.body as Envelope;
  const { ref: sessionRef } = await authenticatedSession(request);
  if (envelope.session_id !== sessionRef.id || envelope.kind !== kind) {
    throw new APIError(400, "INVALID_SCHEMA", "Envelope session or kind does not match endpoint");
  }
  if (kind === "telemetry" && request.header("idempotency-key") !== envelope.packet_id) {
    throw new APIError(400, "INVALID_SCHEMA", "Idempotency-Key must match packet_id");
  }

  const packetRef = sessionRef.collection("packets").doc(envelope.packet_id);
  const eventType = kind === "event" ? String(envelope.payload.event_type) : undefined;
  const checkInEvent = eventType !== undefined && ["check_in_started", "check_in_ok", "check_in_help_requested", "check_in_timeout"].includes(eventType);
  const requestedIncidentID = kind === "event" && (envelope.payload.severity === "critical" || checkInEvent)
    ? requireUUID(envelope.payload.incident_id, "incident_id") : undefined;
  const result = await db.runTransaction(async transaction => {
    const [session, packet] = await Promise.all([transaction.get(sessionRef), transaction.get(packetRef)]);
    if (packet.exists) {
      const duplicateIncident = requestedIncidentID
        ? await transaction.get(db.collection("incidents").doc(requestedIncidentID)) : undefined;
      return {
        duplicate: true, lastSeq: session.get("last_seq") as number,
        incidentID: duplicateIncident?.exists ? requestedIncidentID : undefined,
        incidentStatus: duplicateIncident?.exists ? String(duplicateIncident.get("status")) : undefined,
      };
    }
    if (session.get("status") !== "active") throw new APIError(409, "SESSION_ENDED", "Session has ended");

    const connectionIncidentID = session.get("connection_state") === "stale" ? session.get("connection_incident_id") as string | undefined : undefined;
    const connectionIncidentRef = connectionIncidentID ? db.collection("incidents").doc(connectionIncidentID) : undefined;
    const connectionMarkerRef = connectionIncidentID ? db.collection("incidentFanoutMarkers").doc(`${connectionIncidentID}__alert`) : undefined;
    const connectionIncident = connectionIncidentRef ? await transaction.get(connectionIncidentRef) : undefined;
    const connectionMarker = connectionMarkerRef ? await transaction.get(connectionMarkerRef) : undefined;

    const minute = Math.floor(Date.now() / 60_000);
    const rateRef = sessionRef.collection("rateLimits").doc(`${kind}-${minute}`);
    const rate = await transaction.get(rateRef);
    const count = rate.exists ? Number(rate.get("count")) : 0;
    const limit = kind === "telemetry" ? 30 : 60;
    if (count >= limit) throw new APIError(429, "RATE_LIMITED", "Rate limit exceeded", true);
    let eventID: string | undefined;
    let eventRef: FirebaseFirestore.DocumentReference | undefined;
    let eventExists = false;
    let incidentID: string | undefined;
    let incidentRef: FirebaseFirestore.DocumentReference | undefined;
    let incidentExists = false;
    let incident: FirebaseFirestore.DocumentSnapshot | undefined;
    let alertMarker: FirebaseFirestore.DocumentSnapshot | undefined;
    let cancellationMarker: FirebaseFirestore.DocumentSnapshot | undefined;
    let activeCheckInRef: FirebaseFirestore.DocumentReference | undefined;
    let activeCheckIn: FirebaseFirestore.DocumentSnapshot | undefined;
    let resultingIncidentStatus: string | undefined;
    const cancellation = kind === "event" && envelope.payload.event_type === "manual_sos_cancelled";
    if (kind === "event") {
      eventID = requireUUID(envelope.payload.event_id, "event_id");
      eventRef = sessionRef.collection("events").doc(eventID);
      eventExists = (await transaction.get(eventRef)).exists;
      if (envelope.payload.severity === "critical" || checkInEvent) {
        incidentID = requestedIncidentID!;
        incidentRef = db.collection("incidents").doc(incidentID);
        incident = await transaction.get(incidentRef);
        incidentExists = incident.exists;
        resultingIncidentStatus = incidentExists ? String(incident.get("status")) : undefined;
        alertMarker = await transaction.get(db.collection("incidentFanoutMarkers").doc(`${incidentID}__alert`));
        if (cancellation) {
          cancellationMarker = await transaction.get(db.collection("incidentFanoutMarkers").doc(`${incidentID}__cancelled`));
          if (!incidentExists || incident.get("session_id") !== sessionRef.id || incident.get("type") !== "manual_sos") {
            throw new APIError(409, "INCIDENT_NOT_CANCELLABLE", "Manual SOS incident does not match this session");
          }
        }
        if (eventType === "manual_sos" && !incidentExists) {
          const activeID = session.get("active_incident_id") as string | undefined;
          if (activeID && activeID !== incidentID) {
            activeCheckInRef = db.collection("incidents").doc(activeID);
            activeCheckIn = await transaction.get(activeCheckInRef);
          }
        }
      }
    }

    transaction.set(rateRef, { count: count + 1, minute, expires_at: Timestamp.fromMillis((minute + 2) * 60_000) });
    transaction.create(packetRef, { kind, seq: envelope.seq, received_at: FieldValue.serverTimestamp(), expire_at: Timestamp.fromMillis(Date.now() + retention.operationalMillis) });

    const previousSequence = Number(session.get("last_seq") ?? 0);
    const newest = envelope.seq >= previousSequence;
    const update: Record<string, unknown> = {
      last_seen_at: FieldValue.serverTimestamp(), last_seq: Math.max(previousSequence, envelope.seq),
    };
    if (session.get("connection_state") === "stale") {
      update.connection_state = "healthy"; update.connection_incident_id = null; update.connection_stale_since = FieldValue.delete();
      if (connectionIncident?.exists && connectionIncident.get("status") !== "resolved") {
        transaction.update(connectionIncident.ref, { status: "resolved", resolution_reason: "connection_recovered", resolved_at: FieldValue.serverTimestamp() });
      }
      if (connectionMarker?.exists && connectionMarker.get("status") === "pending") {
        transaction.update(connectionMarker.ref, { status: "superseded", completed_at: FieldValue.serverTimestamp() });
      }
    }
    if (newest) {
      update.last_watch_timestamp = envelope.watch_timestamp;
      if (kind === "telemetry") {
        const payload = envelope.payload;
        update.latest_hr = payload.heart_rate_bpm ?? null;
        const location = payload.location as Record<string, unknown> | undefined;
        update.latest_lat = location?.lat ?? null;
        update.latest_lon = location?.lon ?? null;
        update.latest_speed = payload.speed_mps ?? null;
      }
    }
    transaction.update(sessionRef, update);

    if (kind === "telemetry" && newest) {
      const bucket = Math.floor(Date.now() / 30_000);
      transaction.set(sessionRef.collection("samples").doc(String(bucket)), {
        at: FieldValue.serverTimestamp(), seq: envelope.seq,
        hr: envelope.payload.heart_rate_bpm ?? null,
        lat: (envelope.payload.location as Record<string, unknown> | undefined)?.lat ?? null,
        lon: (envelope.payload.location as Record<string, unknown> | undefined)?.lon ?? null,
        speed: envelope.payload.speed_mps ?? null,
        expire_at: Timestamp.fromMillis(Date.now() + retention.telemetryMillis),
      }, { merge: false });
    } else {
      if (!eventExists) transaction.create(eventRef!, {
        type: envelope.payload.event_type, severity: envelope.payload.severity,
        watch_at: envelope.watch_timestamp, received_at: FieldValue.serverTimestamp(), payload: envelope.payload,
        expire_at: Timestamp.fromMillis(Date.now() + retention.incidentMillis),
      });
      if (checkInEvent) {
        const escalation = eventType === "check_in_help_requested" || eventType === "check_in_timeout";
        if (!incidentExists) {
          transaction.create(incidentRef!, {
            session_id: sessionRef.id, family_id: session.get("family_id"), runner_uid: session.get("runner_uid"),
            type: eventType, severity: escalation ? "critical" : envelope.payload.severity,
            status: escalation ? "alerted" : eventType === "check_in_started" ? "check_in" : "resolved",
            created_at: FieldValue.serverTimestamp(), runner_event_at: envelope.watch_timestamp,
            context: envelope.payload.context ?? null, acknowledged_by: null, acknowledged_at: null,
            resolution_reason: eventType === "check_in_ok" ? "runner_ok" : null,
          });
          if (escalation) transaction.set(db.collection("incidentFanoutMarkers").doc(`${incidentID}__alert`), {
            incident_id: incidentID, family_id: session.get("family_id"), phase: "alert",
            status: "pending", created_at: FieldValue.serverTimestamp(),
            expire_at: Timestamp.fromMillis(Date.now() + retention.operationalMillis),
          });
          transaction.update(sessionRef, { active_incident_id: escalation || eventType === "check_in_started" ? incidentID : null });
          resultingIncidentStatus = escalation ? "alerted" : eventType === "check_in_started" ? "check_in" : "resolved";
        } else if (incident!.get("session_id") !== sessionRef.id) {
          throw new APIError(409, "INCIDENT_SESSION_MISMATCH", "Check-in incident does not match this session");
        } else if (escalation && incident!.get("status") === "check_in") {
          transaction.update(incidentRef!, { status: "alerted", type: eventType, severity: "critical", context: envelope.payload.context ?? incident!.get("context") });
          if (!alertMarker?.exists) transaction.create(db.collection("incidentFanoutMarkers").doc(`${incidentID}__alert`), {
            incident_id: incidentID, family_id: session.get("family_id"), phase: "alert", status: "pending", created_at: FieldValue.serverTimestamp(),
            expire_at: Timestamp.fromMillis(Date.now() + retention.operationalMillis),
          });
          transaction.update(sessionRef, { active_incident_id: incidentID });
          resultingIncidentStatus = "alerted";
        } else if (eventType === "check_in_ok" && incident!.get("status") === "check_in") {
          transaction.update(incidentRef!, { status: "resolved", resolution_reason: "runner_ok", resolved_at: FieldValue.serverTimestamp() });
          transaction.update(sessionRef, { active_incident_id: null });
          resultingIncidentStatus = "resolved";
        }
      } else if (envelope.payload.severity === "critical") {
        if (cancellation) {
          if (incident!.get("status") !== "cancelled") {
            transaction.update(incidentRef!, {
              status: "cancelled", cancelled_at: FieldValue.serverTimestamp(),
              cancelled_by: "runner", cancellation_event_id: eventID,
            });
            transaction.update(sessionRef, { active_incident_id: null });
            resultingIncidentStatus = "cancelled";
          }
          if (alertMarker?.exists && alertMarker.get("status") === "pending") {
            transaction.update(alertMarker.ref, { status: "superseded", completed_at: FieldValue.serverTimestamp() });
          } else if (!cancellationMarker?.exists) {
            transaction.create(db.collection("incidentFanoutMarkers").doc(`${incidentID}__cancelled`), {
              incident_id: incidentID, family_id: session.get("family_id"), phase: "cancelled",
              status: "pending", created_at: FieldValue.serverTimestamp(),
              expire_at: Timestamp.fromMillis(Date.now() + retention.operationalMillis),
            });
          }
        } else if (!incidentExists) {
          if (eventType === "manual_sos" && activeCheckInRef && activeCheckIn?.exists && activeCheckIn.get("status") === "check_in") {
            transaction.update(activeCheckInRef, {
              status: "resolved", resolution_reason: "superseded_by_manual_sos", resolved_at: FieldValue.serverTimestamp(),
            });
          }
          transaction.create(incidentRef!, {
            session_id: sessionRef.id, family_id: session.get("family_id"), runner_uid: session.get("runner_uid"),
            type: envelope.payload.event_type, severity: "critical", status: "alerted",
            created_at: FieldValue.serverTimestamp(), runner_event_at: envelope.watch_timestamp,
            context: envelope.payload.context ?? null, acknowledged_by: null, acknowledged_at: null,
          });
          transaction.set(db.collection("incidentFanoutMarkers").doc(`${incidentID}__alert`), {
            incident_id: incidentID, family_id: session.get("family_id"), phase: "alert",
            status: "pending", created_at: FieldValue.serverTimestamp(),
            expire_at: Timestamp.fromMillis(Date.now() + retention.operationalMillis),
          });
          transaction.update(sessionRef, { active_incident_id: incidentID });
          resultingIncidentStatus = "alerted";
        }
      }
    }
    return {
      duplicate: false, lastSeq: Math.max(previousSequence, envelope.seq), incidentID,
      incidentStatus: incidentID ? resultingIncidentStatus : undefined,
    };
  });
  response.status(200).json({
    accepted: true, duplicate: result.duplicate, last_seq: result.lastSeq,
    server_time: new Date().toISOString(), incident_id: result.incidentID,
    incident_status: result.incidentStatus,
  });
}

app.post("/v1/run-sessions/:session_id/telemetry", (request, response, next) => {
  ingest(request, response, "telemetry").catch(next);
});
app.post("/v1/run-sessions/:session_id/events", (request, response, next) => {
  ingest(request, response, "event").catch(next);
});

app.post("/v1/run-sessions/:session_id/end", async (request, response, next) => {
  try {
    const { ref, data: authenticatedData } = await authenticatedSession(request);
    const lastSequence = Number(request.body?.last_seq);
    if (!Number.isInteger(lastSequence) || lastSequence < 1) throw new APIError(400, "INVALID_SCHEMA", "last_seq must be positive");
    await db.runTransaction(async transaction => {
      const session = await transaction.get(ref);
      if (session.get("status") === "ended") return;
      transaction.update(ref, {
        status: "ended", ended_at: FieldValue.serverTimestamp(), last_seq: Math.max(Number(session.get("last_seq") ?? 0), lastSequence),
        revoked_ingest_token_hash: authenticatedData.ingest_token_hash,
        revoked_ingest_token_expires_at: Timestamp.fromMillis(Date.now() + 24 * 60 * 60 * 1000),
        ingest_token_hash: FieldValue.delete(), ingest_token_expires_at: FieldValue.delete(),
      });
      const mappingID = Buffer.from(`${session.get("runner_uid")}:${session.get("client_session_id")}`).toString("base64url");
      transaction.set(db.collection("clientRunSessions").doc(mappingID), { expire_at: Timestamp.fromMillis(Date.now() + retention.operationalMillis) }, { merge: true });
    });
    response.status(200).json({ accepted: true, server_time: new Date().toISOString() });
  } catch (error) { next(error); }
});

app.post("/v1/devices", requireUser, async (request: AuthedRequest, response, next) => {
  try {
    const uid = request.runnerUID!;
    const deviceID = requireUUID(request.body?.device_id, "device_id");
    if (request.body?.platform !== "ios" || !["runner", "caregiver"].includes(request.body?.role)) {
      throw new APIError(400, "INVALID_SCHEMA", "platform and role are invalid");
    }
    const token = request.body?.fcm_token;
    const appVersion = request.body?.app_version;
    if (typeof token !== "string" || token.length < 10 || token.length > 4096 || typeof appVersion !== "string" || appVersion.length > 64) {
      throw new APIError(400, "INVALID_SCHEMA", "FCM token or app version is invalid");
    }
    const familyID = await defaultFamilyFor(uid);
    const member = await requireActiveFamilyMember(uid, familyID);
    if (member.role !== request.body.role) {
      throw new APIError(403, "FORBIDDEN", "Device role must match active family membership");
    }
    await devices.register(uid, deviceID, { role: request.body.role, token, appVersion, familyID });
    response.status(200).json({ registered: true, device_id: deviceID });
  } catch (error) { next(error); }
});

app.delete("/v1/devices/:device_id", requireUser, async (request: AuthedRequest, response, next) => {
  try {
    const deviceID = requireUUID(request.params.device_id, "device_id");
    await devices.deactivate(request.runnerUID!, deviceID);
    response.status(200).json({ registered: false, device_id: deviceID });
  } catch (error) { next(error); }
});

app.get("/v1/incidents/:incident_id", requireUser, async (request: AuthedRequest, response, next) => {
  try {
    const incidentID = requireUUID(request.params.incident_id, "incident_id");
    response.status(200).json(await incidents.detail(request.runnerUID!, incidentID));
  } catch (error) { next(error); }
});

app.post("/v1/incidents/:incident_id/acknowledge", requireUser, async (request: AuthedRequest, response, next) => {
  try {
    if (request.body?.action !== "seen") throw new APIError(400, "INVALID_SCHEMA", "Only the seen action is supported");
    const incidentID = requireUUID(request.params.incident_id, "incident_id");
    response.status(200).json(await incidents.acknowledge(request.runnerUID!, incidentID));
  } catch (error) { next(error); }
});

app.use((_request, _response, next) => next(new APIError(404, "NOT_FOUND", "Endpoint not found")));
app.use((error: unknown, request: AuthedRequest, response: Response, _next: NextFunction) => {
  const normalized = error instanceof SyntaxError && "status" in error && error.status === 400
    ? new APIError(400, "INVALID_SCHEMA", "Request body is not valid JSON")
    : error;
  safeLog({ event_name: "api_request_failed", timestamp: new Date().toISOString(), request_id: request.requestID, error_code: normalized instanceof APIError ? normalized.code : "INTERNAL" });
  sendError(response, normalized, request.requestID);
});

import { initializeApp } from "firebase-admin/app";
import { onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineInt } from "firebase-functions/params";

initializeApp();

// Import after Admin initialization so module-level Firestore/Auth clients are valid.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { app } = require("./app") as typeof import("./app");

export const api = onRequest({ region: "asia-southeast1", cors: false, timeoutSeconds: 60, memory: "256MiB" }, app);
export { fanoutIncident } from "./fanout";

const staleSeconds = defineInt("STALE_SESSION_SECONDS", { default: 180 });
export const monitorStaleSessions = onSchedule({ schedule: "every 1 minutes", region: "asia-southeast1" }, async () => {
  const { StaleSessionMonitor } = await import("./maintenance");
  await new StaleSessionMonitor(undefined, staleSeconds.value()).run(new Date());
});
export const sweepExpiredSensitiveData = onSchedule({ schedule: "every day 03:00", timeZone: "Asia/Ho_Chi_Minh", region: "asia-southeast1" }, async () => {
  const { RetentionSweeper } = await import("./maintenance");
  await new RetentionSweeper().run(new Date());
});

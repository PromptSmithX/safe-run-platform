import { initializeApp } from "firebase-admin/app";
import { onRequest } from "firebase-functions/v2/https";

initializeApp();

// Import after Admin initialization so module-level Firestore/Auth clients are valid.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { app } = require("./app") as typeof import("./app");

export const api = onRequest({ region: "asia-southeast1", cors: false, timeoutSeconds: 60, memory: "256MiB" }, app);

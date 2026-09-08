import { initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

const values = Object.fromEntries(process.argv.slice(2).map(value => {
  const [key, ...rest] = value.replace(/^--/, "").split("=");
  return [key, rest.join("=")];
}));
const projectID = process.env.GCLOUD_PROJECT ?? process.env.GOOGLE_CLOUD_PROJECT ?? values.project;
if (!projectID?.startsWith("demo-") || !process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error("This seed command only runs against a demo-* Firestore Emulator project.");
}
if (!values.runner || !values.caregiver || !/^\+[1-9]\d{7,14}$/.test(values.phone ?? "")) {
  throw new Error("Use --runner=<uid> --caregiver=<uid> --phone=<E.164>.");
}

initializeApp({ projectId: projectID });
const db = getFirestore();
const batch = db.batch();
batch.set(db.collection("users").doc(values.runner), {
  display_name: "Safe Run runner", default_family_id: values.runner,
  phone_e164: values.phone, updated_at: FieldValue.serverTimestamp(),
}, { merge: true });
batch.set(db.collection("families").doc(values.runner), {
  name: "Personal Safe Run family", created_at: FieldValue.serverTimestamp(),
}, { merge: true });
batch.set(db.collection("families").doc(values.runner).collection("members").doc(values.runner), {
  role: "runner", status: "active", updated_at: FieldValue.serverTimestamp(),
}, { merge: true });
batch.set(db.collection("users").doc(values.caregiver), {
  display_name: "Safe Run caregiver", default_family_id: values.runner,
  updated_at: FieldValue.serverTimestamp(),
}, { merge: true });
batch.set(db.collection("families").doc(values.runner).collection("members").doc(values.caregiver), {
  role: "caregiver", status: "active", updated_at: FieldValue.serverTimestamp(),
}, { merge: true });
await batch.commit();
console.log(JSON.stringify({ family_id: values.runner, runner_uid: values.runner, caregiver_uid: values.caregiver }));

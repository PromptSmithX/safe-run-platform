import { FieldValue, getFirestore } from "firebase-admin/firestore";

const db = getFirestore();

export type CaregiverPushTarget = { uid: string; deviceID: string; token: string };

export class DeviceRepository {
  async register(uid: string, deviceID: string, values: {
    role: string; token: string; appVersion: string; familyID: string;
  }): Promise<void> {
    await db.collection("users").doc(uid).collection("devices").doc(deviceID).set({
      platform: "ios", role: values.role, fcm_token: values.token, active: true,
      app_version: values.appVersion, family_id: values.familyID, updated_at: FieldValue.serverTimestamp(),
      invalidated_at: FieldValue.delete(), invalidation_code: FieldValue.delete(),
    }, { merge: true });
  }

  async deactivate(uid: string, deviceID: string): Promise<void> {
    await db.collection("users").doc(uid).collection("devices").doc(deviceID).set({
      active: false, fcm_token: FieldValue.delete(), deactivated_at: FieldValue.serverTimestamp(),
    }, { merge: true });
  }

  async activeCaregiverTargets(familyID: string): Promise<CaregiverPushTarget[]> {
    const members = await db.collection("families").doc(familyID).collection("members")
      .where("role", "==", "caregiver").where("status", "==", "active").get();
    const targets: CaregiverPushTarget[] = [];
    for (const member of members.docs) {
      const devices = await db.collection("users").doc(member.id).collection("devices")
        .where("role", "==", "caregiver").where("active", "==", true).get();
      for (const device of devices.docs) {
        const token = device.get("fcm_token");
        if (typeof token === "string" && token.length > 0) {
          targets.push({ uid: member.id, deviceID: device.id, token });
        }
      }
    }
    return targets;
  }

  async invalidate(target: CaregiverPushTarget, code: string): Promise<void> {
    await db.collection("users").doc(target.uid).collection("devices").doc(target.deviceID).set({
      active: false, invalidated_at: FieldValue.serverTimestamp(), invalidation_code: code,
      fcm_token: FieldValue.delete(),
    }, { merge: true });
  }
}

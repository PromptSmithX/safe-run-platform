import { getFirestore } from "firebase-admin/firestore";
import { APIError } from "./errors";

const db = getFirestore();

export async function requireActiveFamilyMember(uid: string, familyID: string): Promise<FirebaseFirestore.DocumentData> {
  const member = await db.collection("families").doc(familyID).collection("members").doc(uid).get();
  if (!member.exists || member.get("status") !== "active") {
    throw new APIError(403, "FORBIDDEN", "Active family membership required");
  }
  return member.data()!;
}

export async function defaultFamilyFor(uid: string): Promise<string> {
  const user = await db.collection("users").doc(uid).get();
  const familyID = user.get("default_family_id");
  if (typeof familyID !== "string" || familyID.length === 0) {
    throw new APIError(403, "FAMILY_NOT_PROVISIONED", "Family membership has not been provisioned");
  }
  await requireActiveFamilyMember(uid, familyID);
  return familyID;
}

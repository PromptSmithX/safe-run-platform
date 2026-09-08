import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

export function issueIngestToken(): { raw: string; hash: string } {
  const raw = randomBytes(32).toString("base64url");
  return { raw, hash: hashIngestToken(raw) };
}

export function hashIngestToken(raw: string): string {
  return createHash("sha256").update(raw, "utf8").digest("hex");
}

export function tokenHashesMatch(expectedHex: string, raw: string): boolean {
  const actual = Buffer.from(hashIngestToken(raw), "hex");
  const expected = Buffer.from(expectedHex, "hex");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

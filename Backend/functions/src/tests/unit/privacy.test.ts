import assert from "node:assert/strict";
import test from "node:test";
import { assertSafeLogRecord } from "../../privacy";

test("structured logger accepts only allowlisted metadata", () => {
  assert.doesNotThrow(() => assertSafeLogRecord({ event_name: "upload", session_id: "id", retry_count: 2 }));
  for (const key of ["token", "heart_rate", "latitude", "phone", "fcm_token", "payload"]) {
    assert.throws(() => assertSafeLogRecord({ event_name: "unsafe", [key]: "secret" }));
  }
});

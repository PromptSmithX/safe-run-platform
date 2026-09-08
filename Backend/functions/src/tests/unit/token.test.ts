import assert from "node:assert/strict";
import test from "node:test";
import { issueIngestToken, tokenHashesMatch } from "../../token";

test("ingest tokens are random and compare against only their hash", () => {
  const first = issueIngestToken();
  const second = issueIngestToken();
  assert.notEqual(first.raw, second.raw);
  assert.equal(tokenHashesMatch(first.hash, first.raw), true);
  assert.equal(tokenHashesMatch(first.hash, second.raw), false);
  assert.equal(first.hash.includes(first.raw), false);
});

import assert from "node:assert/strict";
import test from "node:test";
import { RetentionSweeper, StaleSessionMonitor, type MaintenanceRepository, type StaleTransition } from "../../maintenance";

class FakeRepository implements MaintenanceRepository {
  candidates: string[] = [];
  transitions = new Map<string, StaleTransition>();
  transitionCalls: string[] = [];
  swept = 0;
  async staleCandidateIDs(): Promise<string[]> { return this.candidates; }
  async transitionCandidate(id: string): Promise<StaleTransition> { this.transitionCalls.push(id); return this.transitions.get(id) ?? "none"; }
  async sweep(): Promise<number> { return this.swept; }
}

test("stale monitor counts only repository edge transitions", async () => {
  const repository = new FakeRepository();
  repository.candidates = ["new-stale", "already-stale", "abandoned"];
  repository.transitions.set("new-stale", "stale"); repository.transitions.set("abandoned", "abandoned");
  const result = await new StaleSessionMonitor(repository, 180).run(new Date(1_000));
  assert.deepEqual(result, { stale: 1, abandoned: 1 });
  assert.deepEqual(repository.transitionCalls, repository.candidates);
});

test("retention sweeper delegates one bounded run", async () => {
  const repository = new FakeRepository(); repository.swept = 4;
  assert.equal(await new RetentionSweeper(repository).run(new Date(1_000)), 4);
});

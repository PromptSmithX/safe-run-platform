import { cpSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, "../../../safe_run_mvp_docs/schemas");
const destination = resolve(here, "../src/generated-schemas");
mkdirSync(destination, { recursive: true });
for (const name of ["telemetry-envelope.schema.json", "event-envelope.schema.json"]) {
  cpSync(resolve(source, name), resolve(destination, name));
}

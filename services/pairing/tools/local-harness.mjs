// Local system-boundary integration harness. No external service or credentials.
import { Miniflare } from "miniflare";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
const setupToken = "local-test-setup-only";
const mf = new Miniflare({
  modules: true,
  scriptPath: "src/worker.mjs",
  compatibilityDate: "2026-07-30",
  d1Databases: ["DB"],
  bindings: {
    ENROLLMENT_HASH: createHash("sha256").update(setupToken).digest("hex"),
  },
  port: 0,
  host: "127.0.0.1",
});
await (
  await mf.getD1Database("DB")
).exec(await readFile("migrations/0001_pairing.sql", "utf8"));
console.log((await mf.ready).origin);
process.on("SIGTERM", async () => {
  await mf.dispose();
  process.exit(0);
});

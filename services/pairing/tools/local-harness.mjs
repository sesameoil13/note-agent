// Local system-boundary integration harness. No external service or credentials.
import { Miniflare } from "miniflare";
import { readFile, readdir } from "node:fs/promises";
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
const db = await mf.getD1Database("DB");
for (const file of (await readdir("migrations")).sort())
  for (const sql of (await readFile("migrations/" + file, "utf8"))
    .split(";")
    .filter((s) => s.trim()))
    await db.prepare(sql).run();
console.log((await mf.ready).origin);
process.on("SIGTERM", async () => {
  await mf.dispose();
  process.exit(0);
});

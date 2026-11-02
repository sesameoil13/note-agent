import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { Miniflare } from "miniflare";
import { createHash } from "node:crypto";
const hash = (v) => createHash("sha256").update(v).digest("hex");
const setupToken = "budget-removed-setup-token-only";
const ownerToken = "budget-removed-owner-bearer-32-characters";
const mf = new Miniflare({
  modules: true,
  scriptPath: "src/worker.mjs",
  compatibilityDate: "2026-07-30",
  d1Databases: ["DB"],
  bindings: { ENROLLMENT_HASH: hash(setupToken) },
});
after(() => mf.dispose());
async function request(path, body, token = ownerToken) {
  const response = await mf.dispatchFetch("https://pairing.test" + path, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: "Bearer " + token } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { status: response.status, data: await response.json() };
}
const statements = async (file) =>
  (await readFile("migrations/" + file, "utf8"))
    .split(";")
    .filter((s) => s.trim());

before(async () => {
  const db = await mf.getD1Database("DB");
  for (const file of (await readdir("migrations")).sort())
    for (const sql of await statements(file)) await db.prepare(sql).run();
  await request("/v1/enroll", {
    setupToken,
    deviceId: "owner-device",
    deviceName: "Mac",
    tokenHash: hash(ownerToken),
  });
});

test("budget endpoints are gone for an enrolled device", async () => {
  for (const [path, body] of [
    ["/v1/budget", undefined],
    ["/v1/budget/quote", { kind: "text", inputBytes: 10 }],
    ["/v1/budget/settings", { limitCny: 100 }],
    ["/v1/budget/reserve", { quoteId: "quote-12345678" }],
    ["/v1/budget/attempt/attempt-12345678/send", {}],
    ["/v1/budget/attempt/attempt-12345678/settle", {}],
  ]) {
    const { status, data } = await request(path, body);
    assert.equal(status, 404, path);
    assert.deepEqual(data, { error: "not_found" }, path);
  }
});

test("the new migration drops the budget tables from a database that has them, keeping devices", async () => {
  const old = new Miniflare({
    modules: true,
    scriptPath: "src/worker.mjs",
    compatibilityDate: "2026-07-30",
    d1Databases: ["DB"],
    bindings: { ENROLLMENT_HASH: hash(setupToken) },
  });
  try {
    const db = await old.getD1Database("DB");
    const files = (await readdir("migrations")).sort();
    const earlier = files.filter((f) => f < "0006");
    const later = files.filter((f) => f >= "0006");
    assert.deepEqual(later, ["0006_drop_budget.sql"]);
    for (const file of earlier)
      for (const sql of await statements(file)) await db.prepare(sql).run();
    await db.batch([
      db
        .prepare(
          "INSERT INTO devices(id,name,token_hash,role,created_at) VALUES ('owner-device','Mac',?,'owner',0)",
        )
        .bind(hash(ownerToken)),
      db.prepare(
        "INSERT INTO budget_quotes(id,payload,expires_at) VALUES ('quote-1','{}',0)",
      ),
      db.prepare(
        "INSERT INTO budget_attempts(id,operation_id,device_id,month,state,input_bytes,reserve_cny,quote_id,created_at) VALUES ('attempt-1','op-1','owner-device','2026-10','sent',1,1,'quote-1',0)",
      ),
    ]);
    const tables = async () =>
      (
        await db
          .prepare(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite%' ORDER BY name",
          )
          .all()
      ).results.map((r) => r.name);
    assert.ok((await tables()).includes("budget_attempts"));

    for (const file of later)
      for (const sql of await statements(file)) await db.prepare(sql).run();

    assert.deepEqual(await tables(), [
      "devices",
      "pairs",
      "request_limits",
      "todo_ops",
      "todo_states",
    ]);
    const response = await old.dispatchFetch("https://pairing.test/v1/device", {
      headers: { authorization: "Bearer " + ownerToken },
    });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).deviceId, "owner-device");
  } finally {
    await old.dispose();
  }
});

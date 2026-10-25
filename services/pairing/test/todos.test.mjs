import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { Miniflare } from "miniflare";
import { createHash } from "node:crypto";
const hash = (v) => createHash("sha256").update(v).digest("hex");
const setupToken = "todo-test-setup-token-only";
const ownerToken = "todo-owner-device-bearer-32-characters";
const memberToken = "todo-member-device-bearer-32-characters";
const mf = new Miniflare({
  modules: true,
  scriptPath: "src/worker.mjs",
  compatibilityDate: "2026-07-30",
  d1Databases: ["DB"],
  bindings: { ENROLLMENT_HASH: hash(setupToken) },
});
after(() => mf.dispose());
async function request(path, body, token) {
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
const sync = (ops, after = 0, token = ownerToken) =>
  request("/v1/todos/sync", { ops, after }, token);
let n = 0;
const op = (kind, fields = {}) => ({
  opId: `op-${kind}-${++n}-abcdef`,
  noteId: "note-1",
  actionId: "act-1",
  kind,
  lifecycle: 1,
  at: 1000 + n,
  ...fields,
});
const stateOf = (data, actionId = "act-1") =>
  data.states.find((s) => s.actionId === actionId);

before(async () => {
  const db = await mf.getD1Database("DB");
  for (const file of (await readdir("migrations")).sort())
    for (const sql of (await readFile("migrations/" + file, "utf8"))
      .split(";")
      .filter((s) => s.trim()))
      await db.prepare(sql).run();
  await request("/v1/enroll", {
    setupToken,
    deviceId: "owner-device",
    deviceName: "Mac",
    tokenHash: hash(ownerToken),
  });
  await db
    .prepare(
      "INSERT INTO devices(id,name,token_hash,role,created_at) VALUES ('member-device','手机',?,'member',0)",
    )
    .bind(hash(memberToken))
    .run();
});

test("only paired devices may exchange to-do operations, and payloads are bounded", async () => {
  assert.equal(
    (await sync([], 0, "unknown-device-bearer-0000000")).status,
    401,
  );
  assert.equal(
    (await sync([op("complete", { kind: "delete-all" })])).status,
    400,
  );
  assert.equal((await sync([op("complete", { noteId: "../x" })])).status, 400);
  assert.equal(
    (await sync(Array.from({ length: 26 }, () => op("complete")))).status,
    400,
  );
  assert.equal((await sync([], -1)).status, 400);
});

test("a duplicate delivery is idempotent and completion beats a late snooze in the same lifecycle", async () => {
  const complete = op("complete", { actionId: "dup-act" });
  const first = await sync([complete]);
  assert.equal(first.status, 200);
  assert.deepEqual(first.data.accepted, [complete.opId]);
  const done = stateOf(first.data, "dup-act");
  assert.equal(done.completed, true);
  assert.equal(done.lifecycle, 1);
  const again = await sync([complete], 0, memberToken);
  assert.deepEqual(again.data.accepted, [complete.opId]);
  assert.equal(stateOf(again.data, "dup-act").version, done.version);
  // A snooze made offline (even with a later device time) arrives late.
  const late = await sync(
    [op("snooze", { actionId: "dup-act", at: 999999, until: 5000000 })],
    first.data.cursor,
    memberToken,
  );
  assert.equal(late.status, 200);
  const merged = await sync([], 0);
  assert.equal(stateOf(merged.data, "dup-act").completed, true);
  assert.equal(stateOf(merged.data, "dup-act").snoozeUntil ?? null, null);
});

test("reopen starts a new lifecycle that stale or out-of-order operations cannot overwrite", async () => {
  const id = "reopen-act";
  await sync([op("complete", { actionId: id })]);
  const reopened = await sync([
    op("reopen", { actionId: id, lifecycle: 2, time: 7000000 }),
  ]);
  let s = stateOf(reopened.data, id);
  assert.equal(s.lifecycle, 2);
  assert.equal(s.completed, false);
  assert.equal(s.reopenTime, 7000000);
  // Old lifecycle completions and snoozes, delayed or duplicated, are ignored.
  await sync(
    [
      op("complete", { actionId: id, lifecycle: 1, at: 99999999 }),
      op("snooze", { actionId: id, lifecycle: 1, until: 1, at: 99999999 }),
    ],
    0,
    memberToken,
  );
  s = stateOf((await sync([], 0)).data, id);
  assert.equal(s.lifecycle, 2);
  assert.equal(s.completed, false);
  assert.equal(s.snoozeUntil ?? null, null);
  // A newer lifecycle snooze applies; the later device time wins (ADR 0002).
  await sync([
    op("snooze", { actionId: id, lifecycle: 2, until: 8000000, at: 50 }),
  ]);
  await sync(
    [op("snooze", { actionId: id, lifecycle: 2, until: 9000000, at: 60 })],
    0,
    memberToken,
  );
  await sync([op("snooze", { actionId: id, lifecycle: 2, until: 1, at: 40 })]);
  s = stateOf((await sync([], 0)).data, id);
  assert.equal(s.snoozeUntil, 9000000);
  // Completion of lifecycle 2 arriving before its own reopen is still kept.
  const other = "early-complete";
  await sync([op("complete", { actionId: other, lifecycle: 2 })]);
  await sync([op("reopen", { actionId: other, lifecycle: 2, time: 1 })]);
  s = stateOf((await sync([], 0)).data, other);
  assert.equal(s.lifecycle, 2);
  assert.equal(s.completed, true);
});

test("removal is a tombstone that later operations cannot revive", async () => {
  const id = "removed-act";
  await sync([op("snooze", { actionId: id, until: 3, at: 3 })]);
  await sync([op("remove", { actionId: id })], 0, memberToken);
  await sync([
    op("reopen", { actionId: id, lifecycle: 5, time: 1 }),
    op("complete", { actionId: id, lifecycle: 5 }),
  ]);
  const s = stateOf((await sync([], 0)).data, id);
  assert.equal(s.removed, true);
});

test("pull is incremental by cursor and pages large backlogs", async () => {
  const start = (await sync([], 0)).data.cursor;
  const ops = Array.from({ length: 25 }, (_, i) =>
    op("complete", { actionId: `page-${i}` }),
  );
  await sync(ops);
  const seen = new Set();
  let cursor = start;
  for (;;) {
    const page = await sync([], cursor, memberToken);
    assert.ok(page.data.states.length <= 20);
    page.data.states.forEach((s) => seen.add(s.actionId));
    assert.ok(page.data.cursor >= cursor);
    cursor = page.data.cursor;
    if (!page.data.more) break;
  }
  assert.equal(seen.size, 25);
  assert.equal((await sync([], cursor)).data.states.length, 0);
});

// Deletion marks (T26) travel through the same endpoint under the reserved
// action id "_note": trash, restore and purge of one note.
async function pullMark(noteId, token = ownerToken) {
  let cursor = 0,
    found;
  for (;;) {
    const page = (await sync([], cursor, token)).data;
    for (const s of page.states)
      if (s.noteId === noteId && s.actionId === "_note") found = s;
    cursor = page.cursor;
    if (!page.more) return found;
  }
}
const mark = (kind, noteId, at, fields = {}) =>
  op(kind, { noteId, actionId: "_note", at, ...fields });

test("note marks are only accepted under the reserved action id, and to-do kinds are refused there", async () => {
  assert.equal((await sync([op("purge")])).status, 400);
  assert.equal((await sync([op("trash")])).status, 400);
  assert.equal(
    (await sync([op("complete", { actionId: "_note" })])).status,
    400,
  );
  assert.equal((await sync([mark("trash", "mark-bounds", 5)])).status, 200);
});

test("a stale or replayed restore cannot undo a later deletion; a later restore can", async () => {
  const id = "mark-note-1";
  const restoreOld = mark("restore", id, 100);
  await sync([mark("trash", id, 200)]);
  await sync([restoreOld], 0, memberToken);
  await sync([restoreOld]);
  let s = await pullMark(id, memberToken);
  assert.equal(s.mark, "trashed");
  await sync([mark("restore", id, 300)], 0, memberToken);
  s = await pullMark(id);
  assert.equal(s.mark, "restored");
});

test("a purge is final: no later restore, deletion or duplicate brings it back", async () => {
  const id = "mark-note-2";
  const purge = mark("purge", id, 50);
  await sync([mark("trash", id, 10), purge]);
  await sync([mark("restore", id, 900), purge], 0, memberToken);
  await sync([mark("trash", id, 1000)]);
  const s = await pullMark(id, memberToken);
  assert.equal(s.mark, "purged");
});

// To-do lifecycle coordination (ADR 0001/0002). Each operation is a partial
// state; states merge with a commutative, idempotent join, so duplicates and
// any delivery order converge: a higher lifecycle wins, completion wins within
// a lifecycle, the later device time wins between snoozes or reopen times, and
// removal is a tombstone. Note bodies never pass through this endpoint.
const KINDS = new Set(["complete", "snooze", "reopen", "remove"]);
const PAGE = 20;
const MAX_OPS = 25;
const ref = (v) => typeof v === "string" && /^[A-Za-z0-9_-]{1,100}$/.test(v);
const opRef = (v) => typeof v === "string" && /^[A-Za-z0-9_-]{8,80}$/.test(v);
const time = (v) => Number.isSafeInteger(v) && v >= 0;
const stamp = (at, opId) => `${String(at).padStart(16, "0")}:${opId}`;
const later = (a, b, field) =>
  (b[field + "Stamp"] || "") > (a[field + "Stamp"] || "") ? b : a;

export function joinTodo(a, b) {
  if (!a) return normalize(b);
  let r;
  if (a.lifecycle !== b.lifecycle) r = a.lifecycle > b.lifecycle ? a : b;
  else {
    const s = later(a, b, "snooze"),
      o = later(a, b, "reopen");
    const done = [a, b].filter((x) => x.completed && x.completedAt != null);
    r = {
      lifecycle: a.lifecycle,
      completed: !!(a.completed || b.completed),
      completedAt: done.length
        ? Math.min(...done.map((x) => x.completedAt))
        : null,
      snoozeUntil: s.snoozeUntil ?? null,
      snoozeStamp: s.snoozeStamp ?? null,
      reopenTime: o.reopenTime ?? null,
      reopenStamp: o.reopenStamp ?? null,
    };
  }
  return normalize({ ...r, removed: !!(a.removed || b.removed) });
}

function normalize(s) {
  const completed = !!s.completed;
  return {
    lifecycle: s.lifecycle,
    completed,
    completedAt: completed ? (s.completedAt ?? null) : null,
    removed: !!s.removed,
    // Completion closes the lifecycle, so its snooze no longer applies.
    snoozeUntil: completed ? null : (s.snoozeUntil ?? null),
    snoozeStamp: completed ? null : (s.snoozeStamp ?? null),
    reopenTime: s.reopenTime ?? null,
    reopenStamp: s.reopenStamp ?? null,
  };
}

function operationState(op) {
  const s = stamp(op.at, op.opId);
  switch (op.kind) {
    case "complete":
      return { lifecycle: op.lifecycle, completed: true, completedAt: op.at };
    case "snooze":
      return { lifecycle: op.lifecycle, snoozeUntil: op.until, snoozeStamp: s };
    case "reopen":
      return { lifecycle: op.lifecycle, reopenTime: op.time, reopenStamp: s };
    default:
      return { lifecycle: 0, removed: true };
  }
}

function validOperation(op, fail) {
  if (
    !op ||
    typeof op !== "object" ||
    !opRef(op.opId) ||
    !ref(op.noteId) ||
    !ref(op.actionId) ||
    !KINDS.has(op.kind) ||
    !time(op.at) ||
    !Number.isSafeInteger(op.lifecycle) ||
    op.lifecycle < 1 ||
    op.lifecycle > 1000000 ||
    (op.kind === "snooze" && !time(op.until)) ||
    (op.kind === "reopen" && (!time(op.time) || op.lifecycle < 2))
  )
    fail(400, "invalid_todo_operation");
}

async function apply(env, own, op, now, fail) {
  const db = env.DB;
  const key = `${op.noteId}:${op.actionId}`;
  if (
    await db.prepare("SELECT id FROM todo_ops WHERE id=?").bind(op.opId).first()
  )
    return;
  for (let attempt = 0; attempt < 5; attempt++) {
    const row = await db
      .prepare("SELECT payload,version FROM todo_states WHERE action_key=?")
      .bind(key)
      .first();
    const current = row ? JSON.parse(row.payload) : null;
    const version = row ? row.version : 0;
    const next = joinTodo(current, operationState(op));
    const record = db
      .prepare(
        "INSERT OR IGNORE INTO todo_ops(id,action_key,device_id,received_at) SELECT ?,?,?,? WHERE COALESCE((SELECT version FROM todo_states WHERE action_key=?),0)=?",
      )
      .bind(op.opId, key, own.id, now, key, version);
    if (current && JSON.stringify(current) === JSON.stringify(next)) {
      const [done] = await db.batch([record]);
      if (done.meta.changes) return;
      continue;
    }
    const [, changed] = await db.batch([
      record,
      db
        .prepare(
          "INSERT INTO todo_states(action_key,note_id,action_id,payload,version,seq) VALUES (?,?,?,?,1,(SELECT COALESCE(MAX(seq),0)+1 FROM todo_states)) ON CONFLICT(action_key) DO UPDATE SET payload=excluded.payload,version=todo_states.version+1,seq=excluded.seq WHERE todo_states.version=?",
        )
        .bind(key, op.noteId, op.actionId, JSON.stringify(next), version),
    ]);
    if (changed.meta.changes) return;
    if (
      await db
        .prepare("SELECT id FROM todo_ops WHERE id=?")
        .bind(op.opId)
        .first()
    )
      return;
  }
  fail(503, "todo_busy");
}

export async function todoRequest(
  request,
  env,
  { own, now, body, fail, response },
) {
  const url = new URL(request.url);
  if (url.pathname !== "/v1/todos/sync" || request.method !== "POST")
    fail(404, "not_found");
  const data = await body(request);
  if (
    !Array.isArray(data.ops) ||
    data.ops.length > MAX_OPS ||
    !Number.isSafeInteger(data.after) ||
    data.after < 0
  )
    fail(400, "invalid_todo_operation");
  data.ops.forEach((op) => validOperation(op, fail));
  const accepted = [];
  for (const op of data.ops) {
    await apply(env, own, op, now, fail);
    accepted.push(op.opId);
  }
  const rows = (
    await env.DB.prepare(
      "SELECT note_id,action_id,payload,version,seq FROM todo_states WHERE seq>? ORDER BY seq LIMIT ?",
    )
      .bind(data.after, PAGE + 1)
      .all()
  ).results;
  const page = rows.slice(0, PAGE);
  return response({
    accepted,
    states: page.map((r) => ({
      noteId: r.note_id,
      actionId: r.action_id,
      version: r.version,
      ...JSON.parse(r.payload),
    })),
    cursor: page.length ? page[page.length - 1].seq : data.after,
    more: rows.length > PAGE,
  });
}

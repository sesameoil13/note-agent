const response = (data, status = 200) =>
  Response.json(data, {
    status,
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
const hash = async (value) =>
  [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    ),
  ]
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
const safeId = (value) =>
  typeof value === "string" && /^[a-zA-Z0-9_-]{8,80}$/.test(value);
const safeName = (value) =>
  typeof value === "string" &&
  value.trim().length > 0 &&
  value.length <= 80 &&
  !/[\x00-\x1f]/.test(value);
const safeHash = (value) =>
  typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const token = (request) =>
  /^Bearer ([a-zA-Z0-9_-]{24,128})$/.exec(
    request.headers.get("authorization") || "",
  )?.[1];
class ApiFailure extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}
const fail = (status, code) => {
  throw new ApiFailure(status, code);
};
const unexpired = (pair) => {
  if (pair.status !== "completed" && pair.expires_at <= Date.now())
    fail(410, "pair_expired");
};
async function body(request) {
  if (!request.headers.get("content-type")?.startsWith("application/json"))
    fail(415, "json_required");
  const chunks = [];
  let size = 0;
  for await (const chunk of request.body || []) {
    size += chunk.byteLength;
    if (size > 8192) fail(413, "request_too_large");
    chunks.push(chunk);
  }
  const all = new Uint8Array(size);
  let pos = 0;
  for (const chunk of chunks) {
    all.set(chunk, pos);
    pos += chunk.byteLength;
  }
  try {
    const parsed = JSON.parse(new TextDecoder().decode(all));
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object")
      fail(400, "invalid_json");
    return parsed;
  } catch {
    fail(400, "invalid_json");
  }
}
async function device(request, env) {
  const bearer = token(request);
  if (!bearer) fail(401, "device_auth_required");
  const result = await env.DB.prepare(
    "SELECT id,name,role FROM devices WHERE token_hash = ?",
  )
    .bind(await hash(bearer))
    .first();
  if (!result) fail(401, "device_auth_required");
  return result;
}
async function limit(request, env, now, group, maximum) {
  const ip = request.headers.get("cf-connecting-ip") || "local";
  const bucket = await hash(`${group}:${ip}:${Math.floor(now / 60000)}`);
  const row = await env.DB.prepare(
    "INSERT INTO request_limits(bucket,hits,expires_at) VALUES (?,1,?) ON CONFLICT(bucket) DO UPDATE SET hits=hits+1 RETURNING hits",
  )
    .bind(bucket, now + 120000)
    .first();
  if (row.hits > maximum) fail(429, "rate_limited");
}
export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url),
        now = Date.now();
      if (
        url.protocol !== "https:" &&
        url.hostname !== "127.0.0.1" &&
        url.hostname !== "localhost"
      )
        fail(400, "https_required");
      if (url.search || request.headers.has("origin"))
        fail(400, "native_app_required");
      if (url.pathname === "/v1/health" && request.method === "GET")
        return response({ service: "note-agent-pairing", version: 1 });
      await limit(request, env, now, "requests", 120);
      if (url.pathname === "/v1/enroll" && request.method === "POST") {
        await limit(request, env, now, "enroll", 5);
        const data = await body(request);
        if (
          typeof data.setupToken !== "string" ||
          data.setupToken.length > 128 ||
          !env.ENROLLMENT_HASH ||
          (await hash(data.setupToken)) !== env.ENROLLMENT_HASH
        )
          fail(401, "setup_invalid");
        if (
          !safeId(data.deviceId) ||
          !safeName(data.deviceName) ||
          !safeHash(data.tokenHash)
        )
          fail(400, "invalid_device");
        const existing = await env.DB.prepare(
          "SELECT id,token_hash FROM devices WHERE role = 'owner'",
        ).first();
        if (existing) {
          if (
            existing.id === data.deviceId &&
            existing.token_hash === data.tokenHash
          )
            return response({ deviceId: existing.id, role: "owner" });
          fail(409, "already_enrolled");
        }
        try {
          await env.DB.prepare(
            "INSERT INTO devices(id,name,token_hash,role,created_at) VALUES (?,?,?,'owner',?)",
          )
            .bind(data.deviceId, data.deviceName.trim(), data.tokenHash, now)
            .run();
        } catch {
          fail(409, "already_enrolled");
        }
        return response({ deviceId: data.deviceId, role: "owner" }, 201);
      }
      if (url.pathname === "/v1/device" && request.method === "GET") {
        const own = await device(request, env);
        return response({
          deviceId: own.id,
          deviceName: own.name,
          role: own.role,
          scope:
            own.role === "owner"
              ? ["pairing:approve", "device:self"]
              : ["device:self"],
        });
      }

      if (url.pathname === "/v1/pairs" && request.method === "POST") {
        const own = await device(request, env);
        if (own.role !== "owner") fail(403, "owner_required");
        await limit(request, env, now, "create", 3);
        const data = await body(request);
        if (!safeId(data.pairId) || !safeHash(data.claimHash))
          fail(400, "invalid_pair");
        await env.DB.batch([
          env.DB.prepare(
            "DELETE FROM request_limits WHERE expires_at < ?",
          ).bind(now),
          env.DB.prepare(
            "UPDATE pairs SET status='expired',ciphertext=NULL WHERE expires_at < ? AND status IN ('open','claimed','approved')",
          ).bind(now),
          env.DB.prepare("DELETE FROM pairs WHERE expires_at < ?").bind(
            now - 86400000,
          ),
        ]);
        const prior = await env.DB.prepare(
          "SELECT owner_id,claim_hash,status,expires_at FROM pairs WHERE id = ?",
        )
          .bind(data.pairId)
          .first();
        if (prior) {
          if (
            prior.owner_id === own.id &&
            prior.claim_hash === data.claimHash &&
            prior.status === "open"
          )
            return response({
              pairId: data.pairId,
              expiresAt: prior.expires_at,
            });
          fail(409, "pair_already_exists");
        }
        const expiresAt =
          now +
          Math.min(300, Math.max(1, Number(env.PAIR_TTL_SECONDS) || 300)) *
            1000;
        try {
          await env.DB.prepare(
            "INSERT INTO pairs(id,owner_id,claim_hash,expires_at,status) VALUES (?,?,?,?,'open')",
          )
            .bind(data.pairId, own.id, data.claimHash, expiresAt)
            .run();
        } catch {
          fail(409, "active_pair_exists");
        }
        return response({ pairId: data.pairId, expiresAt }, 201);
      }
      const match =
        /^\/v1\/pairs\/([a-zA-Z0-9_-]{8,80})(?:\/(claim|result|approve|ack|reject))?$/.exec(
          url.pathname,
        );
      if (match) {
        const [, id, action] = match;
        const pair = await env.DB.prepare("SELECT * FROM pairs WHERE id = ?")
          .bind(id)
          .first();
        if (!pair) fail(404, "pair_not_found");
        if (pair.expires_at <= now && pair.status !== "completed") {
          await env.DB.prepare(
            "UPDATE pairs SET status='expired',ciphertext=NULL WHERE id = ? AND status IN ('open','claimed','approved')",
          )
            .bind(id)
            .run();
          fail(410, "pair_expired");
        }
        if (action === "claim" && request.method === "POST") {
          await limit(request, env, now, "claim", 8);
          const data = await body(request);
          unexpired(pair);
          if (
            typeof data.claimToken !== "string" ||
            data.claimToken.length > 128 ||
            (await hash(data.claimToken)) !== pair.claim_hash
          )
            fail(401, "pair_code_invalid");
          if (
            !safeId(data.deviceId) ||
            !safeName(data.deviceName) ||
            !safeHash(data.tokenHash)
          )
            fail(400, "invalid_device");
          if (
            pair.status === "claimed" &&
            pair.device_id === data.deviceId &&
            pair.token_hash === data.tokenHash
          )
            return response({ status: "waiting_approval" });
          if (pair.status !== "open") fail(409, "pair_already_claimed");
          if (
            await env.DB.prepare(
              "SELECT id FROM devices WHERE id = ? OR token_hash = ?",
            )
              .bind(data.deviceId, data.tokenHash)
              .first()
          )
            fail(409, "device_already_enrolled");
          const changed = await env.DB.prepare(
            "UPDATE pairs SET status='claimed',device_id=?,device_name=?,token_hash=? WHERE id=? AND status='open' AND expires_at>?",
          )
            .bind(
              data.deviceId,
              data.deviceName.trim(),
              data.tokenHash,
              id,
              Date.now(),
            )
            .run();
          if (!changed.meta.changes) {
            unexpired(pair);
            fail(409, "pair_already_claimed");
          }
          return response({ status: "waiting_approval" });
        }
        if (
          (action === "result" && request.method === "GET") ||
          (action === "ack" && request.method === "POST")
        ) {
          const bearer = token(request);
          if (
            !bearer ||
            !pair.token_hash ||
            (await hash(bearer)) !== pair.token_hash
          )
            fail(401, "device_auth_required");
          unexpired(pair);
          if (pair.status === "rejected") fail(403, "pair_rejected");
          if (pair.status === "completed")
            return response({ status: "completed" });
          if (pair.status === "claimed")
            return response({ status: "waiting_approval" });
          if (pair.status !== "approved") fail(409, "pair_not_ready");
          if (action === "result")
            return response({
              status: "approved",
              ciphertext: pair.ciphertext,
              deviceId: pair.device_id,
            });
          await body(request);
          unexpired(pair);
          const mutationNow = Date.now();
          const committed = await env.DB.batch([
            env.DB.prepare(
              "INSERT INTO devices(id,name,token_hash,role,created_at) SELECT device_id,device_name,token_hash,'member',? FROM pairs WHERE id=? AND status='approved' AND expires_at>? ON CONFLICT(id) DO NOTHING",
            ).bind(mutationNow, id, mutationNow),
            env.DB.prepare(
              "UPDATE pairs SET status='completed',ciphertext=NULL WHERE id=? AND status='approved' AND expires_at>?",
            ).bind(id, mutationNow),
          ]);
          if (!committed[1].meta.changes) {
            const latest = await env.DB.prepare(
              "SELECT status FROM pairs WHERE id=?",
            )
              .bind(id)
              .first();
            if (latest?.status !== "completed") {
              unexpired(pair);
              fail(403, "pair_rejected");
            }
          }
          return response({ status: "completed" });
        }
        const own = await device(request, env);
        if (own.role !== "owner" || own.id !== pair.owner_id)
          fail(403, "owner_required");
        if (!action && request.method === "GET")
          return response({
            status: pair.status,
            expiresAt: pair.expires_at,
            deviceId: pair.device_id,
            deviceName: pair.device_name,
            tokenHash: pair.token_hash,
          });
        if (action === "approve" && request.method === "POST") {
          const data = await body(request);
          unexpired(pair);
          if (
            typeof data.ciphertext !== "string" ||
            data.ciphertext.length < 16 ||
            data.ciphertext.length > 6000
          )
            fail(400, "invalid_sealed_config");
          if (pair.status === "approved" && pair.ciphertext === data.ciphertext)
            return response({ status: "approved" });
          const changed = await env.DB.prepare(
            "UPDATE pairs SET status='approved',ciphertext=? WHERE id=? AND status='claimed' AND expires_at>?",
          )
            .bind(data.ciphertext, id, Date.now())
            .run();
          if (!changed.meta.changes) {
            unexpired(pair);
            fail(409, "pair_not_ready");
          }
          return response({ status: "approved" });
        }
        if (action === "reject" && request.method === "POST") {
          await body(request);
          if (pair.status === "completed") fail(409, "pair_completed");
          const changed = await env.DB.prepare(
            "UPDATE pairs SET status='rejected',ciphertext=NULL WHERE id=? AND status IN ('open','claimed','approved')",
          )
            .bind(id)
            .run();
          if (!changed.meta.changes) {
            const latest = await env.DB.prepare(
              "SELECT status FROM pairs WHERE id=?",
            )
              .bind(id)
              .first();
            if (latest?.status !== "rejected") fail(409, "pair_completed");
          }
          return response({ status: "rejected" });
        }
      }
      fail(404, "not_found");
    } catch (error) {
      return response(
        {
          error:
            error instanceof ApiFailure ? error.code : "service_unavailable",
        },
        error instanceof ApiFailure ? error.status : 503,
      );
    }
  },
};

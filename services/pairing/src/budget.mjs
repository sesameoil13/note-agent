const MODEL = "deepseek/deepseek-v4.1-flash";
const MAX_OUTPUT = 1024;
const MAX_INPUT = 20000;
const integer = (v, min = 0, max = 1e12) =>
  Number.isSafeInteger(v) && v >= min && v <= max;
const id = (v) => typeof v === "string" && /^[a-zA-Z0-9_-]{8,80}$/.test(v);
const ceilRatio = (a, b) => Number((BigInt(a) + BigInt(b) - 1n) / BigInt(b));
const cny = (usd, fx) => ceilRatio(BigInt(usd) * BigInt(fx), 1000000000);
const month = (now) => new Date(now + 8 * 3600000).toISOString().slice(0, 7);
async function sha(value) {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    ),
  ]
    .map((v) => v.toString(16).padStart(2, "0"))
    .join("");
}
async function limited(url, max) {
  const r = await fetch(url, {
    redirect: "manual",
    signal: AbortSignal.timeout(12000),
  });
  if (!r.ok) throw Error("quote_unavailable");
  const reader = r.body.getReader();
  let text = "",
    size = 0;
  const decoder = new TextDecoder();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > max) {
      await reader.cancel();
      throw Error("quote_unavailable");
    }
    text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}
async function quote(env, now) {
  const cached = await env.DB.prepare(
    "SELECT payload FROM budget_quotes WHERE expires_at>? ORDER BY expires_at DESC LIMIT 1",
  )
    .bind(now)
    .first();
  if (cached) return JSON.parse(cached.payload);
  const [catalog, xml] = await Promise.all([
    limited(
      `https://openrouter.ai/api/v1/models/${MODEL}/endpoints`,
      262144,
    ).then(JSON.parse),
    limited(
      "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml",
      32768,
    ),
  ]);
  if (catalog.data?.id !== MODEL) throw Error("quote_unavailable");
  const candidates = (catalog.data.endpoints || []).filter(
    (e) =>
      e.status === 0 &&
      e.model_id === MODEL &&
      /^[a-z0-9_/-]{1,80}$/.test(e.tag || "") &&
      [
        "max_tokens",
        "response_format",
        "structured_outputs",
        "reasoning",
      ].every((p) => e.supported_parameters?.includes(p)) &&
      Number(e.pricing?.prompt) > 0 &&
      Number(e.pricing?.prompt) <= 0.0000006 &&
      Number(e.pricing?.completion) > 0 &&
      Number(e.pricing?.completion) <= 0.0000024,
  );
  candidates.sort(
    (a, b) =>
      Number(a.pricing.prompt) - Number(b.pricing.prompt) ||
      Number(a.pricing.completion) - Number(b.pricing.completion),
  );
  const route = candidates[0];
  if (!route) throw Error("quote_unavailable");
  const date = /time=['"]([0-9-]+)['"]/.exec(xml)?.[1];
  const usd = Number(
    /currency=['"]USD['"] rate=['"]([0-9.]+)['"]/.exec(xml)?.[1],
  );
  const yuan = Number(
    /currency=['"]CNY['"] rate=['"]([0-9.]+)['"]/.exec(xml)?.[1],
  );
  const age = now - Date.parse(date + "T00:00:00Z");
  if (
    !Number.isFinite(age) ||
    age < -86400000 ||
    age > 7 * 86400000 ||
    !(usd > 0) ||
    !(yuan / usd >= 1 && yuan / usd <= 20)
  )
    throw Error("quote_unavailable");
  const q = {
    model: MODEL,
    provider: route.tag,
    promptNano: Math.ceil(Number(route.pricing.prompt) * 1e9),
    completionNano: Math.ceil(Number(route.pricing.completion) * 1e9),
    fxMicros: Math.ceil((yuan / usd) * 1e6 * 1.1),
    fxDate: date,
    fxMarginPercent: 10,
    retryMarginPercent: 25,
    maxOutput: MAX_OUTPUT,
    maxInput: MAX_INPUT,
  };
  q.id = await sha(JSON.stringify(q));
  q.expiresAt = now + 600000;
  await env.DB.prepare(
    "INSERT INTO budget_quotes(id,payload,expires_at) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,expires_at=excluded.expires_at",
  )
    .bind(q.id, JSON.stringify(q), q.expiresAt)
    .run();
  return q;
}
async function state(env, now) {
  const row = await env.DB.prepare(
    `SELECT
    COALESCE(SUM(CASE WHEN month=? AND state='settled' THEN actual_cny ELSE 0 END),0) spent,
    COALESCE(SUM(CASE WHEN state IN ('reserved','sent','uncertain') THEN reserve_cny ELSE 0 END),0) held,
    COALESCE(SUM(CASE WHEN state IN ('sent','uncertain') THEN reserve_cny ELSE 0 END),0) uncertain,
    COALESCE(MAX(disputed),0) disputed FROM budget_attempts`,
  )
    .bind(month(now))
    .first();
  const limit = (
    await env.DB.prepare(
      "SELECT limit_cny FROM budget_settings WHERE id=1",
    ).first()
  ).limit_cny;
  return {
    month: month(now),
    limitCnyMicros: limit,
    spentCnyMicros: row.spent,
    reservedCnyMicros: row.held,
    unknownCnyMicros: row.uncertain,
    disputed: !!row.disputed,
  };
}
export async function budgetRequest(request, env, context) {
  const { own, now, body, fail, response } = context;
  const path = new URL(request.url).pathname;
  if (path === "/v1/budget" && request.method === "GET")
    return response(await state(env, now));
  if (path === "/v1/budget/quote" && request.method === "POST") {
    try {
      return response({
        quote: await quote(env, now),
        budget: await state(env, now),
      });
    } catch {
      return fail(503, "quote_unavailable");
    }
  }
  if (path === "/v1/budget/settings" && request.method === "POST") {
    if (own.role !== "owner") fail(403, "owner_required");
    const d = await body(request);
    if (!integer(d.limitCnyMicros, 1, 30000000)) fail(400, "invalid_budget");
    await env.DB.prepare("UPDATE budget_settings SET limit_cny=? WHERE id=1")
      .bind(d.limitCnyMicros)
      .run();
    return response(await state(env, now));
  }
  if (path === "/v1/budget/reserve" && request.method === "POST") {
    const d = await body(request);
    if (
      !id(d.attemptId) ||
      !id(d.operationId) ||
      !integer(d.inputBytes, 1, MAX_INPUT) ||
      typeof d.quoteId !== "string"
    )
      fail(400, "invalid_budget");
    const prior = await env.DB.prepare(
      "SELECT * FROM budget_attempts WHERE id=?",
    )
      .bind(d.attemptId)
      .first();
    if (prior) {
      if (prior.device_id !== own.id || prior.operation_id !== d.operationId)
        fail(409, "attempt_conflict");
      return response({ attempt: prior, budget: await state(env, now) });
    }
    const row = await env.DB.prepare(
      "SELECT payload FROM budget_quotes WHERE id=? AND expires_at>?",
    )
      .bind(d.quoteId, now)
      .first();
    if (!row) fail(409, "quote_expired");
    const q = JSON.parse(row.payload);
    const usd =
      (d.inputBytes + 512) * q.promptNano + MAX_OUTPUT * q.completionNano;
    const amount = ceilRatio(BigInt(cny(usd, q.fxMicros)) * 125n, 100);
    const result = await env.DB.prepare(
      `INSERT INTO budget_attempts(id,operation_id,device_id,month,state,reserve_cny,quote_id,created_at)
      SELECT ?,?,?,?,'reserved',?,?,? WHERE
      (SELECT COALESCE(SUM(CASE WHEN state='settled' AND month=? THEN actual_cny WHEN state IN ('reserved','sent','uncertain') THEN reserve_cny ELSE 0 END),0) FROM budget_attempts)+? <= (SELECT limit_cny FROM budget_settings WHERE id=1)
      AND NOT EXISTS (SELECT 1 FROM budget_attempts WHERE disputed=1)`,
    )
      .bind(
        d.attemptId,
        d.operationId,
        own.id,
        month(now),
        amount,
        q.id,
        now,
        month(now),
        amount,
      )
      .run();
    if (result.meta.changes !== 1) fail(409, "budget_exceeded");
    return response(
      {
        attempt: await env.DB.prepare(
          "SELECT * FROM budget_attempts WHERE id=?",
        )
          .bind(d.attemptId)
          .first(),
        budget: await state(env, now),
      },
      201,
    );
  }
  fail(404, "not_found");
}

const MODEL = "deepseek/deepseek-v4.1-flash";
const MAX_OUTPUT = 1024;
const MAX_INPUT = 20000;
const integer = (v, min = 0, max = 1e12) =>
  Number.isSafeInteger(v) && v >= min && v <= max;
const id = (v) => typeof v === "string" && /^[a-zA-Z0-9_-]{8,80}$/.test(v);
const ceilRatio = (a, b) => Number((BigInt(a) + BigInt(b) - 1n) / BigInt(b));
const cny = (usd, fx) => ceilRatio(BigInt(usd) * BigInt(fx), 1000000000);
const month = (now) => new Date(now + 8 * 3600000).toISOString().slice(0, 7);
function fixed(value, scale) {
  const match = /^(\d+)(?:\.(\d+))?$/.exec(String(value));
  if (!match) throw Error("quote_unavailable");
  const fraction = match[2] || "";
  const base =
    BigInt(match[1]) * 10n ** BigInt(scale) +
    BigInt(fraction.slice(0, scale).padEnd(scale, "0") || "0");
  return Number(base + (fraction.slice(scale).replace(/0/g, "") ? 1n : 0n));
}
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
    "SELECT payload FROM budget_quotes WHERE expires_at>? AND json_extract(payload,'$.purpose') IS NULL ORDER BY expires_at DESC LIMIT 1",
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
      Number(e.pricing?.request ?? 0) === 0 &&
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
    promptNano: fixed(route.pricing.prompt, 9),
    completionNano: fixed(route.pricing.completion, 9),
    fxMicros: ceilRatio(
      BigInt(fixed(String(yuan), 9)) * 1100000n,
      BigInt(fixed(String(usd), 9)),
    ),
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
const STT_MODEL = "openai/whisper-large-v3-turbo";
async function audioQuote(env, now) {
  const base = await quote(env, now);
  const catalog = JSON.parse(
    await limited(
      `https://openrouter.ai/api/v1/models/${STT_MODEL}/endpoints`,
      262144,
    ),
  );
  const routes = catalog.data?.endpoints;
  if (
    catalog.data?.id !== STT_MODEL ||
    !Array.isArray(routes) ||
    !routes.length
  )
    throw Error("quote_unavailable");
  // The trusted local decoder proves duration. The Worker binds that duration,
  // derives the price itself, and never receives private audio or a client rate.
  const prices = [];
  for (const e of routes) {
    if (e.status !== 0) continue;
    if (
      e.model_id !== STT_MODEL ||
      !["deepinfra/us", "groq"].includes(e.tag) ||
      !e.pricing ||
      !(Number(e.pricing.prompt) > 0) ||
      Number(e.pricing.prompt) > 0.000012 ||
      Object.entries(e.pricing).some(
        ([key, value]) => key !== "prompt" && Number(value) !== 0,
      )
    )
      throw Error("quote_unavailable");
    prices.push(fixed(e.pricing.prompt, 9));
  }
  if (!prices.length) throw Error("quote_unavailable");
  const q = {
    purpose: "transcription",
    model: STT_MODEL,
    routes: routes
      .filter((e) => e.status === 0)
      .map((e) => e.tag)
      .sort(),
    secondNano: Math.max(...prices),
    minimumSeconds: 10,
    durationMarginPercent: 25,
    fxMicros: base.fxMicros,
    fxDate: base.fxDate,
    retryMarginPercent: 25,
    maxDurationMs: 600000,
    maxInput: 25000000,
    remotePriceCap: false,
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
function sourceBinding(d) {
  if (d.purpose !== "transcription") return null;
  const s = d.source;
  if (
    !s ||
    !id(s.sourceId) ||
    !/^[a-f0-9]{64}$/.test(s.digest || "") ||
    !["wav", "mp3", "m4a", "aac"].includes(s.format) ||
    !integer(s.durationMs, 1, 600000)
  )
    throw Error("invalid_budget");
  return JSON.stringify({
    purpose: "transcription",
    sourceId: s.sourceId,
    digest: s.digest,
    format: s.format,
    durationMs: s.durationMs,
  });
}
async function state(env, now) {
  const row = await env.DB.prepare(
    `SELECT
    COALESCE(SUM(CASE WHEN month=? AND state='settled' THEN actual_cny ELSE 0 END),0) spent,
    COALESCE(SUM(CASE WHEN month=? AND state='settled' THEN usd_nanos ELSE 0 END),0) usd,
    COALESCE(SUM(CASE WHEN state IN ('reserved','sent','uncertain') THEN reserve_cny ELSE 0 END),0) held,
    COALESCE(SUM(CASE WHEN state IN ('sent','uncertain') THEN reserve_cny ELSE 0 END),0) uncertain,
    COALESCE(MAX(disputed),0) disputed FROM budget_attempts WHERE month=? OR state IN ('reserved','sent','uncertain') OR disputed=1`,
  )
    .bind(month(now), month(now), month(now))
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
    spentUsdNanos: row.usd,
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
        quote:
          (await body(request)).purpose === "transcription"
            ? await audioQuote(env, now)
            : await quote(env, now),
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
      !integer(
        d.inputBytes,
        1,
        d.purpose === "transcription" ? 25000000 : MAX_INPUT,
      ) ||
      typeof d.quoteId !== "string"
    )
      fail(400, "invalid_budget");
    let binding;
    try {
      binding = sourceBinding(d);
    } catch {
      fail(400, "invalid_budget");
    }
    const prior = await env.DB.prepare(
      "SELECT * FROM budget_attempts WHERE id=?",
    )
      .bind(d.attemptId)
      .first();
    if (prior) {
      if (
        prior.device_id !== own.id ||
        prior.operation_id !== d.operationId ||
        prior.quote_id !== d.quoteId ||
        prior.input_bytes !== d.inputBytes ||
        prior.source_binding !== binding
      )
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
    if ((q.purpose || null) !== (d.purpose || null))
      fail(409, "attempt_conflict");
    const usd =
      q.purpose === "transcription"
        ? ceilRatio(
            BigInt(
              Math.max(q.minimumSeconds, Math.ceil(d.source.durationMs / 1000)),
            ) * 125n,
            100,
          ) * q.secondNano
        : (d.inputBytes + 512) * q.promptNano + MAX_OUTPUT * q.completionNano;
    const amount = ceilRatio(BigInt(cny(usd, q.fxMicros)) * 125n, 100);
    const result = await env.DB.prepare(
      `INSERT INTO budget_attempts(id,operation_id,device_id,month,state,reserve_cny,quote_id,created_at,input_bytes,source_binding)
      SELECT ?,?,?,?,'reserved',?,?,?,?,? WHERE
      (SELECT COALESCE(SUM(CASE WHEN state='settled' AND month=? THEN actual_cny WHEN state IN ('reserved','sent','uncertain') THEN reserve_cny ELSE 0 END),0) FROM budget_attempts WHERE month=? OR state IN ('reserved','sent','uncertain'))+? <= (SELECT limit_cny FROM budget_settings WHERE id=1)
      AND NOT EXISTS (SELECT 1 FROM budget_attempts WHERE disputed=1) ON CONFLICT(id) DO NOTHING`,
    )
      .bind(
        d.attemptId,
        d.operationId,
        own.id,
        month(now),
        amount,
        q.id,
        now,
        d.inputBytes,
        binding,
        month(now),
        month(now),
        amount,
      )
      .run();
    if (result.meta.changes !== 1) {
      const same = await env.DB.prepare(
        "SELECT * FROM budget_attempts WHERE id=?",
      )
        .bind(d.attemptId)
        .first();
      if (!same) fail(409, "budget_exceeded");
      if (
        same.device_id !== own.id ||
        same.operation_id !== d.operationId ||
        same.quote_id !== d.quoteId ||
        same.input_bytes !== d.inputBytes ||
        same.source_binding !== binding
      )
        fail(409, "attempt_conflict");
    }
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
  const inspection = /^\/v1\/budget\/attempt\/([a-zA-Z0-9_-]{8,80})$/.exec(
    path,
  );
  if (inspection && request.method === "GET") {
    const attempt = await env.DB.prepare(
      "SELECT * FROM budget_attempts WHERE id=? AND device_id=?",
    )
      .bind(inspection[1], own.id)
      .first();
    if (!attempt) fail(404, "attempt_missing");
    return response({ attempt, budget: await state(env, now) });
  }
  const match =
    /^\/v1\/budget\/attempt\/([a-zA-Z0-9_-]{8,80})\/(send|uncertain|release|settle)$/.exec(
      path,
    );
  if (match && request.method === "POST") {
    const a = await env.DB.prepare(
      "SELECT * FROM budget_attempts WHERE id=? AND device_id=?",
    )
      .bind(match[1], own.id)
      .first();
    if (!a) fail(404, "attempt_missing");
    const action = match[2];
    if (action === "send") {
      if (a.state !== "reserved") fail(409, "attempt_not_sendable");
      if (
        await env.DB.prepare(
          "SELECT 1 FROM budget_attempts WHERE disputed=1 LIMIT 1",
        ).first()
      )
        fail(409, "cost_conflict");
      const r = await env.DB.prepare(
        "UPDATE budget_attempts SET state='sent' WHERE id=? AND state='reserved' AND NOT EXISTS (SELECT 1 FROM budget_attempts WHERE disputed=1)",
      )
        .bind(a.id)
        .run();
      if (r.meta.changes !== 1) fail(409, "attempt_not_sendable");
    } else if (action === "release") {
      await env.DB.prepare(
        "UPDATE budget_attempts SET state='released' WHERE id=? AND state='reserved'",
      )
        .bind(a.id)
        .run();
    } else if (action === "uncertain") {
      await env.DB.prepare(
        "UPDATE budget_attempts SET state='uncertain' WHERE id=? AND state='sent'",
      )
        .bind(a.id)
        .run();
    } else {
      const d = await body(request);
      if (!integer(d.usdNanos) || !id(d.generationId))
        fail(400, "invalid_cost");
      if (a.state === "settled") {
        if (a.usd_nanos !== d.usdNanos || a.generation_id !== d.generationId) {
          await env.DB.prepare(
            "UPDATE budget_attempts SET disputed=1 WHERE id=?",
          )
            .bind(a.id)
            .run();
          fail(409, "cost_conflict");
        }
      } else {
        if (!["sent", "uncertain"].includes(a.state))
          fail(409, "attempt_not_sent");
        const q = JSON.parse(
          (
            await env.DB.prepare("SELECT payload FROM budget_quotes WHERE id=?")
              .bind(a.quote_id)
              .first()
          ).payload,
        );
        try {
          await env.DB.prepare(
            "UPDATE budget_attempts SET state='settled',usd_nanos=?,actual_cny=?,generation_id=? WHERE id=? AND state IN ('sent','uncertain')",
          )
            .bind(d.usdNanos, cny(d.usdNanos, q.fxMicros), d.generationId, a.id)
            .run();
        } catch {
          const collision = await env.DB.prepare(
            "SELECT id FROM budget_attempts WHERE generation_id=? AND id<>?",
          )
            .bind(d.generationId, a.id)
            .first();
          if (!collision) fail(503, "budget_unavailable");
          // Preserve the existing receipt and this unresolved hold. A unique
          // receipt collision must durably block all later paid admission.
          await env.DB.prepare(
            "UPDATE budget_attempts SET disputed=1 WHERE id=?",
          )
            .bind(a.id)
            .run();
          fail(409, "generation_conflict");
        }
        if (cny(d.usdNanos, q.fxMicros) > a.reserve_cny) {
          await env.DB.prepare(
            "UPDATE budget_attempts SET disputed=1 WHERE id=?",
          )
            .bind(a.id)
            .run();
        }
        const committed = await env.DB.prepare(
          "SELECT usd_nanos,generation_id FROM budget_attempts WHERE id=?",
        )
          .bind(a.id)
          .first();
        if (
          committed.usd_nanos !== d.usdNanos ||
          committed.generation_id !== d.generationId
        ) {
          await env.DB.prepare(
            "UPDATE budget_attempts SET disputed=1 WHERE id=?",
          )
            .bind(a.id)
            .run();
          fail(409, "cost_conflict");
        }
      }
    }
    return response({
      attempt: await env.DB.prepare("SELECT * FROM budget_attempts WHERE id=?")
        .bind(a.id)
        .first(),
      budget: await state(env, now),
    });
  }
  fail(404, "not_found");
}

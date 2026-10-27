import { test } from "node:test";
import assert from "node:assert/strict";
import { Miniflare, createFetchMock } from "miniflare";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Bailian (ADR 0003) has no public price API: the Worker quotes from a yuan
// price table in its configuration and never fetches anything to do so.
const PRICES = {
  version: "fixture-2026-10-27",
  text: {
    model: "qwen-plus",
    promptNanoCnyPerToken: 800,
    completionNanoCnyPerToken: 2000,
  },
  transcription: {
    model: "qwen3-asr-flash",
    secondNanoCny: 250000,
    minimumSeconds: 1,
  },
};

function options(prices, persist, openRouter = false) {
  const mock = createFetchMock();
  mock.disableNetConnect();
  if (openRouter) mockOpenRouter(mock);
  return {
    modules: true,
    scriptPath: "src/worker.mjs",
    compatibilityDate: "2026-07-30",
    d1Databases: ["DB"],
    ...(persist ? { d1Persist: persist } : {}),
    fetchMock: mock,
    bindings: {
      ENROLLMENT_HASH: createHash("sha256").update("test-setup").digest("hex"),
      ...(prices ? { BAILIAN_PRICES: JSON.stringify(prices) } : {}),
    },
  };
}

// The old OpenRouter text price route and exchange rate, as older apps use.
function mockOpenRouter(mock) {
  mock
    .get("https://openrouter.ai")
    .intercept({
      path: "/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints",
    })
    .reply(200, {
      data: {
        id: "deepseek/deepseek-v4.1-flash",
        endpoints: [
          {
            model_id: "deepseek/deepseek-v4.1-flash",
            tag: "fixture/provider",
            status: 0,
            pricing: { prompt: "0.0000006", completion: "0.0000024" },
            supported_parameters: [
              "max_tokens",
              "response_format",
              "structured_outputs",
              "reasoning",
            ],
          },
        ],
      },
    })
    .persist();
  mock
    .get("https://www.ecb.europa.eu")
    .intercept({ path: "/stats/eurofxref/eurofxref-daily.xml" })
    .reply(
      200,
      `<Cube time='${new Date().toISOString().slice(0, 10)}'><Cube currency='USD' rate='1'/><Cube currency='CNY' rate='7'/></Cube>`,
    )
    .persist();
}

async function worker(prices = PRICES, persist, openRouter = false) {
  const token = "bailian-test-owner-token-0000000032";
  const mf = new Miniflare(options(prices, persist, openRouter));
  try {
    await migrate(mf);
  } catch (error) {
    await mf.dispose();
    throw error;
  }
  return { mf, req: requester(mf, token) };
}

async function migrate(mf) {
  const db = await mf.getD1Database("DB");
  for (const file of [
    "0001_pairing.sql",
    "0002_budget.sql",
    "0003_audio_budget.sql",
    "0005_bailian_budget.sql",
  ])
    for (const sql of (await readFile("migrations/" + file, "utf8"))
      .split(";")
      .filter((s) => s.trim()))
      await db.prepare(sql).run();
}

function requester(mf, token) {
  return async (path, body) => {
    const r = await mf.dispatchFetch("https://fixture.test" + path, {
      method: body === undefined ? "GET" : "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer " + token,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: r.status, data: await r.json() };
  };
}

async function enrolled(prices, persist, openRouter = false) {
  const { mf, req } = await worker(prices, persist, openRouter);
  await req("/v1/enroll", {
    setupToken: "test-setup",
    deviceId: "bailian-owner",
    deviceName: "fixture",
    tokenHash: createHash("sha256")
      .update("bailian-test-owner-token-0000000032")
      .digest("hex"),
  });
  return { mf, req };
}

test("a Bailian text request is quoted in yuan from the table and settled from token usage", async () => {
  const { mf, req } = await enrolled();
  try {
    const quoted = await req("/v1/budget/quote", { provider: "bailian-cn" });
    assert.equal(quoted.status, 200);
    const q = quoted.data.quote;
    assert.equal(q.provider, "bailian-cn");
    assert.equal(q.model, "qwen-plus");
    assert.equal(q.currency, "CNY");
    assert.equal(q.rateVersion, "fixture-2026-10-27");
    assert.equal(q.promptNanoCny, 800);
    assert.equal(q.completionNanoCny, 2000);

    const reserved = await req("/v1/budget/reserve", {
      attemptId: "bailian-text-1",
      operationId: "bailian-text-op-1",
      quoteId: q.id,
      inputBytes: 1200,
    });
    assert.equal(reserved.status, 201);
    // ((1200 + 512) × 800 + 1024 × 2000) nano-元 = 3417.6 micro-元 → 3418,
    // plus the 25% margin → 4273 (rounded up).
    assert.equal(reserved.data.attempt.reserve_cny, 4273);

    assert.equal(
      (await req("/v1/budget/attempt/bailian-text-1/send", {})).status,
      200,
    );
    const receipt = {
      responseId: "chatcmpl-e9d2271a-5ba2-948c-9084-74c1babb745a",
      usage: { promptTokens: 377, completionTokens: 173 },
    };
    const settled = await req(
      "/v1/budget/attempt/bailian-text-1/settle",
      receipt,
    );
    assert.equal(settled.status, 200);
    assert.equal(settled.data.attempt.state, "settled");
    // 377 × 800 + 173 × 2000 = 647600 nano-元 → 648 micro-元.
    assert.equal(settled.data.attempt.actual_cny, 648);
    assert.equal(settled.data.budget.spentCnyMicros, 648);

    // The same receipt replays; a different one is a dispute.
    assert.equal(
      (await req("/v1/budget/attempt/bailian-text-1/settle", receipt)).status,
      200,
    );
    assert.equal(
      (
        await req("/v1/budget/attempt/bailian-text-1/settle", {
          ...receipt,
          usage: { promptTokens: 377, completionTokens: 174 },
        })
      ).status,
      409,
    );
  } finally {
    await mf.dispose();
  }
});

const chunk = (index, durationMs) => ({
  sourceId: "bailian-source-1",
  digest: "b".repeat(64),
  format: "m4a",
  durationMs,
  chunk: { index, count: 2 },
});

test("each transcription part is reserved and settled by seconds, within the per-request limits", async () => {
  const { mf, req } = await enrolled();
  try {
    const q = (
      await req("/v1/budget/quote", {
        provider: "bailian-cn",
        purpose: "transcription",
      })
    ).data.quote;
    assert.equal(q.model, "qwen3-asr-flash");
    assert.equal(q.secondNanoCny, 250000);
    const reserve = (attemptId, source, inputBytes = 1040000) =>
      req("/v1/budget/reserve", {
        attemptId,
        operationId: "bailian-audio-op-" + attemptId,
        quoteId: q.id,
        purpose: "transcription",
        inputBytes,
        source,
      });
    // Over 4.5 min plus slack, or over 7 MB (base64 must stay under 10 MB).
    assert.equal(
      (await reserve("too-long-part", chunk(0, 290001))).status,
      400,
    );
    assert.equal(
      (await reserve("too-big-part", chunk(0, 167000), 7000001)).status,
      400,
    );
    assert.equal(
      (
        await reserve("bad-part", {
          ...chunk(0, 167000),
          chunk: { index: 2, count: 2 },
        })
      ).status,
      400,
    );
    const first = await reserve("bailian-part-0", chunk(0, 167000));
    assert.equal(first.status, 201);
    // ceil(167 s × 1.25) = 209 s × 250000 nano-元 = 52250 micro-元, + 25% → 65313.
    assert.equal(first.data.attempt.reserve_cny, 65313);
    const second = await reserve("bailian-part-1", chunk(1, 167000));
    assert.equal(second.status, 201);

    await req("/v1/budget/attempt/bailian-part-0/send", {});
    const settled = await req("/v1/budget/attempt/bailian-part-0/settle", {
      responseId: "chatcmpl-part-0-0000000000",
      usage: { seconds: 167 },
    });
    assert.equal(settled.status, 200);
    assert.equal(settled.data.attempt.actual_cny, 41750);
    // A text-shaped receipt is not a transcription receipt.
    await req("/v1/budget/attempt/bailian-part-1/send", {});
    assert.equal(
      (
        await req("/v1/budget/attempt/bailian-part-1/settle", {
          responseId: "chatcmpl-part-1-0000000000",
          usage: { promptTokens: 1, completionTokens: 1 },
        })
      ).status,
      400,
    );
  } finally {
    await mf.dispose();
  }
});

test("without a valid price table Bailian is not quoted, and other quotes still go to OpenRouter", async () => {
  const { mf, req } = await enrolled(null);
  try {
    assert.equal(
      (await req("/v1/budget/quote", { provider: "bailian-cn" })).status,
      503,
    );
    // No provider: the old OpenRouter path, which needs a live price fetch
    // (disabled here), so it is unavailable rather than silently Bailian.
    assert.equal((await req("/v1/budget/quote", {})).status, 503);
  } finally {
    await mf.dispose();
  }
  const broken = await enrolled({
    ...PRICES,
    text: { ...PRICES.text, model: "qwen3.8-flash" },
  });
  try {
    assert.equal(
      (await broken.req("/v1/budget/quote", { provider: "bailian-cn" })).status,
      503,
    );
  } finally {
    await broken.mf.dispose();
  }
});

test("a price change never re-prices an attempt that is already open", async () => {
  const persist = await mkdtemp(join(tmpdir(), "bailian-budget-"));
  const { mf, req } = await enrolled(PRICES, persist);
  try {
    const old = (await req("/v1/budget/quote", { provider: "bailian-cn" })).data
      .quote;
    await req("/v1/budget/reserve", {
      attemptId: "bailian-before-change",
      operationId: "bailian-before-change-op",
      quoteId: old.id,
      inputBytes: 100,
    });
    await req("/v1/budget/attempt/bailian-before-change/send", {});
    await mf.setOptions(
      options(
        {
          ...PRICES,
          version: "fixture-2026-11-01",
          text: { ...PRICES.text, promptNanoCnyPerToken: 1600 },
        },
        persist,
      ),
    );
    const fresh = (await req("/v1/budget/quote", { provider: "bailian-cn" }))
      .data.quote;
    assert.equal(fresh.promptNanoCny, 1600);
    assert.notEqual(fresh.id, old.id);
    const settled = await req(
      "/v1/budget/attempt/bailian-before-change/settle",
      {
        responseId: "chatcmpl-before-change-000",
        usage: { promptTokens: 1000, completionTokens: 0 },
      },
    );
    // Frozen at the old 800 nano-元 per token: 1000 × 800 = 800 micro-元.
    assert.equal(settled.data.attempt.actual_cny, 800);
  } finally {
    await mf.dispose();
    await rm(persist, { recursive: true, force: true });
  }
});

test("an older app still gets an OpenRouter quote after Bailian quotes exist", async () => {
  const { mf, req } = await enrolled(PRICES, undefined, true);
  try {
    assert.equal(
      (await req("/v1/budget/quote", { provider: "bailian-cn" })).status,
      200,
    );
    const legacy = await req("/v1/budget/quote", {});
    assert.equal(legacy.status, 200);
    assert.equal(legacy.data.quote.provider, "fixture/provider");
    assert.equal(legacy.data.quote.promptNano, 600);
    assert.ok(legacy.data.quote.fxMicros > 0);
    assert.equal(legacy.data.quote.currency, undefined);
    // A cached OpenRouter quote is not handed to a Bailian request either.
    const bailian = await req("/v1/budget/quote", { provider: "bailian-cn" });
    assert.equal(bailian.data.quote.provider, "bailian-cn");
  } finally {
    await mf.dispose();
  }
});

test("a recording may be split into as many parts as its size needs, up to eight", async () => {
  const { mf, req } = await enrolled();
  try {
    const q = (
      await req("/v1/budget/quote", {
        provider: "bailian-cn",
        purpose: "transcription",
      })
    ).data.quote;
    const reserve = (index, count) =>
      req("/v1/budget/reserve", {
        attemptId: `bailian-many-${index}-${count}`,
        operationId: `bailian-many-op-${index}-${count}`,
        quoteId: q.id,
        purpose: "transcription",
        inputBytes: 6000000,
        source: {
          sourceId: "bailian-many-source",
          digest: "c".repeat(64),
          format: "wav",
          durationMs: 30000,
          chunk: { index, count },
        },
      });
    // A 25 MB WAV needs four 7 MB parts even when it is short.
    assert.equal((await reserve(3, 4)).status, 201);
    assert.equal((await reserve(7, 8)).status, 201);
    assert.equal((await reserve(8, 9)).status, 400);
  } finally {
    await mf.dispose();
  }
});

test("a charge the user checked in the console settles a request whose response was lost", async () => {
  const { mf, req } = await enrolled();
  try {
    const q = (await req("/v1/budget/quote", { provider: "bailian-cn" })).data
      .quote;
    const lost = async (attemptId) => {
      const r = await req("/v1/budget/reserve", {
        attemptId,
        operationId: attemptId + "-op",
        quoteId: q.id,
        inputBytes: 1200,
      });
      await req(`/v1/budget/attempt/${attemptId}/send`, {});
      return r.data.attempt.reserve_cny;
    };
    const reserved = await lost("bailian-lost-1");
    const settled = await req("/v1/budget/attempt/bailian-lost-1/settle", {
      confirmedCnyMicros: 650,
    });
    assert.equal(settled.status, 200);
    assert.equal(settled.data.attempt.state, "settled");
    assert.equal(settled.data.attempt.actual_cny, 650);
    assert.equal(settled.data.budget.reservedCnyMicros, 0);
    assert.equal(settled.data.budget.spentCnyMicros, 650);
    // Recording the same amount again is harmless.
    assert.equal(
      (
        await req("/v1/budget/attempt/bailian-lost-1/settle", {
          confirmedCnyMicros: 650,
        })
      ).status,
      200,
    );

    // Not billed at all is recorded as zero and frees the hold.
    await lost("bailian-lost-2");
    const zero = await req("/v1/budget/attempt/bailian-lost-2/settle", {
      confirmedCnyMicros: 0,
    });
    assert.equal(zero.data.attempt.actual_cny, 0);

    // Only whole, bounded amounts.
    await lost("bailian-lost-4");
    for (const bad of [-1, 1.5, 30000001, "650"])
      assert.equal(
        (
          await req("/v1/budget/attempt/bailian-lost-4/settle", {
            confirmedCnyMicros: bad,
          })
        ).status,
        400,
      );
    // More than was held is recorded as it is, and pauses paid admission.
    const held = await lost("bailian-lost-3");
    const over = await req("/v1/budget/attempt/bailian-lost-3/settle", {
      confirmedCnyMicros: held + 1,
    });
    assert.equal(over.data.attempt.actual_cny, held + 1);
    assert.equal(over.data.budget.disputed, true);
    assert.ok(reserved > 0);
    // A different amount for a settled request is a dispute.
    assert.equal(
      (
        await req("/v1/budget/attempt/bailian-lost-1/settle", {
          confirmedCnyMicros: 700,
        })
      ).status,
      409,
    );
  } finally {
    await mf.dispose();
  }
});

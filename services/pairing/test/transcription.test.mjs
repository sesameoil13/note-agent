import { test } from "node:test";
import assert from "node:assert/strict";
import { Miniflare, createFetchMock } from "miniflare";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
test("STT binding and conservative budget; above-reserve actual pauses admission", async () => {
  const mock = createFetchMock();
  mock.disableNetConnect();
  const route = (tag, prompt) => ({
    tag,
    model_id: "openai/whisper-large-v3-turbo",
    status: 0,
    pricing: { prompt, completion: "0", request: "0" },
  });
  mock
    .get("https://openrouter.ai")
    .intercept({
      path: "/api/v1/models/openai/whisper-large-v3-turbo/endpoints",
    })
    .reply(200, {
      data: {
        id: "openai/whisper-large-v3-turbo",
        endpoints: [
          route("deepinfra/us", "0.00000333"),
          route("groq", "0.0000111111111111"),
        ],
      },
    })
    .times(1);
  mock
    .get("https://openrouter.ai")
    .intercept({
      path: "/api/v1/models/openai/whisper-large-v3-turbo/endpoints",
    })
    .reply(200, {
      data: {
        id: "openai/whisper-large-v3-turbo",
        endpoints: [route("unknown/audio-route", "0.000001")],
      },
    })
    .persist();
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
  const token = "transcription-test-owner-token-32";
  const mf = new Miniflare({
    modules: true,
    scriptPath: "tools/budget-latency-fixture.mjs",
    compatibilityDate: "2026-07-30",
    d1Databases: ["DB"],
    fetchMock: mock,
    bindings: {
      ENROLLMENT_HASH: createHash("sha256").update("test-setup").digest("hex"),
    },
  });
  try {
    const db = await mf.getD1Database("DB");
    for (const file of [
      "0001_pairing.sql",
      "0002_budget.sql",
      "0003_audio_budget.sql",
    ])
      for (const sql of (await readFile("migrations/" + file, "utf8"))
        .split(";")
        .filter((s) => s.trim()))
        await db.prepare(sql).run();
    const req = async (path, body, extra = {}) => {
      const r = await mf.dispatchFetch("https://fixture.test" + path, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: "Bearer " + token,
          ...extra,
        },
        body: JSON.stringify(body),
      });
      return { status: r.status, data: await r.json() };
    };
    await req("/v1/enroll", {
      setupToken: "test-setup",
      deviceId: "audio-owner",
      deviceName: "fixture",
      tokenHash: createHash("sha256").update(token).digest("hex"),
    });
    const quoted = await req("/v1/budget/quote", { purpose: "transcription" });
    assert.equal(quoted.status, 200);
    assert.equal(quoted.data.quote.secondNano, 11112);
    assert.equal(quoted.data.quote.remotePriceCap, false);
    const textQuote = await req("/v1/budget/quote", {});
    const textReserve = await req("/v1/budget/reserve", {
      attemptId: "text-held-before-overrun",
      operationId: "text-operation-before-overrun",
      quoteId: textQuote.data.quote.id,
      inputBytes: 200,
    });
    assert.equal(textReserve.status, 201);
    const source = {
      sourceId: "audio-source-1",
      digest: "a".repeat(64),
      format: "wav",
      durationMs: 600000,
    };
    const binding = {
      attemptId: "audio-attempt-1",
      operationId: "audio-operation-1",
      quoteId: quoted.data.quote.id,
      purpose: "transcription",
      inputBytes: 19200044,
      source,
    };
    assert.equal(
      (
        await req("/v1/budget/reserve", {
          ...binding,
          source: { ...source, durationMs: 600001 },
        })
      ).status,
      400,
    );
    assert.equal(
      (await req("/v1/budget/reserve", { ...binding, inputBytes: 25000001 }))
        .status,
      400,
    );
    assert.equal(
      (await req("/v1/budget/quote", { purpose: "transcription" })).status,
      503,
    );
    const reserved = await req("/v1/budget/reserve", binding);
    assert.equal(reserved.status, 201);
    assert.ok(reserved.data.attempt.reserve_cny > 64000);
    assert.equal(
      (
        await req("/v1/budget/reserve", {
          ...binding,
          source: { ...source, durationMs: 1000 },
        })
      ).status,
      409,
    );
    assert.equal(
      (await req("/v1/budget/attempt/audio-attempt-1/send", {})).status,
      200,
    );
    const settling = req(
      "/v1/budget/attempt/audio-attempt-1/settle",
      {
        generationId: "gen-audio-overrun",
        usdNanos: 100000000,
      },
      { "x-fixture-write-latency": "first-write" },
    );
    let receipt;
    try {
      let reached = false;
      for (let i = 0; i < 100; i++) {
        reached = (
          await (
            await mf.dispatchFetch("https://fixture.test/fixture-write-status")
          ).json()
        ).reached;
        if (reached) break;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      assert.equal(reached, true);
      const observed = await (
        await mf.dispatchFetch("https://fixture.test/v1/budget", {
          headers: { authorization: "Bearer " + token },
        })
      ).json();
      assert.equal(observed.spentUsdNanos, 100000000);
      assert.equal(observed.disputed, true);
      assert.equal(
        (await req("/v1/budget/attempt/text-held-before-overrun/send", {}))
          .status,
        409,
      );
    } finally {
      receipt = await settling;
    }
    assert.equal(receipt.data.budget.disputed, true);
    assert.equal(
      (await req("/v1/budget/attempt/text-held-before-overrun/send", {}))
        .status,
      409,
    );
    assert.equal(receipt.data.attempt.usd_nanos, 100000000);
    assert.equal(
      (
        await req("/v1/budget/reserve", {
          ...binding,
          attemptId: "audio-attempt-2",
        })
      ).status,
      409,
    );
  } finally {
    await mf.dispose();
  }
});

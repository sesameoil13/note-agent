// Synthetic HTTP/ECB boundaries only; no external account, model or credential.
import { Miniflare, createFetchMock } from "miniflare";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
const mock = createFetchMock();
mock.disableNetConnect();
mock
  .get("https://openrouter.ai")
  .intercept({ path: "/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints" })
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
  .get("https://openrouter.ai")
  .intercept({ path: "/api/v1/models/openai/whisper-large-v3-turbo/endpoints" })
  .reply(200, {
    data: {
      id: "openai/whisper-large-v3-turbo",
      endpoints: [
        {
          model_id: "openai/whisper-large-v3-turbo",
          tag: "groq",
          status: 0,
          pricing: {
            prompt: "0.0000111111111111",
            completion: "0",
            request: "0",
          },
        },
      ],
    },
  })
  .persist();
const date = new Date().toISOString().slice(0, 10);
mock
  .get("https://www.ecb.europa.eu")
  .intercept({ path: "/stats/eurofxref/eurofxref-daily.xml" })
  .reply(
    200,
    `<Cube time='${date}'><Cube currency='USD' rate='1'/><Cube currency='CNY' rate='7'/></Cube>`,
  )
  .persist();
const mf = new Miniflare({
  modules: true,
  scriptPath: "tools/budget-worker-fixture.mjs",
  compatibilityDate: "2026-07-30",
  d1Databases: ["DB"],
  bindings: {
    ENROLLMENT_HASH: createHash("sha256")
      .update("local-test-setup-only")
      .digest("hex"),
    // Synthetic Bailian yuan price table (ADR 0003), not real prices.
    BAILIAN_PRICES: JSON.stringify({
      version: "fixture",
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
    }),
  },
  fetchMock: mock,
  host: "127.0.0.1",
  port: 0,
});
const db = await mf.getD1Database("DB");
for (const file of [
  "0001_pairing.sql",
  "0002_budget.sql",
  "0003_audio_budget.sql",
  "0004_todo_sync.sql",
  "0005_bailian_budget.sql",
]) {
  for (const sql of (await readFile("migrations/" + file, "utf8"))
    .split(";")
    .filter((s) => s.trim()))
    await db.prepare(sql).run();
}
console.log((await mf.ready).origin);
process.on("SIGTERM", async () => {
  await mf.dispose();
  process.exit(0);
});

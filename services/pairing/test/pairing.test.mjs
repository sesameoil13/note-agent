import { test, after } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { Miniflare } from "miniflare";
import { createHash } from "node:crypto";
const hash = (v) => createHash("sha256").update(v).digest("hex");
const setupToken = "test-setup-token-not-a-cloudflare-token";
const ownerToken = "owner-test-device-bearer-32-characters";
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

test("one-time setup enrolls a scoped owner device and cannot create another owner", async () => {
  const db = await mf.getD1Database("DB");
  await db.exec(await readFile("migrations/0001_pairing.sql", "utf8"));
  const owner = {
    setupToken,
    deviceId: "owner-device",
    deviceName: "Mac 工作台",
    tokenHash: hash(ownerToken),
  };
  assert.equal((await request("/v1/enroll", owner)).status, 201);
  const own = await request("/v1/device", undefined, ownerToken);
  assert.deepEqual(own.data, {
    deviceId: "owner-device",
    deviceName: "Mac 工作台",
    role: "owner",
    scope: ["pairing:approve", "device:self"],
  });
  assert.equal(
    (await request("/v1/enroll", { ...owner, deviceId: "other-device" }))
      .status,
    409,
  );
  assert.equal(
    (await request("/v1/device", undefined, "wrong-token")).status,
    401,
  );
});

test("an owner approves a single named device, which alone can receive and acknowledge the sealed configuration", async () => {
  const claim = "one-time-pair-access-32-characters";
  const member = "member-test-device-bearer-32-characters";
  assert.equal(
    (
      await request(
        "/v1/pairs",
        { pairId: "pair-first", claimHash: hash(claim) },
        ownerToken,
      )
    ).status,
    201,
  );
  assert.equal(
    (
      await request("/v1/pairs/pair-first/claim", {
        claimToken: claim,
        deviceId: "phone-device",
        deviceName: "手机",
        tokenHash: hash(member),
      })
    ).status,
    200,
  );
  assert.equal(
    (
      await request("/v1/pairs/pair-first/claim", {
        claimToken: claim,
        deviceId: "other-device",
        deviceName: "陌生设备",
        tokenHash: hash("different-token"),
      })
    ).status,
    409,
  );
  const pending = await request("/v1/pairs/pair-first", undefined, ownerToken);
  assert.equal(pending.data.status, "claimed");
  assert.equal(pending.data.deviceName, "手机");
  assert.equal(
    (await request("/v1/pairs/pair-first/result", undefined, member)).data
      .status,
    "waiting_approval",
  );
  assert.equal(
    (
      await request(
        "/v1/pairs/pair-first/approve",
        { ciphertext: "sealed-config-not-readable-to-worker" },
        member,
      )
    ).status,
    401,
  );
  assert.equal(
    (
      await request(
        "/v1/pairs/pair-first/approve",
        { ciphertext: "sealed-config-not-readable-to-worker" },
        ownerToken,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "/v1/pairs/pair-first/result",
        undefined,
        "wrong-device-bearer",
      )
    ).status,
    401,
  );
  assert.equal(
    (await request("/v1/pairs/pair-first/result", undefined, member)).data
      .ciphertext,
    "sealed-config-not-readable-to-worker",
  );
  assert.equal(
    (await request("/v1/pairs/pair-first/ack", {}, member)).status,
    200,
  );
  assert.equal(
    (await request("/v1/pairs/pair-first/ack", {}, member)).status,
    200,
  );
  assert.equal(
    (await request("/v1/pairs/pair-first/result", undefined, member)).data
      .ciphertext,
    undefined,
  );
  const joined = await request("/v1/device", undefined, member);
  assert.deepEqual(joined.data.scope, ["device:self"]);
  assert.equal(
    (
      await request(
        "/v1/pairs",
        { pairId: "member-pair", claimHash: hash(claim) },
        member,
      )
    ).status,
    403,
  );
});

test("owner rejection removes the sealed result and simultaneous claims admit only one device", async () => {
  const claim = "race-claim-token-32-test-characters";
  assert.equal(
    (
      await request(
        "/v1/pairs",
        { pairId: "pair-reject", claimHash: hash(claim) },
        ownerToken,
      )
    ).status,
    201,
  );
  const claimWith = (id) =>
    request("/v1/pairs/pair-reject/claim", {
      claimToken: claim,
      deviceId: id,
      deviceName: id,
      tokenHash: hash(id + "-bearer-32-test-characters"),
    });
  const results = await Promise.all([
    claimWith("racing-phone"),
    claimWith("racing-other"),
  ]);
  assert.deepEqual(results.map((x) => x.status).sort(), [200, 409]);
  const winner = await request("/v1/pairs/pair-reject", undefined, ownerToken);
  const bearer = winner.data.deviceId + "-bearer-32-test-characters";
  assert.equal(
    (await request("/v1/pairs/pair-reject/reject", {}, ownerToken)).status,
    200,
  );
  assert.equal(
    (await request("/v1/pairs/pair-reject/result", undefined, bearer)).status,
    403,
  );
  assert.equal((await request("/v1/device", undefined, bearer)).status, 401);
});

test("an owner cancellation cannot undo an already acknowledged device when its body arrives late", async () => {
  const claim = "ack-race-claim-token-32-characters";
  const bearer = "ack-race-member-bearer-32-characters";
  assert.equal(
    (
      await request(
        "/v1/pairs",
        { pairId: "ack-race-pair", claimHash: hash(claim) },
        ownerToken,
      )
    ).status,
    201,
  );
  await request("/v1/pairs/ack-race-pair/claim", {
    claimToken: claim,
    deviceId: "ack-race-phone",
    deviceName: "手机",
    tokenHash: hash(bearer),
  });
  await request(
    "/v1/pairs/ack-race-pair/approve",
    { ciphertext: "sealed-race-config-only" },
    ownerToken,
  );
  let finishBody;
  const delayedBody = new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode("{"));
      finishBody = () => {
        controller.enqueue(new TextEncoder().encode("}"));
        controller.close();
      };
    },
  });
  const cancellation = mf.dispatchFetch(
    "https://pairing.test/v1/pairs/ack-race-pair/reject",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer " + ownerToken,
      },
      body: delayedBody,
      duplex: "half",
    },
  );
  assert.equal(
    (await request("/v1/pairs/ack-race-pair/ack", {}, bearer)).status,
    200,
  );
  finishBody();
  assert.equal((await cancellation).status, 409);
  assert.equal((await request("/v1/device", undefined, bearer)).status, 200);
  assert.equal(
    (await request("/v1/pairs/ack-race-pair", undefined, ownerToken)).data
      .status,
    "completed",
  );
});

test("expired pairing rejects approval and receipt, and repeated invalid setup is bounded", async () => {
  const worker = new Miniflare({
    modules: true,
    scriptPath: "src/worker.mjs",
    compatibilityDate: "2026-07-30",
    d1Databases: ["DB"],
    bindings: { ENROLLMENT_HASH: hash(setupToken), PAIR_TTL_SECONDS: "1" },
  });
  try {
    await (
      await worker.getD1Database("DB")
    ).exec(await readFile("migrations/0001_pairing.sql", "utf8"));
    const send = async (path, data, bearer) => {
      const response = await worker.dispatchFetch(
        "https://pairing.test" + path,
        {
          method: data ? "POST" : "GET",
          headers: {
            "content-type": "application/json",
            ...(bearer ? { authorization: "Bearer " + bearer } : {}),
          },
          ...(data ? { body: JSON.stringify(data) } : {}),
        },
      );
      return { status: response.status, data: await response.json() };
    };
    assert.equal(
      (
        await send("/v1/enroll", {
          setupToken,
          deviceId: "expiry-owner",
          deviceName: "Mac",
          tokenHash: hash(ownerToken),
        })
      ).status,
      201,
    );
    assert.equal(
      (
        await send(
          "/v1/pairs",
          { pairId: "expiry-pair", claimHash: hash("expiry-claim") },
          ownerToken,
        )
      ).status,
      201,
    );
    await send("/v1/pairs/expiry-pair/claim", {
      claimToken: "expiry-claim",
      deviceId: "expiry-phone",
      deviceName: "手机",
      tokenHash: hash("expiry-device-bearer-32-characters"),
    });
    await new Promise((resolve) => setTimeout(resolve, 1050));
    assert.equal(
      (
        await send(
          "/v1/pairs/expiry-pair/approve",
          { ciphertext: "sealed-config-no-plaintext" },
          ownerToken,
        )
      ).status,
      410,
    );
    assert.equal(
      (
        await send(
          "/v1/pairs/expiry-pair/result",
          undefined,
          "expiry-device-bearer-32-characters",
        )
      ).status,
      410,
    );
    assert.equal(
      (
        await send(
          "/v1/pairs",
          { pairId: "slow-body-pair", claimHash: hash("slow-body-claim") },
          ownerToken,
        )
      ).status,
      201,
    );
    const payload = JSON.stringify({
      claimToken: "slow-body-claim",
      deviceId: "slow-body-phone",
      deviceName: "手机",
      tokenHash: hash("slow-body-device-bearer-32-characters"),
    });
    const delayedBody = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(payload.slice(0, 1)));
        setTimeout(() => {
          controller.enqueue(new TextEncoder().encode(payload.slice(1)));
          controller.close();
        }, 1100);
      },
    });
    const delayed = await worker.dispatchFetch(
      "https://pairing.test/v1/pairs/slow-body-pair/claim",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: delayedBody,
        duplex: "half",
      },
    );
    assert.equal(
      delayed.status,
      410,
      "finishing a request body after expiry must not extend the pairing window",
    );
    let final;
    for (let count = 0; count < 6; count++)
      final = await send("/v1/enroll", { setupToken: "invalid" });
    assert.equal(final.status, 429);
  } finally {
    await worker.dispose();
  }
});

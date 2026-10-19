// Clock is an OS boundary fake in this loopback-only test entry. Production
// worker source has no clock route or clock override.
import production from "../src/worker.mjs";
let now = Date.now();
Date.now = () => now;
export default {
  async fetch(request, env, context) {
    if (
      new URL(request.url).pathname === "/fixture-clock" &&
      request.method === "POST"
    ) {
      const next = Number(await request.text());
      if (!Number.isSafeInteger(next)) return new Response("", { status: 400 });
      now = next;
      return new Response("ok");
    }
    return production.fetch(request, env, context);
  },
};

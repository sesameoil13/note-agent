// Local-only D1 adapter latency: pause after the first completed write, without
// inspecting SQL or exposing a production endpoint. Assertions remain HTTP-only.
import production from "../src/worker.mjs";
let reached = false;
export default {
  async fetch(request, env, context) {
    const path = new URL(request.url).pathname;
    if (path === "/fixture-write-status") return Response.json({ reached });
    if (request.headers.get("x-fixture-write-latency") !== "first-write")
      return production.fetch(request, env, context);
    let first = true;
    const wrap = (statement) =>
      new Proxy(statement, {
        get(target, key) {
          if (key === "bind") return (...args) => wrap(target.bind(...args));
          if (key === "run")
            return async (...args) => {
              const result = await target.run(...args);
              if (first) {
                first = false;
                reached = true;
                await new Promise((resolve) => setTimeout(resolve, 750));
              }
              return result;
            };
          const value = Reflect.get(target, key);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
    const DB = new Proxy(env.DB, {
      get(target, key) {
        if (key === "prepare")
          return (...args) => wrap(target.prepare(...args));
        const value = Reflect.get(target, key);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    return production.fetch(request, { ...env, DB }, context);
  },
};

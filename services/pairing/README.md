# Personal device pairing service

Worker + D1, limited to enrolling one owner, pairing explicitly approved devices, the shared budget ledger, and to-do lifecycle coordination (`POST /v1/todos/sync`, migration 0004; see [T23](../../docs/development/t23-todo-sync.md)). It does not store plaintext OpenRouter credentials, notes, audio or Cloudflare management tokens. The App supplies no management credential.

The deployment and protocol reference is [T12 connection and pairing](../../docs/development/t12-connection-pairing.md). Current `wrangler.toml` contains a placeholder D1 UUID and is intentionally not deployable to a real database as-is. No automatic deployment or paid plan configuration is present.

Use Node 22.12+ and a workspace-local pnpm installation. The project pins store/cache to ignored `.cache/` directories:

```sh
pnpm install
pnpm test
pnpm run check
```

`test` uses real local Workerd HTTP requests and a local D1 binding. `check` is Wrangler's `deploy --dry-run`, which bundles locally without provisioning or publishing. Set `WRANGLER_SEND_METRICS=false` and `WRANGLER_LOG_PATH` to a workspace cache directory when running Wrangler. The App's connection integration tests also need this service's installed dependencies and `node` on PATH (or `NOTE_AGENT_NODE` set to an absolute Node executable).

`tools/local-harness.mjs` is a loopback-only test fixture, started/stopped by the Dart tests. Its fixed test enrollment token must never be used for a deployed service. `tools/prepare-activation.mjs` generates a random one-use activation capability into ignored, owner-readable files; it does not log the capability or contact a service.

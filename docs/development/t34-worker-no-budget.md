# T34.7 Worker without the budget (issue #42)

Decision: [ADR 0004](../adr/0004-no-spending-tracking.md). The Worker in `services/pairing` keeps
pairing and to-do sync only.

## What changed

- `src/budget.mjs` is deleted: the `/v1/budget*` endpoints, the quote and attempt ledger,
  `BAILIAN_PRICES` and the OpenRouter compatibility path. Every `/v1/budget*` path now answers
  `404 not_found`. App versions up to v0.1.0 can no longer send to AI after this deploy.
- Migration `0006_drop_budget.sql` drops `budget_attempts`, `budget_quotes` and
  `budget_settings` (with their indexes). Devices, pairs, rate limits and to-do sync are untouched.
- `tools/budget-harness.mjs`, `tools/budget-worker-fixture.mjs`, `tools/budget-latency-fixture.mjs`,
  `test/bailian-budget.test.mjs` and `test/transcription.test.mjs` are deleted. The App tests start
  the Worker with `tools/local-harness.mjs`, which is unchanged.

## Deploying (human only, issue #43)

Deploy together with the Mac, Android and Windows release. From the repo, with the commit pushed:

```sh
zsh services/pairing/tools/deploy-drop-budget.sh <commit> "../cloud-release-no-budget" --prepare-only
zsh services/pairing/tools/deploy-drop-budget.sh <commit> "../cloud-release-no-budget"
```

The script:

1. Extracts `services/pairing` at `<commit>` into the release directory, sets the real D1 id, and
   stops unless that copy has migration 0006, no `/v1/budget` route and no `[vars]` (so the deploy
   also removes the old `BAILIAN_PRICES` variable).
2. Builds a local dry run (`wrangler deploy --dry-run`). `--prepare-only` stops here.
3. Read-only checks: Wrangler account, `/v1/health`, remote migration list.
4. Exports the remote database to `backup-before-0006.sql` (mode 600). It stops if the file
   already exists or doesn't contain the budget tables.
5. Asks, then deploys the Worker. The new Worker never reads the budget tables, so it goes before
   the migration: a failed deploy leaves the database as it was.
6. Asks, then applies migration 0006 to the remote database.
7. Verifies `/v1/health`, that `GET /v1/budget` returns 404, and the migration list.

Answering anything but `y` stops the script without further changes.

To undo the migration, restore the dropped tables from the backup with
`wrangler d1 execute note-agent-pairing --remote --file <the CREATE TABLE and INSERT INTO lines for budget_* from backup-before-0006.sql>`,
then redeploy the previous Worker commit.

## Tests

- `services/pairing/test/budget-removed.test.mjs` (Miniflare): every budget endpoint returns 404
  for an enrolled device; on a database built with migrations 0001–0005 and holding budget rows,
  migration 0006 leaves only the pairing and to-do tables and the owner device still works.
- `pairing.test.mjs`, `todos.test.mjs` and `merge-cases.test.mjs` are unchanged.
- The deploy script was checked with `zsh -n` and run with Wrangler and curl stubbed; it has not
  been run against Cloudflare.

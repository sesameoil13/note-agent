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
export NOTE_AGENT_D1_ID=<id of note-agent-pairing, from `wrangler d1 list`>
export NOTE_AGENT_CLOUD_ENV=<script that selects the isolated Wrangler login>
zsh services/pairing/tools/deploy-drop-budget.sh <commit> "../cloud-release-no-budget" --prepare-only
zsh services/pairing/tools/deploy-drop-budget.sh <commit> "../cloud-release-no-budget"
```

Both variables are required; the script stops with an error before doing anything if either is
missing. `NOTE_AGENT_ENDPOINT` overrides the Worker URL.

The script:

1. Extracts `services/pairing` at `<commit>` into the release directory (a directory prepared for
   another commit is refused), sets the real D1 id, and stops unless that copy has migration 0006, no `/v1/budget` route and no `[vars]` (so the deploy
   also removes the old `BAILIAN_PRICES` variable).
2. Builds a local dry run (`wrangler deploy --dry-run`). `--prepare-only` stops here.
3. Read-only checks: Wrangler account, `/v1/health`, remote migration list.
4. Exports the remote database to `backup-before-0006.sql` (mode 600). It stops if the file
   already exists or doesn't contain the budget tables.
5. Asks, then deploys the Worker. The new Worker never reads the budget tables, so it goes before
   the migration: a failed deploy leaves the database as it was.
6. Asks, then applies migration 0006 to the remote database.
7. Verifies `/v1/health`, the migration list, and that `GET /v1/budget` returns 404; anything
   else ends the script with an error.

Answering anything but `y` stops the script without further changes.

To undo, redeploy the previous Worker commit and restore the dropped tables from the backup:

```sh
# Statements span lines (CREATE TABLE budget_attempts), so split on ";\n", not on lines.
node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8").split(/;\n/);console.log(s.filter(x=>/^(PRAGMA|CREATE (UNIQUE )?(TABLE|INDEX) "?budget_|INSERT INTO "?budget_)/.test(x)).join(";\n")+";")' backup-before-0006.sql > restore-budget.sql
wrangler d1 execute note-agent-pairing --remote --file restore-budget.sql
```

Check `restore-budget.sql` before running it; the `d1_migrations` row for 0006 stays, so a
later `migrations apply` won't drop the tables again.

## Tests

- `services/pairing/test/budget-removed.test.mjs` (Miniflare): every budget endpoint returns 404
  for an enrolled device; on a database built with migrations 0001–0005 and holding budget rows,
  migration 0006 leaves only the pairing and to-do tables and the owner device still works.
- `pairing.test.mjs`, `todos.test.mjs` and `merge-cases.test.mjs` are unchanged.
- The deploy script was checked with `zsh -n` and run with Wrangler and curl stubbed; it has not
  been run against Cloudflare. Its answers were driven through a terminal: `y y` runs everything,
  `y n` deploys and stops before the migration, and without a terminal it stops before deploying.
  The restore extraction was checked against the T33 backup (`backup-before-0005.sql`) loaded
  into a local SQLite file.

#!/bin/zsh
# T34.7 (issue #42, ADR 0004): deploy the Worker without the budget and drop the
# budget tables (migration 0006). Free plan only; nothing is upgraded.
#
#   NOTE_AGENT_D1_ID=<d1-database-id> NOTE_AGENT_CLOUD_ENV=<wrangler-login-env.sh> \
#     zsh services/pairing/tools/deploy-drop-budget.sh <commit> <release-dir> [--prepare-only]
#
# NOTE_AGENT_D1_ID is the id of the remote note-agent-pairing database;
# NOTE_AGENT_CLOUD_ENV is a script sourced first to select the Wrangler login.
# Both are required. NOTE_AGENT_ENDPOINT overrides the Worker URL.
# <commit> is the pushed commit to deploy; <release-dir> is a new directory outside
# the repo that receives an isolated copy of services/pairing and the backup.
# The remote database is backed up first. Deploying and dropping the tables each
# ask before they run. --prepare-only stops after the local dry-run build.
# Release the apps together with this (docs/development/t34-worker-no-budget.md).
set -euo pipefail

REV=${1:?usage: deploy-drop-budget.sh <commit> <release-dir> [--prepare-only]}
OUT=${2:?usage: deploy-drop-budget.sh <commit> <release-dir> [--prepare-only]}
MODE=${3:-}
DB=note-agent-pairing
DB_ID=${NOTE_AGENT_D1_ID:?set NOTE_AGENT_D1_ID to the remote D1 database id (wrangler d1 list)}
ENDPOINT=${NOTE_AGENT_ENDPOINT:-https://note-agent-pairing.sesameoil13.workers.dev}
CLOUD_ENV=${NOTE_AGENT_CLOUD_ENV:?set NOTE_AGENT_CLOUD_ENV to the script that selects the Wrangler login}
[[ -r "$CLOUD_ENV" ]] || { echo "NOTE_AGENT_CLOUD_ENV: $CLOUD_ENV is not readable."; exit 1; }
REPO="${0:A:h}/../../.."
mkdir -p "$OUT"
OUT="${OUT:A}"
PAIRING="$OUT/services/pairing"
BACKUP="$OUT/backup-before-0006.sql"

ask() { read -q "?$1 [y/N] " || { echo; echo "Stopped."; exit 1; }; echo; }

source "$CLOUD_ENV"
export PATH="$HOME/.local/node-global/bin:$PATH"

echo "== 1. Isolated copy of services/pairing at $REV"
SHA=$(git -C "$REPO" rev-parse --verify "$REV^{commit}")
if [[ ! -d "$PAIRING" ]]; then
  git -C "$REPO" archive "$SHA" services/pairing | tar -x -C "$OUT"
  sed -i '' "s/database_id = \"00000000-0000-0000-0000-000000000000\"/database_id = \"$DB_ID\"/" "$PAIRING/wrangler.toml"
  ln -s "${REPO:A}/services/pairing/node_modules" "$PAIRING/node_modules"
  print "$SHA" > "$OUT/release-commit"
fi
# A directory prepared for another commit is never reused.
[[ "$(cat "$OUT/release-commit" 2>/dev/null)" == "$SHA" ]] || { echo "$OUT was prepared for another commit; use a new release directory."; exit 1; }
grep -q "database_id = \"$DB_ID\"" "$PAIRING/wrangler.toml"
[[ -f "$PAIRING/migrations/0006_drop_budget.sql" ]] || { echo "No migration 0006 at $REV."; exit 1; }
if grep -rq "/v1/budget" "$PAIRING/src"; then echo "Budget routes still in $REV."; exit 1; fi
# No [vars]: deploying without them also removes the old BAILIAN_PRICES variable.
if grep -q "^\[vars\]" "$PAIRING/wrangler.toml"; then echo "Unexpected [vars] in wrangler.toml."; exit 1; fi
cd "$PAIRING"
wr() { ${=NOTE_AGENT_WRANGLER:-node node_modules/wrangler/bin/wrangler.js} "$@"; }

echo "== 2. Dry run of the Worker build (nothing is sent)"
wr deploy --dry-run --outdir "$OUT/dry-run" | tail -5
[[ "$MODE" == "--prepare-only" ]] && { echo "Prepared only."; exit 0; }

echo "== 3. Read-only checks"
wr whoami | grep -i "account"
curl -fsS "$ENDPOINT/v1/health"; echo
wr d1 migrations list "$DB" --remote

echo "== 4. Backup of the current remote database (read-only export)"
[[ -e "$BACKUP" ]] && { echo "$BACKUP already exists; use a new release directory."; exit 1; }
wr d1 export "$DB" --remote --output "$BACKUP"
chmod 600 "$BACKUP"
grep -q "budget_attempts" "$BACKUP" || { echo "Backup has no budget tables; stopping before any change."; exit 1; }
ls -l "$BACKUP"

# The new Worker never reads the budget tables, so it goes first: the backup stays
# complete, and a failed deploy leaves the database untouched.
ask "Deploy the Worker from $REV (no budget routes, no BAILIAN_PRICES) to $ENDPOINT?"
wr deploy

ask "Apply migration 0006 (DROP the budget tables, backup at $BACKUP) to the REMOTE database?"
wr d1 migrations apply "$DB" --remote

echo "== 5. Verify"
curl -fsS "$ENDPOINT/v1/health"; echo
code=$(curl -s -o /dev/null -w '%{http_code}' "$ENDPOINT/v1/budget" || true)
echo "GET /v1/budget -> HTTP $code (expect 404: the budget is gone)"
wr d1 migrations list "$DB" --remote
[[ "$code" == 404 ]] || { echo "Verification failed: the budget endpoint did not answer 404."; exit 1; }
echo "Done. Keep $BACKUP until the release is accepted."

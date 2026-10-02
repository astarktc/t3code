#!/usr/bin/env bash
# Dry-run this checkout's startup migrations on copies of installed DBs (README:
# migration hazard). Each file is MIGRATED IN PLACE, so pass copies, never a live DB.
#
# Usage: fork-infra/dry-run-migrations.sh <copy.sqlite>...
#
# Make the copies first:
#   Mac (local or over ssh):  sqlite3 ~/.t3/userdata/statev2.sqlite "VACUUM INTO '/tmp/<host>.sqlite'"
#     VACUUM INTO reads one snapshot. `.backup` restarts from page 1 at every write by the
#     running app, so on a busy DB (the work Mac's 15 GB) it never finishes.
#     A large copy travels faster compressed: ssh <host> 'gzip -1 -c /tmp/<host>.sqlite' | gunzip -c > …
#   Windows: scp the host's .t3/userdata/statev2.sqlite, -wal and -shm together into one dir.
#
# Prints, per copy: the ledger before and after, MIGRATED_MS (startup migration time, to
# compare with deploy.sh's 300 s readiness deadline) and integrity_check.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ $# -gt 0 ]] || { echo "usage: $0 <copy.sqlite>..." >&2; exit 2; }

LIVE=$(cd ~/.t3/userdata 2>/dev/null && pwd -P)/statev2.sqlite
for db in "$@"; do
  [[ -f "$db" ]] || { echo "ERROR: no such file: $db" >&2; exit 1; }
  real="$(cd "$(dirname "$db")" && pwd -P)/$(basename "$db")"
  [[ "$real" != "$LIVE" ]] || { echo "ERROR: $db is the live DB — pass a copy" >&2; exit 1; }
done

DEST=apps/server/src/persistence/forkInfraMigrationDryRun.test.ts
cp fork-infra/migration-dry-run.ts "$DEST"
trap 'rm -f "$DEST"' EXIT

for db in "$@"; do
  real="$(cd "$(dirname "$db")" && pwd -P)/$(basename "$db")"
  echo "== $db"
  (cd apps/server && FORK_DRYRUN_DB="$real" pnpm exec vp test run "src/persistence/$(basename "$DEST")" \
    --reporter=verbose --silent=false 2>&1) \
    | grep -E '^(BEFORE|MIGRATED_MS|AFTER|INTEGRITY)|Tests |FAIL|Error' || true
done

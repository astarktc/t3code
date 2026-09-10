#!/usr/bin/env bash
# One-shot DB fix for the 2026-09-10 upstream absorption (QM-123).
#
# Base moved to the V2 branch head 8f44bec (PR #7211 was squash-merged into #2829,
# then #6461). Upstream inserted a new migration 50 ProjectionThreadPullRequests
# BEFORE the consolidated OrchestrationV2 migration, pushing it 50 -> 51.
#
# Failure mode is the CRASH-LOOP shape (Migrator runs ids > ledger max): a DB at
# max 50 = OrchestrationV2 would run new id 51 = OrchestrationV2 again, re-running
# the entire V2 base schema -> "table ... already exists" -> backend crash-loop and
# the app launches with NO WINDOW (the shell waits forever on backend readiness;
# the real error only appears in ~/.t3/userdata/logs/server-child.log).
#
# Verified before writing this: 051_OrchestrationV2.ts is BYTE-IDENTICAL to the
# 050_OrchestrationV2.ts we already applied, so this is renumber-only for that step.
#
# This script: (1) applies migration 50's schema (table + index, both IF NOT EXISTS),
# (2) backfills projection_thread_pull_requests from projection_threads.linked_pull_request_json,
# (3) renumbers the ledger 50 -> 51 and inserts 50 ProjectionThreadPullRequests.
#
# NOTE on the backfill: the real migration derives `host` by URL-parsing each linked
# PR (packages/shared/src/threadPullRequests.ts). That logic is not reproducible in
# plain SQL, so this script REFUSES to run if any legacy rows exist rather than
# guessing — both Macs measured 0 rows on 2026-09-10. If it ever refuses, do the
# backfill by hand (or let migration 50 run by renumbering only that row down).
#
# RUN WITH THE APP FULLY QUIT. Usage: trial-infra/fix-migration-renumber-20260910.sh
set -euo pipefail

DB="${T3_STATE_DB:-$HOME/.t3/userdata/state.sqlite}"
[[ -f "$DB" ]] || { echo "no DB at $DB"; exit 1; }
if pgrep -f 'Contents/MacOS/T3' >/dev/null 2>&1; then
  echo "ERROR: quit T3 Code (Alpha) first." >&2; exit 1
fi

# Applicability guard: only the exact pre-fix ledger shape.
AT50=$(sqlite3 "$DB" "SELECT name FROM effect_sql_migrations WHERE migration_id=50")
MAXID=$(sqlite3 "$DB" "SELECT MAX(migration_id) FROM effect_sql_migrations")
if [[ "$AT50" != "OrchestrationV2" || "$MAXID" != "50" ]]; then
  echo "Ledger not in the pre-fix state (50='$AT50', max=$MAXID) — not applicable/already applied. Exiting."
  exit 0
fi

LEGACY=$(sqlite3 "$DB" "SELECT count(*) FROM projection_threads WHERE linked_pull_request_json IS NOT NULL")
if [[ "$LEGACY" != "0" ]]; then
  echo "ERROR: $LEGACY thread(s) carry linked_pull_request_json; this script cannot derive their PR host." >&2
  echo "       Back these up and migrate them by hand — see the header note." >&2
  exit 1
fi

cp "$DB" "$DB.bak-pre-renumber-$(date +%Y%m%d-%H%M%S)"
echo "== backup taken"

sqlite3 "$DB" <<'SQL'
BEGIN;
-- 050 ProjectionThreadPullRequests (schema; backfill is a no-op, guarded above)
CREATE TABLE IF NOT EXISTS projection_thread_pull_requests (
  thread_id TEXT NOT NULL,
  host TEXT NOT NULL,
  repository TEXT NOT NULL,
  number INTEGER NOT NULL,
  url TEXT NOT NULL,
  source TEXT NOT NULL,
  linked_at TEXT NOT NULL,
  snapshot_json TEXT,
  stack_json TEXT,
  PRIMARY KEY (thread_id, host, repository, number)
);
CREATE INDEX IF NOT EXISTS idx_projection_thread_pull_requests_pr
  ON projection_thread_pull_requests(host, repository, number);

-- Ledger: OrchestrationV2 50 -> 51, then record the newly applied 50.
UPDATE effect_sql_migrations SET migration_id = 51 WHERE migration_id = 50;
INSERT INTO effect_sql_migrations (migration_id, name) VALUES (50, 'ProjectionThreadPullRequests');
COMMIT;
SQL

echo "== ledger after fix:"
sqlite3 "$DB" "SELECT migration_id, name FROM effect_sql_migrations WHERE migration_id >= 48 ORDER BY migration_id"
echo "== pull-requests table present: $(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='projection_thread_pull_requests'") (expect 1)"
sqlite3 "$DB" "PRAGMA integrity_check" | head -1
echo "== done — relaunch the app."

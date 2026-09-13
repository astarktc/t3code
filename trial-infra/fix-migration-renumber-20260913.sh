#!/usr/bin/env bash
# One-shot DB fix for the 2026-09-13 upstream absorption (QM-131).
#
# Base moved 8f44bec67 -> a8cc38b95 (the V2 branch was re-rebased onto main;
# 510 new commits). Upstream's main inserted a new migration
# 051 ProjectionThreadMessageContext BEFORE the V2 base migration, pushing
# OrchestrationV2 51 -> 52.
#
# Failure mode is the CRASH-LOOP shape, with a silent-skip rider. Effect's
# Migrator runs only ids > the ledger max, so a DB at max 51 = OrchestrationV2:
#   * runs new id 52 = OrchestrationV2 again -> re-runs the entire V2 base schema
#     -> "table ... already exists" -> backend crash-loop, app launches with NO
#     WINDOW (the shell waits forever on backend readiness; the real error only
#     appears in ~/.t3/userdata/logs/server-child.log), and
#   * never runs the real new id 51 = ProjectionThreadMessageContext, so
#     projection_thread_messages.context_json would silently never exist.
#
# Verified before writing this: 051_OrchestrationV2.ts (old base) is
# BYTE-IDENTICAL to 052_OrchestrationV2.ts (new base), so this is renumber-only
# for that step. Migrations 001-050 are unchanged between the two bases.
#
# Unlike the 2026-09-10 script, migration 051 here is a plain guarded
# ALTER TABLE ADD COLUMN with no data backfill, so it IS fully reproducible in
# SQL and this script never needs to refuse.
#
# This script: (1) applies migration 51's column (guarded, matching the migration
# body), (2) renumbers the ledger 51 -> 52 and inserts 51 ProjectionThreadMessageContext.
#
# RUN WITH THE APP FULLY QUIT, BEFORE the new build's first launch.
# Usage: trial-infra/fix-migration-renumber-20260913.sh
set -euo pipefail

DB="${T3_STATE_DB:-$HOME/.t3/userdata/state.sqlite}"
[[ -f "$DB" ]] || { echo "no DB at $DB"; exit 1; }
if pgrep -f 'Contents/MacOS/T3' >/dev/null 2>&1; then
  echo "ERROR: quit T3 Code (Alpha) first." >&2; exit 1
fi

# Applicability guard: only the exact pre-fix ledger shape.
AT51=$(sqlite3 "$DB" "SELECT name FROM effect_sql_migrations WHERE migration_id=51")
MAXID=$(sqlite3 "$DB" "SELECT MAX(migration_id) FROM effect_sql_migrations")
if [[ "$AT51" != "OrchestrationV2" || "$MAXID" != "51" ]]; then
  echo "Ledger not in the pre-fix state (51='$AT51', max=$MAXID) — not applicable/already applied. Exiting."
  exit 0
fi

cp "$DB" "$DB.bak-pre-renumber-$(date +%Y%m%d-%H%M%S)"
echo "== backup taken"

# 051 ProjectionThreadMessageContext: guarded ADD COLUMN, mirroring the migration
# body (sqlite has no ADD COLUMN IF NOT EXISTS, so guard in shell).
HAS_COL=$(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('projection_thread_messages') WHERE name='context_json'")
if [[ "$HAS_COL" == "0" ]]; then
  sqlite3 "$DB" "ALTER TABLE projection_thread_messages ADD COLUMN context_json TEXT"
  echo "== added projection_thread_messages.context_json"
else
  echo "== context_json already present — skipping ALTER"
fi

sqlite3 "$DB" <<'SQL'
BEGIN;
-- Ledger: OrchestrationV2 51 -> 52, then record the newly applied 51.
UPDATE effect_sql_migrations SET migration_id = 52 WHERE migration_id = 51;
INSERT INTO effect_sql_migrations (migration_id, name) VALUES (51, 'ProjectionThreadMessageContext');
COMMIT;
SQL

echo "== ledger after fix:"
sqlite3 "$DB" "SELECT migration_id, name FROM effect_sql_migrations WHERE migration_id >= 49 ORDER BY migration_id"
echo "== context_json present: $(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('projection_thread_messages') WHERE name='context_json'") (expect 1)"
sqlite3 "$DB" "PRAGMA integrity_check" | head -1
echo "== done — relaunch the app."

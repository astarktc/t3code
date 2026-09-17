#!/usr/bin/env bash
# One-shot DB fix for the 2026-09-17 upstream absorption (QM-151).
#
# Base moved 834edb9a8 (0.0.40) -> b4cc55c24 (0.0.42); the V2 branch was
# re-rebased onto main (646 new commits). Upstream's main inserted a new
# migration 052 ProjectionThreadTitleState BEFORE the V2 base migration,
# pushing OrchestrationV2 52 -> 53.
#
# Failure mode is the CRASH-LOOP shape, with a silent-skip rider (identical to
# 2026-09-13). Effect's Migrator runs only ids > the ledger max, so a DB at
# max 52 = OrchestrationV2:
#   * runs new id 53 = OrchestrationV2 again -> re-runs the entire V2 base schema
#     -> "table ... already exists" -> backend crash-loop, app launches with NO
#     WINDOW, and
#   * never runs the real new id 52 = ProjectionThreadTitleState, so
#     projection_threads.title_state_json would silently never exist.
#
# Verified before writing this: 052_OrchestrationV2.ts (old base) is
# BYTE-IDENTICAL to 053_OrchestrationV2.ts (new base); migrations 001-051 are
# unchanged between the two bases. Migration 052 is a plain ADD COLUMN with no
# data backfill, so it IS fully reproducible in SQL and this script never needs
# to refuse.
#
# This script: (1) applies migration 52's column (guarded, matching the
# migration body), (2) renumbers the ledger 52 -> 53 and inserts
# 52 ProjectionThreadTitleState.
#
# RUN WITH THE APP FULLY QUIT, BEFORE the new build's first launch.
# Dry-run on a copy first: T3_STATE_DB=/tmp/state-copy.sqlite trial-infra/fix-migration-renumber-20260917.sh
set -euo pipefail

DB="${T3_STATE_DB:-$HOME/.t3/userdata/state.sqlite}"
[[ -f "$DB" ]] || { echo "no DB at $DB"; exit 1; }
if pgrep -f 'Contents/MacOS/T3' >/dev/null 2>&1; then
  echo "ERROR: quit T3 Code (Alpha) first." >&2; exit 1
fi

# Applicability guard: only the exact pre-fix ledger shape.
AT52=$(sqlite3 "$DB" "SELECT name FROM effect_sql_migrations WHERE migration_id=52")
MAXID=$(sqlite3 "$DB" "SELECT MAX(migration_id) FROM effect_sql_migrations")
if [[ "$AT52" != "OrchestrationV2" || "$MAXID" != "52" ]]; then
  echo "Ledger not in the pre-fix state (52='$AT52', max=$MAXID) — not applicable/already applied. Exiting."
  exit 0
fi

cp "$DB" "$DB.bak-pre-renumber-$(date +%Y%m%d-%H%M%S)"
echo "== backup taken"

# 052 ProjectionThreadTitleState: guarded ADD COLUMN, mirroring the migration
# body (sqlite has no ADD COLUMN IF NOT EXISTS, so guard in shell).
HAS_COL=$(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('projection_threads') WHERE name='title_state_json'")
if [[ "$HAS_COL" == "0" ]]; then
  sqlite3 "$DB" "ALTER TABLE projection_threads ADD COLUMN title_state_json TEXT"
  echo "== added projection_threads.title_state_json"
else
  echo "== title_state_json already present — skipping ALTER"
fi

sqlite3 "$DB" <<'SQL'
BEGIN;
-- Ledger: OrchestrationV2 52 -> 53, then record the newly applied 52.
UPDATE effect_sql_migrations SET migration_id = 53 WHERE migration_id = 52;
INSERT INTO effect_sql_migrations (migration_id, name) VALUES (52, 'ProjectionThreadTitleState');
COMMIT;
SQL

echo "== ledger after fix:"
sqlite3 "$DB" "SELECT migration_id, name FROM effect_sql_migrations WHERE migration_id >= 50 ORDER BY migration_id"
echo "== title_state_json present: $(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('projection_threads') WHERE name='title_state_json'") (expect 1)"
sqlite3 "$DB" "PRAGMA integrity_check" | head -1
echo "== done — relaunch the app."

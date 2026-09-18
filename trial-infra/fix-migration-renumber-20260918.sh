#!/usr/bin/env bash
# One-shot DB fix for the 2026-09-18 upstream absorption (QM-156, absorption #8).
#
# Base moved b4cc55c24 (0.0.42) -> 7e675127e (0.0.42); the V2 branch was
# re-rebased onto main. Upstream's main inserted a new migration
# 053 PullRequestFilesViewed BEFORE the V2 base migration, pushing
# OrchestrationV2 53 -> 54.
#
# Failure mode is the CRASH-LOOP shape with a silent-skip rider (same as
# 2026-09-13 and 2026-09-17). Effect's Migrator runs only ids > the ledger max,
# so a DB at max 53 = OrchestrationV2:
#   * runs new id 54 = OrchestrationV2 again -> re-runs the entire V2 base schema
#     -> "table ... already exists" -> backend crash-loop, app launches with NO
#     WINDOW, and
#   * never runs the real new id 53 = PullRequestFilesViewed, so the
#     pull_request_files_viewed table would silently never exist.
#
# Verified before writing this: 053_OrchestrationV2.ts (old base) is
# BYTE-IDENTICAL to 054_OrchestrationV2.ts (new base); migrations 001-052 are
# unchanged between the two bases. Migration 053 is a plain
# CREATE TABLE IF NOT EXISTS with no data backfill, so it IS fully reproducible
# in SQL and this script never needs to refuse.
#
# This script: (1) creates migration 53's table (guarded, matching the
# migration body), (2) renumbers the ledger 53 -> 54 and inserts
# 53 PullRequestFilesViewed.
#
# RUN WITH THE APP FULLY QUIT, BEFORE the new build's first launch.
# Dry-run on a copy first: T3_STATE_DB=/tmp/state-copy.sqlite trial-infra/fix-migration-renumber-20260918.sh
set -euo pipefail

DB="${T3_STATE_DB:-$HOME/.t3/userdata/state.sqlite}"
[[ -f "$DB" ]] || { echo "no DB at $DB"; exit 1; }
# Quit guard applies to the live DB only; a dry-run on a copy may run while the app is up.
if [[ "$DB" == "$HOME/.t3/userdata/state.sqlite" ]] && pgrep -f 'Contents/MacOS/T3' >/dev/null 2>&1; then
  echo "ERROR: quit T3 Code (Alpha) first." >&2; exit 1
fi

# Applicability guard: only the exact pre-fix ledger shape.
AT53=$(sqlite3 "$DB" "SELECT name FROM effect_sql_migrations WHERE migration_id=53")
MAXID=$(sqlite3 "$DB" "SELECT MAX(migration_id) FROM effect_sql_migrations")
if [[ "$AT53" != "OrchestrationV2" || "$MAXID" != "53" ]]; then
  echo "Ledger not in the pre-fix state (53='$AT53', max=$MAXID) — not applicable/already applied. Exiting."
  exit 0
fi

cp "$DB" "$DB.bak-pre-renumber-$(date +%Y%m%d-%H%M%S)"
echo "== backup taken"

# 053 PullRequestFilesViewed: mirrors the migration body verbatim.
sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS pull_request_files_viewed (
  provider TEXT NOT NULL,
  host TEXT NOT NULL,
  repository TEXT NOT NULL,
  number INTEGER NOT NULL,
  viewer TEXT NOT NULL,
  path TEXT NOT NULL,
  revision TEXT,
  viewed_at TEXT NOT NULL,
  PRIMARY KEY (provider, host, repository, number, viewer, path)
) WITHOUT ROWID;
SQL
echo "== pull_request_files_viewed ensured"

sqlite3 "$DB" <<'SQL'
BEGIN;
-- Ledger: OrchestrationV2 53 -> 54, then record the newly applied 53.
UPDATE effect_sql_migrations SET migration_id = 54 WHERE migration_id = 53;
INSERT INTO effect_sql_migrations (migration_id, name) VALUES (53, 'PullRequestFilesViewed');
COMMIT;
SQL

echo "== ledger after fix:"
sqlite3 "$DB" "SELECT migration_id, name FROM effect_sql_migrations WHERE migration_id >= 50 ORDER BY migration_id"
echo "== pull_request_files_viewed present: $(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='pull_request_files_viewed'") (expect 1)"
sqlite3 "$DB" "PRAGMA integrity_check" | head -1
echo "== done — relaunch the app."

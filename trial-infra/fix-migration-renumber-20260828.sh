#!/usr/bin/env bash
# One-shot DB fix for the 2026-08-28 upstream force-push of the #7211 stack (QM-79).
#
# Upstream inserted 3 new migrations (41 AuthSessionClientConnection,
# 42 ProjectionThreadLinkedPullRequest, 43 ProjectionThreadsUnsettledAt) BEFORE
# the OrchestrationV2 block, shifting our applied 41-49 to 44-52. A DB that ran
# the old numbering crash-loops the backend on "52_LegacyV1ImportState failed:
# table orchestration_v2_legacy_imports already exists" (window never opens).
#
# This script: (1) applies the three new migrations' ALTERs (idempotent-guarded),
# (2) renumbers the effect_sql_migrations ledger 41-49 -> 44-52, (3) inserts
# ledger rows 41-43. Verified: the 9 shifted migrations are byte-identical
# between old head bdfd4eca2 and new head a00565fbf, so renumber-only is safe.
#
# RUN WITH THE APP FULLY QUIT. Usage: trial-infra/fix-migration-renumber-20260828.sh
set -euo pipefail

DB="$HOME/.t3/userdata/state.sqlite"
[[ -f "$DB" ]] || { echo "no DB at $DB"; exit 1; }
if pgrep -f 'T3 Code (Alpha).app' >/dev/null 2>&1 || pgrep -f 'T3.*Alpha.*Contents/MacOS' >/dev/null 2>&1; then
  echo "ERROR: quit T3 Code (Alpha) first." >&2; exit 1
fi

# Idempotence / applicability guard: only run against the old ledger state.
AT49=$(sqlite3 "$DB" "SELECT name FROM effect_sql_migrations WHERE migration_id=49")
if [[ "$AT49" != "LegacyV1ImportState" ]]; then
  echo "Ledger row 49 is '$AT49' (not LegacyV1ImportState) — fix not applicable/already applied. Exiting."
  exit 0
fi

cp "$DB" "$DB.bak-pre-renumber-$(date +%Y%m%d-%H%M%S)"
echo "== backup taken"

add_col() { # table column
  if ! sqlite3 "$DB" "SELECT 1 FROM pragma_table_info('$1') WHERE name='$2'" | grep -q 1; then
    sqlite3 "$DB" "ALTER TABLE $1 ADD COLUMN $2 TEXT"
    echo "== added $1.$2"
  fi
}
add_col auth_sessions client_surface
add_col auth_sessions client_app_version
add_col projection_threads linked_pull_request_json
add_col projection_threads unsettled_at

sqlite3 "$DB" <<'SQL'
BEGIN;
UPDATE effect_sql_migrations SET migration_id = migration_id + 1000 WHERE migration_id >= 41;
UPDATE effect_sql_migrations SET migration_id = migration_id - 997 WHERE migration_id >= 1000;
INSERT INTO effect_sql_migrations (migration_id, name) VALUES
  (41, 'AuthSessionClientConnection'),
  (42, 'ProjectionThreadLinkedPullRequest'),
  (43, 'ProjectionThreadsUnsettledAt');
COMMIT;
SQL

echo "== ledger after fix:"
sqlite3 "$DB" "SELECT migration_id, name FROM effect_sql_migrations WHERE migration_id >= 41 ORDER BY migration_id"
sqlite3 "$DB" "PRAGMA integrity_check" | head -1
echo "== done — relaunch the app."

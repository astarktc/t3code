#!/usr/bin/env bash
# One-shot DB fix for the 2026-09-09 upstream force-push of the #7211 stack
# (QM-122; base 727d4f6a0 / 0.0.37 -> 4689317a4 / 0.0.40).
#
# Upstream CONSOLIDATED the nine OrchestrationV2 migrations (old ids 44-52) into
# a single migration 50 "OrchestrationV2" and inserted six new main-line
# migrations at 44-49 (ClearAutomaticProjectModelDefaults, ProjectionProjectsAutoPull,
# RepairAutomaticSettlementTimestamps, ProjectionProjectIcon,
# ProjectionThreadBranchPullRequest, ProjectionThreadsActiveOrderKey). The
# consolidated migration also gained three new index-only steps
# (ApplicationEventSequenceIndexes, RecoveryIndexes, ShellIndexes).
#
# Failure mode this time is SILENT, not a crash-loop: Effect's Migrator runs only
# ids > max(ledger). A DB at the old numbering has max 52 > new max 50, so the new
# build runs NOTHING -> the 4 new columns and 9 new indexes never land, and the
# app fails at runtime the first time a query touches them.
#
# This script: (1) applies migrations 44-49 verbatim (the ALTERs idempotent-guarded,
# the two data repairs are re-runnable no-ops once applied), (2) creates the 9 new
# indexes (IF NOT EXISTS), (3) rewrites the ledger: rows 44-52 -> 44-49 (new names)
# + 50 OrchestrationV2. Verified: the nine old V2 migration bodies are content-
# identical to the new sub-steps (comment-only diffs), so no V2 SQL is re-run.
#
# RUN WITH THE APP FULLY QUIT. Usage: trial-infra/fix-migration-consolidation-20260909.sh
set -euo pipefail

DB="${T3_STATE_DB:-$HOME/.t3/userdata/state.sqlite}"
[[ -f "$DB" ]] || { echo "no DB at $DB"; exit 1; }
if pgrep -f 'T3 Code (Alpha).app' >/dev/null 2>&1 || pgrep -f 'T3.*Alpha.*Contents/MacOS' >/dev/null 2>&1; then
  echo "ERROR: quit T3 Code (Alpha) first." >&2; exit 1
fi

# Applicability guard: only the exact pre-fix ledger shape (old V2 block at 44-52).
AT44=$(sqlite3 "$DB" "SELECT name FROM effect_sql_migrations WHERE migration_id=44")
AT52=$(sqlite3 "$DB" "SELECT name FROM effect_sql_migrations WHERE migration_id=52")
MAXID=$(sqlite3 "$DB" "SELECT MAX(migration_id) FROM effect_sql_migrations")
if [[ "$AT44" != "OrchestrationV2" || "$AT52" != "LegacyV1ImportState" || "$MAXID" != "52" ]]; then
  echo "Ledger is not in the pre-fix state (44='$AT44', 52='$AT52', max=$MAXID) — not applicable/already applied. Exiting."
  exit 0
fi

cp "$DB" "$DB.bak-pre-consolidation-$(date +%Y%m%d-%H%M%S)"
echo "== backup taken"

add_col() { # table column decl
  if ! sqlite3 "$DB" "SELECT 1 FROM pragma_table_info('$1') WHERE name='$2'" | grep -q 1; then
    sqlite3 "$DB" "ALTER TABLE $1 ADD COLUMN $2 $3"
    echo "== added $1.$2"
  fi
}

sqlite3 "$DB" <<'SQL'
BEGIN;
-- 044 ClearAutomaticProjectModelDefaults (verbatim)
WITH automatically_seeded_projects AS (
  SELECT created.stream_id AS project_id
  FROM orchestration_events AS created
  WHERE created.aggregate_kind = 'project'
    AND created.event_type = 'project.created'
    AND json_type(created.payload_json, '$.defaultModelSelection') IS NOT NULL
    AND json_type(created.payload_json, '$.defaultModelSelection') <> 'null'
    AND NOT EXISTS (
      SELECT 1
      FROM orchestration_events AS configured
      WHERE configured.aggregate_kind = 'project'
        AND configured.stream_id = created.stream_id
        AND configured.event_type = 'project.meta-updated'
        AND json_type(configured.payload_json, '$.defaultModelSelection') IS NOT NULL
    )
)
UPDATE projection_projects
SET default_model_selection_json = NULL
WHERE project_id IN (SELECT project_id FROM automatically_seeded_projects);

UPDATE orchestration_events AS created
SET payload_json = json_set(created.payload_json, '$.defaultModelSelection', json('null'))
WHERE created.aggregate_kind = 'project'
  AND created.event_type = 'project.created'
  AND json_type(created.payload_json, '$.defaultModelSelection') IS NOT NULL
  AND json_type(created.payload_json, '$.defaultModelSelection') <> 'null'
  AND NOT EXISTS (
    SELECT 1
    FROM orchestration_events AS configured
    WHERE configured.aggregate_kind = 'project'
      AND configured.stream_id = created.stream_id
      AND configured.event_type = 'project.meta-updated'
      AND json_type(configured.payload_json, '$.defaultModelSelection') IS NOT NULL
  );
COMMIT;
SQL
echo "== 044 applied"

add_col projection_projects auto_pull "INTEGER NOT NULL DEFAULT 0"   # 045

sqlite3 "$DB" <<'SQL'
BEGIN;
-- 046 RepairAutomaticSettlementTimestamps (verbatim)
WITH activity_timestamps AS (
  SELECT thread_id, created_at AS activity_at FROM projection_thread_messages WHERE role = 'user'
  UNION ALL SELECT thread_id, requested_at FROM projection_turns
  UNION ALL SELECT thread_id, started_at FROM projection_turns WHERE started_at IS NOT NULL
  UNION ALL SELECT thread_id, completed_at FROM projection_turns WHERE completed_at IS NOT NULL
),
automatic_settlements AS (
  SELECT stream_id AS thread_id, occurred_at,
         json_extract(payload_json, '$.settledAt') AS settled_at
  FROM orchestration_events
  WHERE aggregate_kind = 'thread'
    AND event_type = 'thread.settled'
    AND actor_kind = 'server'
    AND command_id LIKE 'server:auto-settle:%'
    AND json_type(payload_json, '$.settledAt') = 'text'
    AND json_extract(payload_json, '$.settledAt') = occurred_at
)
UPDATE projection_threads AS thread
SET settled_at = (
  SELECT COALESCE(
    (
      SELECT activity.activity_at
      FROM activity_timestamps AS activity
      WHERE activity.thread_id = thread.thread_id
        AND julianday(activity.activity_at) IS NOT NULL
        AND julianday(activity.activity_at) <= julianday(automatic.occurred_at)
      ORDER BY julianday(activity.activity_at) DESC
      LIMIT 1
    ),
    thread.created_at
  )
  FROM automatic_settlements AS automatic
  WHERE automatic.thread_id = thread.thread_id
    AND automatic.settled_at = thread.settled_at
  LIMIT 1
)
WHERE thread.settled_override = 'settled'
  AND EXISTS (
    SELECT 1 FROM automatic_settlements AS automatic
    WHERE automatic.thread_id = thread.thread_id
      AND automatic.settled_at = thread.settled_at
  );
COMMIT;
SQL
echo "== 046 applied"

add_col projection_projects project_icon_json TEXT           # 047
add_col projection_threads branch_pull_request_json TEXT     # 048
add_col projection_threads active_order_key TEXT             # 049

sqlite3 "$DB" <<'SQL'
BEGIN;
-- 050 OrchestrationV2: the three sub-steps that did not exist in the old base.
-- ApplicationEventSequenceIndexes
CREATE INDEX IF NOT EXISTS idx_orchestration_events_application_high_water
  ON orchestration_events(sequence)
  WHERE aggregate_kind = 'project' OR (application_event_version = 2 AND aggregate_kind = 'thread');
CREATE INDEX IF NOT EXISTS idx_orchestration_events_agent_stream_sequence
  ON orchestration_events(stream_id, sequence)
  WHERE application_event_version = 2 AND aggregate_kind = 'thread';
-- RecoveryIndexes
CREATE INDEX IF NOT EXISTS orchestration_events_v2_created_threads_idx
  ON orchestration_events(stream_id)
  WHERE application_event_version = 2 AND aggregate_kind = 'thread' AND event_type = 'thread.created';
CREATE INDEX IF NOT EXISTS orchestration_v2_projection_runs_recovery_idx
  ON orchestration_v2_projection_runs(status, thread_id)
  WHERE status IN ('queued', 'preparing', 'starting', 'running', 'waiting');
CREATE INDEX IF NOT EXISTS orchestration_v2_projection_requests_recovery_idx
  ON orchestration_v2_projection_runtime_requests(thread_id)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS orchestration_v2_projection_turn_items_recovery_idx
  ON orchestration_v2_projection_turn_items(thread_id)
  WHERE type IN ('command_execution', 'dynamic_tool', 'subagent')
    AND status IN ('pending', 'running', 'waiting');
-- ShellIndexes
CREATE INDEX IF NOT EXISTS orchestration_v2_projection_turn_items_thread_run_idx
  ON orchestration_v2_projection_turn_items(thread_id, run_id);
CREATE INDEX IF NOT EXISTS orchestration_v2_projection_turn_items_shell_pending_idx
  ON orchestration_v2_projection_turn_items(thread_id, run_id)
  WHERE type IN ('command_execution', 'dynamic_tool', 'subagent')
    AND status NOT IN ('completed', 'interrupted', 'failed', 'cancelled');
CREATE INDEX IF NOT EXISTS orchestration_v2_projection_messages_latest_user_idx
  ON orchestration_v2_projection_messages(thread_id, updated_at DESC, message_id DESC)
  WHERE role = 'user';

-- Ledger rewrite: old V2 block 44-52 -> new main 44-49 + consolidated 50.
DELETE FROM effect_sql_migrations WHERE migration_id BETWEEN 44 AND 52;
INSERT INTO effect_sql_migrations (migration_id, name) VALUES
  (44, 'ClearAutomaticProjectModelDefaults'),
  (45, 'ProjectionProjectsAutoPull'),
  (46, 'RepairAutomaticSettlementTimestamps'),
  (47, 'ProjectionProjectIcon'),
  (48, 'ProjectionThreadBranchPullRequest'),
  (49, 'ProjectionThreadsActiveOrderKey'),
  (50, 'OrchestrationV2');
COMMIT;
SQL
echo "== indexes + ledger rewritten"

echo "== ledger after fix:"
sqlite3 "$DB" "SELECT migration_id, name FROM effect_sql_migrations WHERE migration_id >= 43 ORDER BY migration_id"
echo "== new columns: $(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('projection_projects') WHERE name IN ('auto_pull','project_icon_json')") + $(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('projection_threads') WHERE name IN ('branch_pull_request_json','active_order_key')") (expect 2 + 2)"
echo "== new indexes: $(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_orchestration_events_application_high_water','idx_orchestration_events_agent_stream_sequence','orchestration_events_v2_created_threads_idx','orchestration_v2_projection_runs_recovery_idx','orchestration_v2_projection_requests_recovery_idx','orchestration_v2_projection_turn_items_recovery_idx','orchestration_v2_projection_turn_items_thread_run_idx','orchestration_v2_projection_turn_items_shell_pending_idx','orchestration_v2_projection_messages_latest_user_idx')") (expect 9)"
sqlite3 "$DB" "PRAGMA integrity_check" | head -1
echo "== done — relaunch the app."

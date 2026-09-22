#!/usr/bin/env bash
# t3code fork deploy — the ONE installer for both Macs (Quartermaster QM-134).
#
# Every absorption before 2026-09-14 hand-wrote a throwaway install script into
# /tmp, and they drifted: the sunlnk bug (2026-09-13) and the launchd quit-loop +
# vacuous pgrep guard (2026-09-14) were all dispatch bugs, not build bugs. This
# script is the committed, tested path. Do not improvise another one.
#
# Usage:
#   trial-infra/deploy.sh --local [--zip <path>] [--detach] [--force] [--expect-asar <hash16>]
#   trial-infra/deploy.sh --remote <ssh-host> [--zip <path>] [--force]
#
#   --local    install onto THIS machine and verify it came back up.
#   --remote   copy the artifact + this script to <ssh-host> and run --local there.
#   --detach   re-exec in the background, immune to the app (and the session that
#              dispatched this) going away. REQUIRED when dispatching from inside
#              a Pi thread hosted by T3 Code itself, because step 1 quits the app.
#   --force    proceed even if the pre-flight finds active orchestration runs.
#
# NEVER dispatch this with `launchctl submit`: submit implies KeepAlive, so launchd
# re-runs the script every time it exits and step 1 ("quit the app") turns into an
# endless quit loop that reads exactly like a crash-on-startup. Use --detach.
# macOS has no `setsid` either (`nohup setsid …` exits 127 and installs nothing).

set -uo pipefail

APP_NAME="T3 Code (Alpha).app"
APP_PROC="T3 Code (Alpha)"
PORT=3773
# The V2 orchestrator lives in statev2.sqlite (upstream 15769fa10e, 2026-09-14);
# state.sqlite is the frozen V1 file. Every guard and verify below must read the
# live one — reading V1 made the active-run pre-flight vacuous and the ledger
# readout stale for four deploys (hazard #8, 2026-09-22).
DB="$HOME/.t3/userdata/statev2.sqlite"
[[ -f "$DB" ]] || DB="$HOME/.t3/userdata/state.sqlite"
# pgrep -f takes an ERE: the bundle's literal parentheses MUST be escaped or the
# pattern matches nothing and every "is it running?" check silently answers "no".
# The main Electron process is INVISIBLE to pgrep on macOS (both -f and -x; only
# the Helper children match), so any pgrep-based guard is vacuous for the app
# proper (hazard #6, 2026-09-17). Match the executable path from `ps -o comm`.
APP_EXE="/Applications/$APP_NAME/Contents/MacOS/$APP_PROC"

MODE="" HOST="" ZIP="" DETACH=0 FORCE=0 EXPECT_ASAR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)  MODE=local ;;
    --remote) MODE=remote; HOST="${2:?--remote needs an ssh host}"; shift ;;
    --zip)    ZIP="${2:?--zip needs a path}"; shift ;;
    --detach) DETACH=1 ;;
    --force)  FORCE=1 ;;
    --expect-asar) EXPECT_ASAR="${2:?--expect-asar needs a hash}"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$MODE" ]] || { echo "ERROR: pass --local or --remote <host>" >&2; exit 2; }

log() { printf '== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

app_pids() { ps -axo pid=,comm= | awk -v p="$APP_EXE" 'index($0, p) { print $1 }'; }
app_running() { [[ -n "$(app_pids)" ]]; }

asar_hash() { shasum -a 256 "$1" | cut -c1-16; }

# ---------------------------------------------------------------- artifact ----
resolve_zip() {
  if [[ -n "$ZIP" ]]; then
    [[ -f "$ZIP" ]] || die "no such artifact: $ZIP"
  else
    local root
    root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null) \
      || die "not in the fork repo; pass --zip <path>"
    ZIP=$(ls -t "$root"/release/T3-Code-*-arm64.zip 2>/dev/null | head -1) \
      || true
    [[ -n "$ZIP" ]] || die "no release/T3-Code-*-arm64.zip found; build first (update.sh)"
  fi
  log "artifact: $ZIP"
}

# ------------------------------------------------------------------ remote ----
if [[ "$MODE" == remote ]]; then
  resolve_zip
  EX=$(mktemp -d /tmp/t3code-verify.XXXXXX)
  ditto -x -k "$ZIP" "$EX" || die "cannot extract artifact"
  [[ -e "$EX/$APP_NAME/Contents/Resources/app-update.yml" ]] \
    && die "app-update.yml present in artifact — auto-update would be live"
  LOCAL_ASAR=$(asar_hash "$EX/$APP_NAME/Contents/Resources/app.asar")
  rm -rf "$EX"
  log "artifact asar: $LOCAL_ASAR"

  ssh -o ConnectTimeout=10 "$HOST" true || die "cannot reach $HOST over ssh"
  log "copying artifact to $HOST"
  scp -q "$ZIP" "$HOST:/tmp/$(basename "$ZIP")" || die "scp of artifact failed"
  scp -q "${BASH_SOURCE[0]}" "$HOST:/tmp/t3-deploy.sh" || die "scp of deploy.sh failed"

  # No --detach: over ssh nothing local hosts the app, so run attached and keep
  # the remote machine's verification output in this terminal.
  # Quoting is written out by hand: macOS ships bash 3.2, which has no ${a[*]@Q}.
  REMOTE_FORCE=""
  [[ $FORCE -eq 1 ]] && REMOTE_FORCE="--force"
  ssh "$HOST" "bash /tmp/t3-deploy.sh --local --zip '/tmp/$(basename "$ZIP")' --expect-asar '$LOCAL_ASAR' $REMOTE_FORCE"
  RC=$?
  ssh "$HOST" "rm -f '/tmp/$(basename "$ZIP")' /tmp/t3-deploy.sh" >/dev/null 2>&1 || true
  exit $RC
fi

# ------------------------------------------------------------------- local ----
# Self-detach. macOS has no setsid(1), but perl's POSIX::setsid works: the re-exec
# gets its OWN session + process group. nohup alone is NOT enough when dispatched
# from a Pi bash tool inside T3 Code — the tool kills its process group when the
# app quits (step 4) aborts the call, taking a merely-nohup'd child with it
# (hazard #6, 2026-09-17). Guarded by an env flag so the body runs exactly once.
if [[ $DETACH -eq 1 && "${T3_DEPLOY_DETACHED:-}" != "1" ]]; then
  LOG="/tmp/t3-deploy-$(date +%Y%m%d-%H%M%S).log"
  resolve_zip
  RE_ARGS=(--local --zip "$ZIP")
  [[ $FORCE -eq 1 ]] && RE_ARGS[${#RE_ARGS[@]}]="--force"
  if [[ -n "$EXPECT_ASAR" ]]; then
    RE_ARGS[${#RE_ARGS[@]}]="--expect-asar"; RE_ARGS[${#RE_ARGS[@]}]="$EXPECT_ASAR"
  fi
  T3_DEPLOY_LOG="$LOG" T3_DEPLOY_DETACHED=1 nohup perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- \
    "${BASH_SOURCE[0]}" "${RE_ARGS[@]}" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "dispatched detached (pid $!)"
  echo "log: $LOG"
  echo "watch: tail -f $LOG"
  exit 0
fi

# Always leave a durable record: this script quits the app that may be hosting the
# session watching it, and an interrupted terminal must not take the evidence with
# it. (2026-09-14: a --local run's output was lost to an aborted tool call.)
# Ignore SIGPIPE before forking tee: if the terminal/ssh channel watching this
# run goes away (2026-09-17: an aborted --remote tool call), BSD tee must NOT
# die on its stdout write — with SIGPIPE ignored it warns and keeps writing the
# log file, and the script keeps going to a real verdict.
trap '' PIPE
if [[ "${T3_DEPLOY_LOGGING:-}" != "1" ]]; then
  export T3_DEPLOY_LOGGING=1
  RUN_LOG="${T3_DEPLOY_LOG:-/tmp/t3-deploy-$(date +%Y%m%d-%H%M%S).log}"
  echo "== logging to $RUN_LOG"
  exec > >(tee -a "$RUN_LOG") 2>&1
fi

# Every probe is bounded. A backend that has bound the port but is still
# starting can accept a connection and never answer it; an unbounded curl then
# blocks the readiness loop forever (2026-09-17: 6 min hang on the work Mac,
# only unstuck by killing the curl by hand).
probe() { curl -s --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/.well-known/t3/environment" || true; }

resolve_zip

# 1. Pre-flight: don't kill live orchestration work.
if [[ -f "$DB" ]]; then
  ACTIVE=$(sqlite3 "$DB" \
    "select count(*) from orchestration_v2_projection_runs
      where status in ('running','queued','starting','preparing','waiting')" 2>/dev/null || echo 0)
  # A Pi thread dispatching this deploy counts itself: --detach (only ever used
  # from inside the app) tolerates exactly that one run. Anything more is
  # somebody's real work. This branch was unreachable while the guard read the
  # frozen V1 DB (hazard #8) — it first fired on 2026-09-22.
  # The detached body re-execs WITHOUT --detach (it carries T3_DEPLOY_DETACHED=1
  # instead), so key the allowance on either signal — the first live run of this
  # branch died on exactly that gap.
  ALLOWED=0; [[ $DETACH -eq 1 || "${T3_DEPLOY_DETACHED:-}" == "1" ]] && ALLOWED=1
  if [[ "${ACTIVE:-0}" -gt $ALLOWED ]]; then
    if [[ $FORCE -eq 1 ]]; then
      log "PRE-FLIGHT: $ACTIVE active run(s) — proceeding (--force)"
    else
      die "$ACTIVE active orchestration run(s); finish them or pass --force"
    fi
  elif [[ "${ACTIVE:-0}" -eq 1 ]]; then
    log "pre-flight: 1 active run = this dispatching thread ✓"
  else
    log "pre-flight: 0 active runs ✓"
  fi
fi

# 2. Verify the artifact before touching the installed bundle.
EX=$(mktemp -d /tmp/t3code-install.XXXXXX)
trap 'rm -rf "$EX"' EXIT
ditto -x -k "$ZIP" "$EX" || die "cannot extract artifact"
[[ -d "$EX/$APP_NAME" ]] || die "no $APP_NAME inside the artifact"
[[ -e "$EX/$APP_NAME/Contents/Resources/app-update.yml" ]] \
  && die "app-update.yml present — auto-update would be live"
NEW_ASAR=$(asar_hash "$EX/$APP_NAME/Contents/Resources/app.asar")
if [[ -n "$EXPECT_ASAR" && "$NEW_ASAR" != "$EXPECT_ASAR" ]]; then
  die "asar mismatch: artifact $NEW_ASAR != expected $EXPECT_ASAR"
fi
log "artifact verified (asar $NEW_ASAR, no update feed)"

# 3. Migration guard: a ledger ABOVE the code's max means Effect's Migrator will
#    silently skip every inserted migration (the consolidation shape). We cannot
#    read ids out of the bundled JS cheaply, so this only reports the ledger and
#    leaves the id comparison to update.sh's rebase-time tripwires.
if [[ -f "$DB" ]]; then
  log "DB ledger: $(sqlite3 "$DB" "select migration_id||'='||name from effect_sql_migrations order by migration_id desc limit 1" 2>/dev/null)"
  log "reminder: if update.sh warned about renumbered/removed migrations, run the"
  log "          matching trial-infra/fix-migration-*.sh NOW — before first launch."
fi

# 4. Quit the app and PROVE it quit (ps-based — see APP_EXE).
if app_running; then
  log "quitting $APP_PROC"
  osascript -e "tell application \"$APP_PROC\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 45); do app_running || break; sleep 1; done
  if app_running; then
    log "still running after 45s — sending TERM"
    app_pids | xargs kill 2>/dev/null || true
    for _ in $(seq 1 15); do app_running || break; sleep 1; done
  fi
  app_running && die "app would not quit; refusing to overwrite a live bundle"
  log "app quit ✓"
else
  log "app not running ✓"
fi

# 5. Install. /Applications is sunlnk: the bundle DIRECTORY cannot be unlinked,
#    so `rm -rf` on it guts the bundle and then fails. Clear contents, fill in place.
TARGET="/Applications/$APP_NAME"
if [[ -d "$TARGET" ]]; then
  find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} + \
    || die "could not clear existing bundle contents"
fi
mkdir -p "$TARGET"
ditto "$EX/$APP_NAME" "$TARGET" || die "ditto into $TARGET failed — bundle is now INCOMPLETE, re-run this script"
INSTALLED=$(asar_hash "$TARGET/Contents/Resources/app.asar")
[[ "$INSTALLED" == "$NEW_ASAR" ]] || die "installed asar $INSTALLED != artifact $NEW_ASAR"
log "installed ✓ (asar $INSTALLED)"

# 6. Relaunch and verify for real.
#    Hazard #7 (2026-09-18, cause proven 2026-09-19): `open -a` passes the caller's
#    ENVIRONMENT to the launched app (man open: "just as if you had launched the
#    application directly through its full path"). A Pi thread hosted by T3 Code runs
#    with ELECTRON_RUN_AS_NODE=1 (T3 spawns Pi under its bundled Electron-as-node), so a
#    --detach install dispatched from inside T3 relaunched the app as a bare Node
#    process with no script: it exited in ~30 ms with no desktop.startup span, and
#    `open` still returned 0. Scrub every ELECTRON_*/T3_* variable before `open`.
#    The exit code is not evidence; a process appearing AND staying is. Poll for it,
#    retry `open` once, and fail with a message distinct from the migration/no-window
#    hazard.
launch_and_wait() {
  local v; local -a scrub=() names=()
  for v in $(env | grep -oE '^(ELECTRON_[A-Z0-9_]*|T3_[A-Z0-9_]*)='); do
    scrub+=(-u "${v%=}"); names+=("${v%=}")
  done
  [[ ${#names[@]} -gt 0 ]] && log "scrubbing inherited launch env (hazard #7): ${names[*]}"
  env "${scrub[@]}" open -a "$TARGET" || return 1
  for _ in $(seq 1 10); do app_running && return 0; sleep 1; done
  return 1
}
if ! launch_and_wait; then
  log "open -a started no process within 10s — retrying open once"
  launch_and_wait || die "app did not launch after two 'open -a' attempts (install is complete, asar $INSTALLED) — open it by hand and re-verify: curl http://127.0.0.1:$PORT/.well-known/t3/environment"
fi
log "app process up ✓"
#    Wall-clock budget, not iteration count: a connection-refused probe returns
#    instantly, so a 45-iteration loop burned out in 91 s on 2026-09-18.
CODE=000
READY_DEADLINE=$((SECONDS + 300))
while (( SECONDS < READY_DEADLINE )); do
  CODE=$(probe)
  [[ "$CODE" == "200" ]] && break
  app_running || { log "app process disappeared while waiting for readiness"; break; }
  sleep 2
done
if [[ "$CODE" != "200" ]]; then
  echo "ERROR: backend never became ready (readiness=$CODE) within 300s" >&2
  echo "       This is the no-window hazard. Look at TODAY's traces:" >&2
  echo "       ~/.t3/userdata/logs/server.trace.ndjson and desktop.trace.ndjson" >&2
  echo "       (server-child.log is NOT written by trace-era builds — its newest" >&2
  echo "        lines are from an old incident and will mislead you)" >&2
  ls -lt "$HOME/.t3/userdata/logs/" 2>/dev/null | head -5 >&2
  exit 1
fi
log "readiness 200 ✓"
curl -s --connect-timeout 2 --max-time 5 "http://127.0.0.1:$PORT/.well-known/t3/environment" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("== serverVersion:", d["serverVersion"], "| protocol:", d.get("orchestrationProtocolVersion"))' 2>/dev/null

# 7. Post-install state checks.
if [[ -f "$DB" ]]; then
  sqlite3 "$DB" "select '== migration '||migration_id||'='||name from effect_sql_migrations order by migration_id desc limit 2" 2>/dev/null
  log "integrity_check: $(sqlite3 "$DB" 'PRAGMA integrity_check' 2>/dev/null | head -1)"
fi

# 8. A graceful quit shortly after this point means something is TELLING the app
#    to quit (a KeepAlive'd dispatcher), not that the build is broken.
sleep 20
if app_running && [[ "$(probe)" == "200" ]]; then
  log "stable 20s after launch ✓"
  log "DEPLOY OK on $(hostname -s) — asar $INSTALLED"
else
  echo "ERROR: app went away within 20s of a healthy launch." >&2
  echo "       Check for a dispatcher restarting this script:" >&2
  echo "         launchctl list | grep -i t3 ; pgrep -fl deploy.sh" >&2
  echo "       launchctl submit implies KeepAlive and produces exactly this." >&2
  exit 1
fi

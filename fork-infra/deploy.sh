#!/usr/bin/env bash
# T3 Code fork deploy — the ONE installer for both Macs (fork-infra/README.md).
#
# Every absorption before 2026-09-14 hand-wrote a throwaway install script into
# /tmp, and they drifted: the sunlnk bug (2026-09-13) and the launchd quit-loop +
# vacuous pgrep guard (2026-09-14) were all dispatch bugs, not build bugs. This
# script is the committed, tested path. Do not improvise another one.
#
# Usage:
#   fork-infra/deploy.sh --local [--zip <path>] [--detach] [--force] [--expect-asar <hash16>]
#   fork-infra/deploy.sh --remote <ssh-host> [--zip <path>] [--force]
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

# The app is identified by its bundle id, never by name: the bundle and executable
# names follow upstream's productName, which changed from "T3 Code (Alpha)" to
# "T3 Code (Beta)" at 0.1.0. The artifact names the new app; the installed one is
# found by bundle id, whatever its directory is called.
BUNDLE_ID="com.t3tools.t3code"
PORT=3773
# The orchestrator lives in statev2.sqlite; state.sqlite is the frozen V1 file.
# Every guard and verify below must read the live one — reading V1 makes the
# active-run pre-flight vacuous and the ledger readout stale (README hazard 7).
DB="$HOME/.t3/userdata/statev2.sqlite"
[[ -f "$DB" ]] || DB="$HOME/.t3/userdata/state.sqlite"
# The main Electron process is INVISIBLE to pgrep on macOS (both -f and -x; only
# the Helper children match), so any pgrep-based guard is vacuous for the app
# proper (README hazard 3). Match the bundle's executable directory in
# `ps -o comm` instead. APP_DIR is the installed bundle being replaced.
APP_DIR=""

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

app_pids() {
  [[ -n "$APP_DIR" ]] || return 0
  ps -axo pid=,comm= | awk -v p="$APP_DIR/Contents/MacOS/" 'index($0, p) { print $1 }'
}
app_running() { [[ -n "$(app_pids)" ]]; }

asar_hash() { shasum -a 256 "$1" | cut -c1-16; }

bundle_id_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }

# The one .app inside an extracted artifact.
artifact_app() {  # $1 = extract dir
  local apps=("$1"/*.app)
  [[ ${#apps[@]} -eq 1 && -d "${apps[0]}" ]] || die "expected one .app in the artifact, found: ${apps[*]}"
  [[ "$(bundle_id_of "${apps[0]}")" == "$BUNDLE_ID" ]] || die "the artifact's app is not $BUNDLE_ID"
  printf '%s\n' "${apps[0]}"
}

# The installed bundle: the /Applications app with our bundle id, or a T3 Code
# bundle directory with no Info.plist (a gutted install, hazard 1), whatever its
# name. Empty when nothing is installed; dies when there is more than one.
installed_bundle() {
  local app found=()
  for app in /Applications/*.app; do
    if [[ "$(bundle_id_of "$app")" == "$BUNDLE_ID" ]] \
      || [[ "$(basename "$app")" == T3\ Code*.app && ! -e "$app/Contents/Info.plist" ]]; then
      found+=("$app")
    fi
  done
  [[ ${#found[@]} -le 1 ]] || die "several installed copies of $BUNDLE_ID: ${found[*]} — keep one"
  [[ ${#found[@]} -eq 0 ]] || printf '%s\n' "${found[0]}"
}

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
  ART_APP=$(artifact_app "$EX") || exit 1
  [[ -e "$ART_APP/Contents/Resources/app-update.yml" ]] \
    && die "app-update.yml present in artifact — auto-update would be live"
  LOCAL_ASAR=$(asar_hash "$ART_APP/Contents/Resources/app.asar")
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
# (README hazard 5). Guarded by an env flag so the body runs exactly once.
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
  # somebody's real work.
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
ART_APP=$(artifact_app "$EX") || exit 1
NEW_NAME=$(basename "$ART_APP")
[[ -e "$ART_APP/Contents/Resources/app-update.yml" ]] \
  && die "app-update.yml present — auto-update would be live"
NEW_ASAR=$(asar_hash "$ART_APP/Contents/Resources/app.asar")
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
  log "          repair (fork-infra/README.md, migration hazard) NOW — before first launch."
fi

# 4. Quit the app and PROVE it quit (ps-based — see APP_DIR).
APP_DIR=$(installed_bundle) || exit 1
log "installed bundle: ${APP_DIR:-none}"
if app_running; then
  log "quitting $BUNDLE_ID"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
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

# 5. Install in place (README hazard 1). Where our user cannot write /Applications
#    itself (the work Mac: no admin rights), the bundle DIRECTORY can be neither
#    removed, renamed nor created, so `rm -rf` on it guts the bundle and then fails.
#    Only its contents are ours to replace. Rename the directory to the artifact's
#    name where /Applications allows it; otherwise the old name stays and only the
#    app inside changes.
if [[ -z "$APP_DIR" ]]; then
  TARGET="/Applications/$NEW_NAME"
elif [[ "$(basename "$APP_DIR")" == "$NEW_NAME" ]]; then
  TARGET="$APP_DIR"
elif [[ ! -e "/Applications/$NEW_NAME" ]] && mv "$APP_DIR" "/Applications/$NEW_NAME" 2>/dev/null; then
  TARGET="/Applications/$NEW_NAME"
  log "renamed $(basename "$APP_DIR") -> $NEW_NAME"
else
  TARGET="$APP_DIR"
  log "keeping the directory name $(basename "$APP_DIR") (cannot rename in /Applications here); the app inside is $NEW_NAME"
fi
APP_DIR="$TARGET"
if [[ -d "$TARGET" ]]; then
  find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} + \
    || die "could not clear existing bundle contents"
fi
mkdir -p "$TARGET"
ditto "$ART_APP" "$TARGET" || die "ditto into $TARGET failed — bundle is now INCOMPLETE, re-run this script"
INSTALLED=$(asar_hash "$TARGET/Contents/Resources/app.asar")
[[ "$INSTALLED" == "$NEW_ASAR" ]] || die "installed asar $INSTALLED != artifact $NEW_ASAR"
log "installed ✓ (asar $INSTALLED)"

# 6. Relaunch and verify for real.
#    README hazard 6: `open -a` passes the caller's
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
  [[ ${#names[@]} -gt 0 ]] && log "scrubbing inherited launch env (README hazard 6): ${names[*]}"
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

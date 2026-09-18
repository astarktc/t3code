#!/usr/bin/env bash
# Install a freshly built artifact on THIS Mac when the dispatching session lives
# INSIDE the app being replaced (a Pi thread hosted by T3 Code): quit → optional
# migration repair → deploy.sh --local. Everything runs in a NEW SESSION so the
# app quitting (which aborts the dispatching tool call and kills its process
# group) cannot take the installer with it (hazard #6).
#
# Usage:
#   trial-infra/install-from-inside.sh [--repair <fix-migration-*.sh>] [--expect-asar <hash16>] [--zip <path>]
#
# Log: /tmp/t3-install-from-inside-<ts>.log (deploy.sh writes its own /tmp/t3-deploy-*.log too).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPAIR="" EXPECT="" ZIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair) REPAIR="${2:?}"; shift ;;
    --expect-asar) EXPECT="${2:?}"; shift ;;
    --zip) ZIP="${2:?}"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "${T3_IFI_DETACHED:-}" != "1" ]]; then
  LOG="/tmp/t3-install-from-inside-$(date +%Y%m%d-%H%M%S).log"
  ARGS=()
  [[ -n "$REPAIR" ]] && ARGS+=(--repair "$REPAIR")
  [[ -n "$EXPECT" ]] && ARGS+=(--expect-asar "$EXPECT")
  [[ -n "$ZIP" ]] && ARGS+=(--zip "$ZIP")
  T3_IFI_LOG="$LOG" T3_IFI_DETACHED=1 nohup perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- \
    "${BASH_SOURCE[0]}" "${ARGS[@]}" >/dev/null 2>&1 &
  echo "dispatched in a new session (pid $!)"
  echo "log: $LOG"
  exit 0
fi

exec >>"$T3_IFI_LOG" 2>&1
APP_NAME="T3 Code (Alpha).app"; APP_PROC="T3 Code (Alpha)"
APP_EXE="/Applications/$APP_NAME/Contents/MacOS/$APP_PROC"
app_pids() { ps -axo pid=,comm= | awk -v p="$APP_EXE" 'index($0, p) { print $1 }'; }
app_running() { [[ -n "$(app_pids)" ]]; }

echo "== $(date) session $(ps -o sess= -p $$ | tr -d ' ') pgid $(ps -o pgid= -p $$ | tr -d ' ')"
if app_running; then
  echo "== quitting $APP_PROC (pids: $(app_pids | tr '\n' ' '))"
  osascript -e "tell application \"$APP_PROC\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do app_running || break; sleep 1; done
  if app_running; then echo "== still up after 60s — TERM"; app_pids | xargs kill 2>/dev/null || true; sleep 10; fi
  app_running && { echo "ERROR: app would not quit"; exit 1; }
  echo "== app quit ✓"
else
  echo "== app not running ✓"
fi

if [[ -n "$REPAIR" ]]; then
  echo "== $(date) repair: $REPAIR"
  "$REPAIR" || { echo "ERROR: repair failed"; exit 1; }
fi

echo "== $(date) deploy"
DARGS=(--local)
[[ -n "$EXPECT" ]] && DARGS+=(--expect-asar "$EXPECT")
[[ -n "$ZIP" ]] && DARGS+=(--zip "$ZIP")
"$HERE/deploy.sh" "${DARGS[@]}"
echo "== $(date) exit $?"

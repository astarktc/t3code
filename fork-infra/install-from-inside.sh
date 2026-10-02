#!/usr/bin/env bash
# Install a freshly built artifact on THIS Mac when the dispatching session lives
# INSIDE the app being replaced (a Pi thread hosted by T3 Code): quit → optional
# migration repair → deploy.sh --local. Everything runs in a NEW SESSION so the
# app quitting (which aborts the dispatching tool call and kills its process
# group) cannot take the installer with it (README hazard 5).
#
# Usage:
#   fork-infra/install-from-inside.sh [--repair <repair-script>] [--expect-asar <hash16>] [--zip <path>] [--force]
#
# The dispatching thread's own run stays recorded as active after the app quits,
# so deploy.sh gets the same one-run allowance as --detach (T3_DEPLOY_DETACHED=1).
# Queued follow-up messages of that thread count as further active runs; after
# checking they are all the dispatching thread's, pass --force.
#
# Log: /tmp/t3-install-from-inside-<ts>.log (deploy.sh writes its own /tmp/t3-deploy-*.log too).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPAIR="" EXPECT="" ZIP="" FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair) REPAIR="${2:?}"; shift ;;
    --expect-asar) EXPECT="${2:?}"; shift ;;
    --zip) ZIP="${2:?}"; shift ;;
    --force) FORCE=1 ;;
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
  [[ $FORCE -eq 1 ]] && ARGS+=(--force)
  T3_IFI_LOG="$LOG" T3_IFI_DETACHED=1 nohup perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- \
    "${BASH_SOURCE[0]}" "${ARGS[@]}" >/dev/null 2>&1 &
  echo "dispatched in a new session (pid $!)"
  echo "log: $LOG"
  exit 0
fi

exec >>"$T3_IFI_LOG" 2>&1
# Found by bundle id, as in deploy.sh: the bundle's name follows upstream's productName.
BUNDLE_ID="com.t3tools.t3code"
APP_DIR=""
for app in /Applications/*.app; do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]] \
    && { APP_DIR="$app"; break; }
done
app_pids() {
  [[ -n "$APP_DIR" ]] || return 0
  ps -axo pid=,comm= | awk -v p="$APP_DIR/Contents/MacOS/" 'index($0, p) { print $1 }'
}
app_running() { [[ -n "$(app_pids)" ]]; }

echo "== $(date) session $(ps -o sess= -p $$ | tr -d ' ') pgid $(ps -o pgid= -p $$ | tr -d ' ')"
if app_running; then
  echo "== quitting $APP_DIR (pids: $(app_pids | tr '\n' ' '))"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
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
[[ $FORCE -eq 1 ]] && DARGS+=(--force)
T3_DEPLOY_DETACHED=1 "$HERE/deploy.sh" "${DARGS[@]}"
echo "== $(date) exit $?"

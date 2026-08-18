#!/usr/bin/env bash
# t3code Pi-fork trial updater (Quartermaster QM-80)
#
# Pulls the latest upstream Pi-provider PR branch, rebases local trial patches,
# reinstalls deps, and produces an unsigned packaged macOS build with
# auto-update guaranteed OFF.
#
# Tracking layout (repo: ~/Projects/forks/t3code):
#   origin     = astarktc/t3code          (our GitHub fork; backup of trial branch)
#   upstream   = pingdotgg/t3code         (canonical upstream, reference only)
#   stienswout = StiensWout/t3code        (PR #7211 source; branch t3code/pi-provider,
#                                          which stacks on upstream PR #2829's V2 branch)
#   trial      = stienswout/t3code/pi-provider + our local patches (this script, etc.)
#
# Usage: trial-infra/update.sh [--no-build] [--install] [--no-push]
#   --no-build  fetch + rebase + pnpm install only
#   --install   after building, copy the .app into /Applications (quit the app first)
#   --no-push   skip force-pushing the rebased trial branch to origin

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Native resource-monitor needs cargo; rustup installs live in ~/.cargo/bin,
# which non-interactive shells don't have on PATH.
export PATH="$HOME/.cargo/bin:$PATH"

BRANCH=trial
REMOTE=stienswout
REMOTE_BRANCH=t3code/pi-provider
APP_NAME="T3 Code (Alpha).app"

DO_BUILD=1 DO_INSTALL=0 DO_PUSH=1
for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --install)  DO_INSTALL=1 ;;
    --no-push)  DO_PUSH=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# 1. Guard: clean worktree
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: worktree not clean — commit/stash first." >&2
  git status --short >&2
  exit 1
fi

# 2. Fetch + rebase local patches onto the moving PR branch
git fetch "$REMOTE" "$REMOTE_BRANCH"
git fetch upstream main --quiet || true   # reference only; PR branches stack on V2, not main
git checkout "$BRANCH"
BEFORE=$(git rev-parse --short HEAD)
git rebase "$REMOTE/$REMOTE_BRANCH"
AFTER=$(git rev-parse --short HEAD)
echo "== rebased $BRANCH: $BEFORE -> $AFTER (base: $(git rev-parse --short "$REMOTE/$REMOTE_BRANCH"))"

# 3. Backup the rebased branch to our fork
if [[ $DO_PUSH -eq 1 ]]; then
  git push --force-with-lease origin "$BRANCH"
fi

# 4. Reinstall deps (lockfile churns upstream daily)
pnpm install

# 5. Packaged production build, auto-update hard-disabled:
#    - unset publish-repo envs -> electron-builder gets no publish config ->
#      no app-update.yml in Resources -> updater self-disables
#      ("no update feed is configured"); builder also runs --publish never.
#    - unsigned (T3CODE_DESKTOP_SIGNED defaults false).
if [[ $DO_BUILD -eq 1 ]]; then
  env -u GITHUB_REPOSITORY -u T3CODE_DESKTOP_UPDATE_REPOSITORY \
    pnpm dist:desktop:dmg:arm64
  echo "== artifacts in release/:"
  ls -la release/ | grep -v '^total'
  APP_PATH=$(find release -maxdepth 2 -name "$APP_NAME" -type d | head -1 || true)
  if [[ -n "${APP_PATH:-}" ]]; then
    if ! [[ -e "$APP_PATH/Contents/Resources/app-update.yml" ]]; then
      echo "== auto-update check: no app-update.yml in bundle -> updater disabled ✓"
    else
      echo "WARNING: app-update.yml present in bundle — auto-update may be live!" >&2
    fi
    if [[ $DO_INSTALL -eq 1 ]]; then
      echo "== installing to /Applications (quit the app first if running)"
      rm -rf "/Applications/$APP_NAME"
      ditto "$APP_PATH" "/Applications/$APP_NAME"
      echo "== installed: /Applications/$APP_NAME (state stays in ~/.t3)"
    fi
  else
    echo "WARNING: could not locate built .app under release/" >&2
  fi
fi

echo "== done. Reminder: threads/pairing/settings live in ~/.t3 and carry over."

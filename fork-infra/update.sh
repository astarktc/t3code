#!/usr/bin/env bash
# Rebase our patch stack onto upstream and produce a packaged macOS build with
# auto-update guaranteed OFF. The operating manual is fork-infra/README.md.
#
# Layout (repo: ~/Projects/forks/t3code):
#   upstream = pingdotgg/t3code   (canonical; the base branch is upstream/main)
#   origin   = astarktc/t3code    (our public GitHub fork; backup of the branch)
#   patched  = upstream/main + our product patches + one fork-infra commit
#
# Usage: fork-infra/update.sh [--base <remote>/<branch>] [--old-base <sha>]
#                             [--no-build] [--install] [--no-push]
#   --base <ref>      upstream branch to stack on (default upstream/main). Use it
#                     only to ride a long-lived upstream feature branch.
#   --old-base <sha>  the base commit the branch sits on now. Default: the
#                     merge-base with --base, which is right whenever the base
#                     branch is never rewritten (main). Required when the branch
#                     sits on a different or force-pushed base.
#   --no-build        fetch + rebase + pnpm install only
#   --install         after building, deploy onto THIS machine via deploy.sh --local
#   --no-push         skip force-pushing the rebased branch to origin
#
# Keep the stack consolidated: commit later fork-infra edits with
#   git commit --fixup=':/^fork-infra:'
# The rebase runs with --autosquash, so they fold into the one fork-infra commit.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Native resource-monitor needs cargo; rustup installs live in ~/.cargo/bin,
# which non-interactive shells don't have on PATH.
export PATH="$HOME/.cargo/bin:$PATH"

BRANCH=patched
BASE_REF=upstream/main
APP_NAME="T3 Code (Alpha).app"

DO_BUILD=1 DO_INSTALL=0 DO_PUSH=1 OLD_BASE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)     BASE_REF="${2:?--base needs <remote>/<branch>}"; shift ;;
    --old-base) OLD_BASE_ARG="${2:?--old-base needs a sha}"; shift ;;
    --no-build) DO_BUILD=0 ;;
    --install)  DO_INSTALL=1 ;;
    --no-push)  DO_PUSH=0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
REMOTE=${BASE_REF%%/*}
REMOTE_BRANCH=${BASE_REF#*/}

# 1. Guard: clean worktree
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: worktree not clean — commit/stash first." >&2
  git status --short >&2
  exit 1
fi

# 2. Fetch + rebase exactly our commits: --onto <new base> <old base>.
#    The merge-base default cannot go stale on a fetch, because main is never
#    rewritten. A force-pushed feature base is the one case that needs
#    --old-base (the recorded sha the branch actually sits on).
git checkout "$BRANCH"
git fetch "$REMOTE" "$REMOTE_BRANCH"
NEW_BASE=$(git rev-parse "$BASE_REF")
OLD_BASE=$(git rev-parse "${OLD_BASE_ARG:-$(git merge-base "$BRANCH" "$BASE_REF")}")
BEFORE=$(git rev-parse --short HEAD)
if ! git merge-base --is-ancestor "$OLD_BASE" "$NEW_BASE"; then
  echo "== NOTE: the new base does not contain the old one ($(git rev-parse --short "$OLD_BASE") -> $(git rev-parse --short "$NEW_BASE"))"
  echo "==       (force-push or base switch): triage every patch against the new base."
fi
echo "== replaying $(git rev-list --count "$OLD_BASE..$BRANCH") commit(s) onto $BASE_REF ($(git rev-list --count "$OLD_BASE..$NEW_BASE") upstream commits since the old base)"
git rebase --autosquash --onto "$NEW_BASE" "$OLD_BASE" "$BRANCH"
AFTER=$(git rev-parse --short HEAD)
echo "== rebased $BRANCH: $BEFORE -> $AFTER (base: $(git rev-parse --short "$NEW_BASE"))"

# 2b. Migration tripwires (README: migration hazard). Effect's Migrator tracks
#     progress by numeric id. A RENUMBERED existing migration re-runs on an old DB
#     ("table ... already exists" -> backend crash-loop, no window). A REMOVED or
#     consolidated one leaves the DB's ledger max above the code's, so inserted
#     migrations are silently skipped. Detect both before anyone ships a build.
mig_pairs() {  # $1 = commit-ish -> lines of "Name id"
  git show "$1:apps/server/src/persistence/Migrations.ts" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\[\([0-9][0-9]*\), "\([A-Za-z0-9]*\)".*/\2 \1/p'
}
if [[ -z "$(mig_pairs "$NEW_BASE")" ]]; then
  echo "== WARNING: no migration table parsed from apps/server/src/persistence/Migrations.ts"
  echo "==   on the new base — upstream moved or reshaped it; the tripwires below are BLIND."
fi
RENUMBERED=$(join <(mig_pairs "$OLD_BASE" | sort) <(mig_pairs "$NEW_BASE" | sort) \
  | awk '$2 != $3 {printf "     %s: %s -> %s\n", $1, $2, $3}')
if [[ -n "$RENUMBERED" ]]; then
  echo "== WARNING: upstream RENUMBERED existing DB migrations:"
  echo "$RENUMBERED"
  echo "==   An installed statev2.sqlite on the old numbering will crash-loop the new"
  echo "==   build's backend. Reconcile the ledger before first launch (README)."
fi
REMOVED=$(comm -23 <(mig_pairs "$OLD_BASE" | cut -d' ' -f1 | sort) <(mig_pairs "$NEW_BASE" | cut -d' ' -f1 | sort) | tr '\n' ' ')
if [[ -n "$REMOVED" ]]; then
  echo "== WARNING: migrations REMOVED/CONSOLIDATED upstream: $REMOVED"
  echo "==   A ledger max above the new code's max silently skips every inserted"
  echo "==   migration. Reconcile the ledger before first launch (README)."
fi
echo "== migrations: max $(mig_pairs "$NEW_BASE" | awk '{print $2}' | sort -n | tail -1) on the new base"

# 3. Backup the rebased branch to our fork
if [[ $DO_PUSH -eq 1 ]]; then
  git push --force-with-lease origin "$BRANCH"
fi

# 4. Reinstall deps (the lockfile churns upstream daily). When upstream changes
#    the pnpm store/layout, pnpm wants to purge node_modules and aborts without a
#    TTY (ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY) — agents run this headless.
pnpm install --config.confirmModulesPurge=false

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
  # The .app only ships inside the dmg/zip (staging dir is cleaned up);
  # extract the zip to verify the update feed is absent and to install.
  ZIP=$(ls -t release/T3-Code-*-arm64.zip 2>/dev/null | head -1 || true)
  if [[ -n "${ZIP:-}" ]]; then
    EXTRACT_DIR=$(mktemp -d /tmp/t3code-app.XXXXXX)
    ditto -x -k "$ZIP" "$EXTRACT_DIR"
    APP_PATH="$EXTRACT_DIR/$APP_NAME"
    if ! [[ -e "$APP_PATH/Contents/Resources/app-update.yml" ]]; then
      echo "== auto-update check: no app-update.yml in bundle -> updater disabled ✓"
    else
      echo "WARNING: app-update.yml present in bundle — auto-update may be live!" >&2
    fi
    rm -rf "$EXTRACT_DIR"
    if [[ $DO_INSTALL -eq 1 ]]; then
      # Installing is deploy.sh's job — ONE installer, so the quit/sunlnk/verify
      # logic cannot drift between this script and a hand-written one.
      echo "== handing off to deploy.sh --local"
      fork-infra/deploy.sh --local --zip "$ZIP"
    fi
  else
    echo "WARNING: no zip artifact found under release/" >&2
  fi
fi

echo "== done. Threads, pairing and settings live in ~/.t3 and carry over."

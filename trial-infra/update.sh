#!/usr/bin/env bash
# t3code Pi-fork trial updater (Quartermaster QM-80)
#
# Pulls the latest upstream Pi-provider PR branch, rebases local trial patches,
# reinstalls deps, and produces an unsigned packaged macOS build with
# auto-update guaranteed OFF.
#
# Tracking layout (repo: ~/Projects/forks/t3code):
#   origin     = astarktc/t3code          (our GitHub fork; backup of trial branch)
#   upstream   = pingdotgg/t3code         (canonical upstream; ALSO the base branch source)
#   stienswout = StiensWout/t3code        (historical: PR #7211 source, squash-merged
#                                          into the V2 branch 2026-09-10; no longer tracked)
#   trial      = upstream/t3code/codex-turn-mapping (PR #2829 V2, now incl. the Pi
#                provider) + our local patches (this script, etc.)
#
# Usage: trial-infra/update.sh [--no-build] [--install] [--no-push] [--old-base <sha>]
#   --no-build        fetch + rebase + pnpm install only
#   --install         after building, copy the .app into /Applications (quit the app first)
#   --no-push         skip force-pushing the rebased trial branch to origin
#   --old-base <sha>  the PR head trial currently sits on; needed when the remote
#                     was already fetched (the default reads the tracking ref)

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Native resource-monitor needs cargo; rustup installs live in ~/.cargo/bin,
# which non-interactive shells don't have on PATH.
export PATH="$HOME/.cargo/bin:$PATH"

BRANCH=trial
# Lineage collapsed 2026-09-10: PR #7211 (Pi provider) was squash-merged INTO the
# Orchestrator V2 branch, so the StiensWout layer is gone and trial now stacks
# directly on the maintainer's V2 branch. Next layer to disappear: #2829 -> main,
# which is this fork's exit condition (QM-116).
REMOTE=upstream
REMOTE_BRANCH=t3code/codex-turn-mapping
APP_NAME="T3 Code (Alpha).app"

DO_BUILD=1 DO_INSTALL=0 DO_PUSH=1 OLD_BASE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) DO_BUILD=0 ;;
    --install)  DO_INSTALL=1 ;;
    --no-push)  DO_PUSH=0 ;;
    --old-base) OLD_BASE_ARG="${2:?--old-base needs a sha}"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# 1. Guard: clean worktree
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: worktree not clean — commit/stash first." >&2
  git status --short >&2
  exit 1
fi

# 2. Fetch + rebase local patches onto the moving PR branch.
#    Always rebase with --onto <new-remote-head> <old-remote-head>: this replays
#    exactly our local commits and is force-push-safe (a plain `git rebase` after
#    an upstream force-push tries to replay hundreds of old-SHA stack commits).
OLD_BASE=$(git rev-parse "${OLD_BASE_ARG:-$REMOTE/$REMOTE_BRANCH}")
git fetch "$REMOTE" "$REMOTE_BRANCH"
git fetch upstream main --quiet || true   # reference only; PR branches stack on V2, not main
NEW_BASE=$(git rev-parse "$REMOTE/$REMOTE_BRANCH")
git checkout "$BRANCH"
BEFORE=$(git rev-parse --short HEAD)
if [[ "$OLD_BASE" != "$NEW_BASE" ]] && ! git merge-base --is-ancestor "$OLD_BASE" "$NEW_BASE"; then
  echo "== NOTE: upstream force-push detected ($(git rev-parse --short "$OLD_BASE") -> $(git rev-parse --short "$NEW_BASE"))"
  echo "==       after the rebase, check whether local patches were superseded upstream"
  echo "==       (2 of 3 were absorbed at the 2026-08-28 force-push)."
fi
git rebase --onto "$NEW_BASE" "$OLD_BASE" "$BRANCH"
AFTER=$(git rev-parse --short HEAD)
echo "== rebased $BRANCH: $BEFORE -> $AFTER (base: $(git rev-parse --short "$NEW_BASE"))"

# 2b. Migration-renumber tripwire: if an already-existing migration's numeric id
#     changed between the old and new base, a DB that ran the old numbering will
#     crash-loop the packaged backend on launch ("table ... already exists") with
#     NO WINDOW and no visible error. Detect it here, before anyone ships a build.
mig_pairs() {  # $1 = commit-ish -> lines of "Name id"
  git show "$1:apps/server/src/persistence/Migrations.ts" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\[\([0-9][0-9]*\), "\([A-Za-z0-9]*\)".*/\2 \1/p'
}
RENUMBERED=$(join <(mig_pairs "$OLD_BASE" | sort) <(mig_pairs "$NEW_BASE" | sort) \
  | awk '$2 != $3 {printf "     %s: %s -> %s\n", $1, $2, $3}')
if [[ -n "$RENUMBERED" ]]; then
  echo "== WARNING: upstream RENUMBERED existing DB migrations:"
  echo "$RENUMBERED"
  echo "==   A ~/.t3/userdata/state.sqlite that ran the old numbering will crash-loop"
  echo "==   the new build's backend (app launches with no window). Reconcile the"
  echo "==   effect_sql_migrations ledger before first launch — see the 2026-08-28"
  echo "==   instance script trial-infra/fix-migration-renumber-20260828.sh and"
  echo "==   trial-infra/README.md for the general pattern."
fi
# Consolidation tripwire: migrations that vanished from the table (folded into
# another id) leave an old DB's ledger max ABOVE the code's max, so the Migrator
# runs nothing and any newly inserted migrations are silently skipped (the
# 2026-09-09 shape: old V2 block 44-52 folded into a single 50, new 44-49
# inserted). See trial-infra/fix-migration-consolidation-20260909.sh.
REMOVED=$(comm -23 <(mig_pairs "$OLD_BASE" | cut -d' ' -f1 | sort) <(mig_pairs "$NEW_BASE" | cut -d' ' -f1 | sort) | tr '\n' ' ')
if [[ -n "$REMOVED" ]]; then
  echo "== WARNING: migrations REMOVED/CONSOLIDATED upstream: $REMOVED"
  echo "==   If the installed DB's ledger max exceeds the new code's max id, the new"
  echo "==   build will SILENTLY skip every inserted migration — reconcile the ledger"
  echo "==   by hand (pattern: trial-infra/fix-migration-consolidation-20260909.sh)."
fi

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
    if [[ $DO_INSTALL -eq 1 ]]; then
      echo "== installing to /Applications (quit the app first if running)"
      rm -rf "/Applications/$APP_NAME"
      ditto "$APP_PATH" "/Applications/$APP_NAME"
      echo "== installed: /Applications/$APP_NAME (state stays in ~/.t3)"
    fi
    rm -rf "$EXTRACT_DIR"
  else
    echo "WARNING: no zip artifact found under release/" >&2
  fi
fi

echo "== done. Reminder: threads/pairing/settings live in ~/.t3 and carry over."

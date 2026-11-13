#!/usr/bin/env bash
# Rebase our patch stack onto upstream and produce a packaged macOS build with
# auto-update guaranteed OFF. The operating manual is fork-infra/README.md.
#
# Layout (repo: ~/Projects/forks/t3code):
#   upstream = pingdotgg/t3code   (canonical; the base branch is upstream/main)
#   origin   = astarktc/t3code    (our public GitHub fork; backup of the branch)
#   patched  = upstream/main + our product patches + one fork-infra commit
#
# Usage: fork-infra/update.sh --ticket <N> [--base <remote>/<branch>] [--old-base <sha>]
#                             [--no-build] [--install] [--no-push] [--no-backup]
#   --ticket <N>      the absorption's work item (QM-380, qm380 or 380). Names the
#                     rollback branch backup/pre-qm<N>, created at the current
#                     head before the rebase and pushed to origin. Required
#                     unless --no-backup. A branch of that name that already
#                     exists is kept where it is (a re-run in one absorption).
#                     Only the newest 3 backup/pre-qm* branches (by number) are
#                     kept; older ones are deleted here and on origin.
#   --no-backup       create no rollback branch (a dry run, or a re-run whose
#                     branch exists under another ticket)
#   --base <ref>      upstream branch to stack on (default upstream/main). Use it
#                     only to ride a long-lived upstream feature branch.
#   --old-base <sha>  the base commit the branch sits on now. Default: the
#                     merge-base with --base, which is right whenever the base
#                     branch is never rewritten (main). Required when the branch
#                     sits on a different or force-pushed base.
#   --no-build        fetch + rebase + pnpm install only
#   --install         after building, deploy onto THIS machine via deploy.sh --local
#   --no-push         push nothing to origin: neither the rollback branch nor the
#                     rebased branch
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
ROLLBACK_KEEP=3

DO_BUILD=1 DO_INSTALL=0 DO_PUSH=1 DO_BACKUP=1 OLD_BASE_ARG="" TICKET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)     BASE_REF="${2:?--base needs <remote>/<branch>}"; shift ;;
    --old-base) OLD_BASE_ARG="${2:?--old-base needs a sha}"; shift ;;
    --no-build) DO_BUILD=0 ;;
    --install)  DO_INSTALL=1 ;;
    --no-push)  DO_PUSH=0 ;;
    --ticket)   TICKET="${2:?--ticket needs a work item number}"; shift ;;
    --no-backup) DO_BACKUP=0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
REMOTE=${BASE_REF%%/*}
REMOTE_BRANCH=${BASE_REF#*/}

# A same-version rebuild overwrites the release zip and the Windows exe under the
# same names, so the rollback branch is the only way back to the deployed build.
BACKUP_BRANCH=""
if [[ $DO_BACKUP -eq 1 ]]; then
  TICKET_NUM=$(printf '%s' "$TICKET" | tr '[:upper:]' '[:lower:]' | sed -E 's/^qm-?//')
  if ! [[ "$TICKET_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: pass --ticket <N> (the absorption's work item; names the rollback branch backup/pre-qm<N>), or --no-backup." >&2
    exit 2
  fi
  BACKUP_BRANCH="backup/pre-qm$TICKET_NUM"
fi

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

# 1b. Rollback branch at the pre-absorption head, on origin before anything is rewritten.
#     A branch of this name that exists already (here or on origin) is never moved:
#     in a re-run, or in another clone, HEAD is no longer the deployed build.
if [[ -n "$BACKUP_BRANCH" ]]; then
  REMOTE_BACKUP=$(git ls-remote --heads origin "refs/heads/$BACKUP_BRANCH" | cut -f1)
  LOCAL_BACKUP=$(git rev-parse -q --verify "refs/heads/$BACKUP_BRANCH" || true)
  if [[ -n "$REMOTE_BACKUP" && -n "$LOCAL_BACKUP" && "$REMOTE_BACKUP" != "$LOCAL_BACKUP" ]]; then
    echo "ERROR: $BACKUP_BRANCH is ${LOCAL_BACKUP:0:10} here and ${REMOTE_BACKUP:0:10} on origin — settle which is the rollback point, then re-run." >&2
    exit 1
  elif [[ -n "$LOCAL_BACKUP" ]]; then
    echo "== rollback branch $BACKUP_BRANCH exists at ${LOCAL_BACKUP:0:10}; kept (HEAD is $(git rev-parse --short HEAD))"
  elif [[ -n "$REMOTE_BACKUP" ]]; then
    git fetch origin "refs/heads/$BACKUP_BRANCH"
    git branch "$BACKUP_BRANCH" "$REMOTE_BACKUP"
    echo "== rollback branch $BACKUP_BRANCH exists on origin at ${REMOTE_BACKUP:0:10}; kept (HEAD is $(git rev-parse --short HEAD))"
  else
    git branch "$BACKUP_BRANCH" HEAD
    echo "== rollback branch $BACKUP_BRANCH = $(git rev-parse --short HEAD)"
  fi
  if [[ $DO_PUSH -eq 1 && -z "$REMOTE_BACKUP" ]]; then
    git push origin "$BACKUP_BRANCH"
  fi

  # 1c. Rotate: keep the newest ROLLBACK_KEEP rollback branches by ticket number,
  #     here and on origin. At one or two absorptions a day an older build is no
  #     realistic rollback, and this run's branch (the deployed build) is always kept.
  ORIGIN_BACKUPS=$(git ls-remote --heads origin 'refs/heads/backup/pre-qm*' | sed 's|.*refs/heads/||')
  LOCAL_BACKUPS=$(git for-each-ref --format='%(refname:short)' 'refs/heads/backup/pre-qm*')
  ALL_BACKUPS=$(printf '%s\n%s\n' "$ORIGIN_BACKUPS" "$LOCAL_BACKUPS" \
    | grep -E '^backup/pre-qm[0-9]+$' | sort -u | sort -t m -k2 -n -r || true)
  KEPT=$(printf '%s\n' "$ALL_BACKUPS" | head -n "$ROLLBACK_KEEP")
  for old in $(printf '%s\n' "$ALL_BACKUPS" | tail -n "+$((ROLLBACK_KEEP + 1))"); do
    if [[ "$old" == "$BACKUP_BRANCH" ]]; then continue; fi
    WHERE=""
    if printf '%s\n' "$LOCAL_BACKUPS" | grep -qx "$old"; then
      git branch -D "$old" >/dev/null
      WHERE="here"
    fi
    if [[ $DO_PUSH -eq 1 ]] && printf '%s\n' "$ORIGIN_BACKUPS" | grep -qx "$old"; then
      git push -q origin --delete "$old"
      WHERE="${WHERE:+$WHERE + }origin"
    fi
    if [[ -n "$WHERE" ]]; then
      echo "== rollback branch $old pruned ($WHERE; keeping the newest $ROLLBACK_KEEP)"
    fi
  done
  echo "== rollback branches kept: $(printf '%s ' $KEPT)"
fi

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

# 2c. Auth-scope tripwire (README: auth-scope hazard). Upstream splits permissions
#     into new scopes and never expands a stored grant, so every client paired
#     before the deploy silently loses the features behind the new scopes until
#     it is re-paired from an upgraded client.
auth_scopes() {  # $1 = commit-ish -> sorted scope names
  git show "$1:packages/contracts/src/auth.ts" 2>/dev/null \
    | sed -n 's/^\(export \)\{0,1\}const Auth[A-Za-z]*Scope = "\([^"]*\)".*/\2/p' | sort -u
}
if [[ -z "$(auth_scopes "$NEW_BASE")" ]]; then
  echo "== WARNING: no auth scopes parsed from packages/contracts/src/auth.ts on the new base"
  echo "==   — upstream moved or reshaped them; the auth-scope tripwire is BLIND."
fi
ADDED_SCOPES=$(comm -13 <(auth_scopes "$OLD_BASE") <(auth_scopes "$NEW_BASE") | tr '\n' ' ')
if [[ -n "$ADDED_SCOPES" ]]; then
  echo "== WARNING: upstream ADDED auth scopes: $ADDED_SCOPES"
  echo "==   Existing pairings keep their old grant. After deploying, re-pair every"
  echo "==   remote client from an upgraded client and check auth_sessions.scopes (README)."
fi
#     Upstream can also widen what a pairing grants without adding a scope, by
#     moving existing scopes into the standard client set (#20432 did, for
#     access:* and relay:write). Same consequence: old pairings lack them.
standard_client_scopes() {  # $1 = commit-ish -> sorted scopes a standard pairing gets
  local src id
  src=$(git show "$1:packages/contracts/src/auth.ts" 2>/dev/null) || return 0
  for id in $(printf '%s\n' "$src" | awk '/^export const AuthStandardClientScopes = \[/ {f=1; next} f && /^\]/ {f=0} f' \
    | grep -oE 'Auth[A-Za-z]+Scope'); do
    printf '%s\n' "$src" | sed -n "s/^\(export \)\{0,1\}const $id = \"\([^\"]*\)\".*/\2/p"
  done | sort -u
}
if [[ -z "$(standard_client_scopes "$NEW_BASE")" ]]; then
  echo "== WARNING: AuthStandardClientScopes not parsed from packages/contracts/src/auth.ts on"
  echo "==   the new base; the standard-grant tripwire is BLIND."
fi
WIDENED=$(comm -13 <(standard_client_scopes "$OLD_BASE") <(standard_client_scopes "$NEW_BASE") | tr '\n' ' ')
if [[ -n "${WIDENED// /}" ]]; then
  echo "== WARNING: a new pairing now also grants: $WIDENED"
  echo "==   Existing pairings keep their old grant; re-pair the remote clients that need"
  echo "==   these (README auth-scope hazard)."
fi

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
#    - built unsigned (T3CODE_DESKTOP_SIGNED defaults false: upstream's signed path
#      wants a Developer ID and a provisioning profile), then signed in the zip by
#      sign-mac.sh with our Apple team identity (README, Code signing). deploy.sh
#      refuses an unsigned zip. The dmg stays unsigned; nothing installs from it.
if [[ $DO_BUILD -eq 1 ]]; then
  env -u GITHUB_REPOSITORY -u T3CODE_DESKTOP_UPDATE_REPOSITORY \
    pnpm dist:desktop:dmg:arm64
  echo "== artifacts in release/:"
  ls -la release/ | grep -v '^total'
  # The .app only ships inside the dmg/zip (staging dir is cleaned up);
  # extract the zip to verify the update feed is absent and to install.
  ZIP=$(ls -t release/T3-Code-*-arm64.zip 2>/dev/null | head -1 || true)
  if [[ -n "${ZIP:-}" ]]; then
    fork-infra/sign-mac.sh "$ZIP"
    EXTRACT_DIR=$(mktemp -d /tmp/t3code-app.XXXXXX)
    ditto -x -k "$ZIP" "$EXTRACT_DIR"
    # The bundle's name follows upstream's productName; the zip holds exactly one app.
    APP_PATH=$(ls -d "$EXTRACT_DIR"/*.app | head -1)
    echo "== app in artifact: $(basename "$APP_PATH")"
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
if [[ -n "$BACKUP_BRANCH" ]]; then
  echo "== rollback: $BACKUP_BRANCH (local$([[ $DO_PUSH -eq 1 ]] && echo ' + origin')). update.sh keeps the newest $ROLLBACK_KEEP rollback branches."
fi

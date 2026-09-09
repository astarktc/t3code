# trial-infra — maintaining a personal fork of an unmerged t3code PR stack

Tooling for running a **personal packaged build** of t3code's Pi-provider PR stack as a
daily driver, tracking a fast-moving upstream that periodically **force-pushes**.
Everything here was built (and battle-tested) while trialing
[pingdotgg/t3code#7211](https://github.com/pingdotgg/t3code/pull/7211).

## The lineage you're standing on

```
pingdotgg/t3code  main                      ← canonical upstream, multiple commits/day
        │  (periodically rebased onto)
pingdotgg/t3code  t3code/codex-turn-mapping ← PR #2829 "Orchestration V2" — a maintainer
        │                                     branch ON the upstream repo, force-pushed
        │                                     at each rebase onto main
StiensWout/t3code t3code/pi-provider        ← PR #7211 (Pi provider), re-stacked on each
        │                                     V2 snapshot (also force-pushed)
trial (this repo)                           ← the PR head + our local patches, replayed
                                              on every update
```

Remotes as configured here: `origin` = the personal GitHub fork (backup of `trial`),
`upstream` = pingdotgg/t3code (reference only), `stienswout` = the PR source.
**Two cascading rebase layers land on you at once** — plan for force-pushes as the
normal case, not the exception.

## `update.sh` — the rebase→rebuild pipeline

```
trial-infra/update.sh [--no-build] [--install] [--no-push] [--old-base <sha>]
```

What it does, in order:

1. **Guard**: refuses to run on a dirty worktree.
2. **Fetch + rebase**: captures the remote PR head *before* fetching, then rebases with
   `git rebase --onto <new-head> <old-head> trial`. This replays **exactly the local
   patch commits** and is **force-push-safe** — a plain `git rebase` after an upstream
   force-push would try to replay hundreds of old-SHA stack commits and drown you in
   conflicts. If a force-push is detected (old head no longer an ancestor), it says so
   and reminds you to check whether your patches were absorbed upstream. **The old head is
   captured from the local remote-tracking ref at run time** — if you `git fetch` the PR
   remote while pre-inspecting, old == new and the rebase degenerates into replaying the
   whole old stack; pass the recorded old head with `--old-base <sha>` in that case.
3. **Migration-renumber tripwire**: diffs the DB migration id/name table
   (`apps/server/src/persistence/Migrations.ts`) between the old and new base and
   **warns loudly if any existing migration's number changed** (see hazard #2 below).
4. **Backup**: force-with-lease pushes the rebased `trial` to `origin` (skip: `--no-push`).
5. **Build**: `pnpm install` + unsigned arm64 packaged build with auto-update
   **provably dead** — publish-repo env vars are unset so electron-builder emits no
   `app-update.yml` (the updater self-disables without it), and the bundle is checked
   for its absence after the build. A fork build that silently self-updates back to an
   upstream release would be a disaster; this makes it structurally impossible.
6. **Install** (`--install`): swaps the app bundle into `/Applications`. Quit the app
   first. App state lives in `~/.t3/userdata/` (packaged) / `~/.t3/dev/` (dev builds)
   and survives reinstalls.

Gotchas encoded in the script: `~/.cargo/bin` is added to PATH (a native resource
monitor needs cargo, and non-interactive shells don't have it); commit trial-infra
changes with `--no-verify` (the repo's pre-commit hook assumes app-code changes).

## `fix-migration-renumber-20260828.sh` — the state-repair pattern

One-shot repair for the 2026-08-28 force-push, kept as the **template for the hazard
class**. Self-guarding: no-ops unless the DB ledger matches the exact pre-fix state,
refuses to run while the app is open, and backs up the DB first.

## The three hazards of rebasing against this upstream

### 1. Force-pushes are routine — never plain-rebase across one

The V2 base branch is rebased onto main every so often, and the PR branch re-stacks on
top; both force-push. All the old commit SHAs vanish. `update.sh` handles this
automatically via `--onto`; if you ever rebase by hand, always use
`git rebase --onto <new-remote-head> <old-remote-head> trial`.

After any force-push, **diff your local patches against the new head before assuming
you still need them** — upstream absorbs fixes fast. At the 2026-08-28 force-push, 2 of
our 3 patches had been superseded (one adopted upstream after our bug report, one
mooted by a refactor). Local patch count should *decay* over time if you report bugs
upstream instead of hoarding fixes.

### 2. Force-pushes can invalidate persistent state, not just code

The nastiest failure mode found: upstream inserted 3 new DB migrations *before*
already-applied ones, renumbering the tail of the sequence (41–49 became 44–52). The
migrator tracks progress by numeric id, so a database created under the old numbering
re-runs "new" migrations that already ran → `table ... already exists` → **the backend
crash-loops and the app launches with no window and no visible error** (the desktop
shell waits forever on backend readiness; the real error is only in
`~/.t3/userdata/logs/server-child.log`).

Repair pattern (see the fix script for a worked example):

1. Quit the app; back up `state.sqlite`.
2. Verify the shifted migrations are **byte-identical** between old and new base
   (`git diff <old> <new> -- .../Migrations/<file>` per pair) — if they are, this is
   renumber-only and safe to reconcile.
3. Manually apply whatever the newly-inserted migrations do (they were guarded
   `ALTER TABLE ADD COLUMN`s in our case).
4. Renumber the `effect_sql_migrations` ledger to match the new sequence and insert
   rows for the newly-applied ids (two-step offset update to dodge PK collisions).
5. `PRAGMA integrity_check`, relaunch.

`update.sh` step 3 now detects the condition at rebase time, before you build.

The hazard has a **second shape** (2026-09-09): upstream *consolidated* nine already-applied
migrations (44–52) into one id (50) and inserted six new ones at 44–49. Effect's Migrator
runs only ids **greater than the ledger's max**, so a DB at 52 sees a code max of 50 and runs
*nothing* — no crash, the new columns/indexes just never land and queries fail later. Same
repair pattern (verify the folded bodies are identical, apply the inserted migrations by
hand, rewrite the ledger); worked example: `fix-migration-consolidation-20260909.sh`.
`update.sh` warns about removed/consolidated migration names alongside the renumber check.

| Ledger vs code | Symptom | Fix |
| --- | --- | --- |
| ledger max **below** the renumbered ids | migrations re-run → `table already exists` → crash-loop, no window | renumber ledger, apply inserted ALTERs |
| ledger max **above** the code max (consolidation) | silent: nothing runs, schema drifts | apply inserted migrations by hand, rewrite ledger to the new sequence |

### 3. Don't try to out-rebase the maintainers

Tempting idea: merge upstream `main` into the stack daily yourself instead of waiting
for the official rebase. Measured reality (2026-08-28): **one day** of main drift = 30
conflicted files against the stack (which diverges from main across ~900 files). The
maintainer's own rebases are visibly manual reconciliation work, your resolutions would
duplicate his, and the next official force-push **discards everything you resolved**.
The economical moves are:

- ride the official force-pushes (this repo's default), and
- **cherry-pick individual main commits** when something specific matters
  (`git cherry-pick <sha>` onto `trial`; drop it at whatever rebase absorbs it).

## After every update — verify before trusting

- App launches **with a window** and About shows the new version (a no-window launch =
  hazard #2 — check `server-child.log`, not the desktop log).
- `curl http://127.0.0.1:3773/.well-known/t3/environment` returns the new
  `serverVersion`.
- Whatever your local patches touch still works.

A second machine can be updated without a repo checkout: copy the built
`release/T3-Code-<ver>-arm64.zip` over, extract with `ditto -x -k`, swap
`/Applications/T3 Code (Alpha).app`, run the state-repair script if hazard #2 applies,
relaunch.

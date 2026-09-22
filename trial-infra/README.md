# trial-infra — maintaining a personal fork of an unmerged t3code PR stack

Tooling for running a **personal packaged build** of t3code's Orchestrator V2 + Pi-provider
stack as a daily driver, tracking a fast-moving upstream that periodically **force-pushes**.

## Absorption checklist (every upstream move — run the scripts, never improvise)

1. `trial-infra/update.sh --old-base <the sha trial actually sits on>` — force-push-safe
   `--onto` rebase + migration tripwires + backup push + packaged build. It **exits at a
   rebase conflict**; after resolving one, run its later steps by hand — the two tripwire
   comparisons (step 3 below) are the ones most easily skipped, and 7 of 8 absorptions to
   date carried a migration hazard.
2. **Patch triage against the new base — by invariant and intent, not by conflict** (hazard #1).
3. **Verify**: `apps/server` `tsc --noEmit` + the suites covering whatever the patches touch.
   If a test fails in a file you just resolved, **baseline first**: `git checkout <newbase> --
<files>`, re-run, restore with `git checkout HEAD -- …` — upstream ships red tests.
4. **Deploy** with `trial-infra/deploy.sh`: `--remote <host>` for other machines FIRST, `--local`
   (`--detach` from inside a T3-hosted thread) for the session host LAST. A migration repair
   between quit and install = `install-from-inside.sh --repair <fix script> --expect-asar <hash>`.
5. **Record**: asar-hash parity on both Macs; prune superseded `~/.t3/userdata/statev2.sqlite.bak-*`
   (and legacy `state.sqlite.bak-*`) on both, keeping the current schema's.

## The lineage you're standing on

```
pingdotgg/t3code  main                      ← canonical upstream, multiple commits/day
        │  (periodically rebased onto)
pingdotgg/t3code  t3code/codex-turn-mapping ← PR #2829 "Orchestration V2" — a maintainer
        │                                     branch ON the upstream repo, force-pushed
        │                                     at each rebase onto main. Since 2026-09-10
        │                                     it also CONTAINS the Pi provider (#7211,
        │                                     squash-merged) and the ACP standardization
        │                                     (#6461).
trial (this repo)                           ← the V2 head + our local patches, replayed
                                              on every update
```

The one remaining layer, #2829 → `main`, is this whole pipeline's exit condition. Squash
merges mean the last PR head is **not** an ancestor of the new base — always `--onto` with an
explicitly recorded old head. Plan for force-pushes as the normal case, not the exception.

Remotes: `origin` = the personal GitHub fork (backup of `trial`), `upstream` = pingdotgg/t3code
(both the canonical repo **and** the base-branch source).

## `update.sh` — the rebase→rebuild pipeline

```
trial-infra/update.sh [--no-build] [--install] [--no-push] [--old-base <sha>]
```

What it does, in order:

1. **Guard**: refuses to run on a dirty worktree.
2. **Fetch + rebase**: captures the remote PR head _before_ fetching, then rebases with
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
6. **Install** (`--install`): hands off to `deploy.sh --local`. App state lives in
   `~/.t3/userdata/` (packaged) / `~/.t3/dev/` (dev builds) and survives reinstalls.

Gotchas encoded in the script: `~/.cargo/bin` is added to PATH (a native resource
monitor needs cargo, and non-interactive shells don't have it); commit trial-infra
changes with `--no-verify` (the repo's pre-commit hook assumes app-code changes).
`update.sh` **exits at a rebase conflict**, so its later steps (tripwires, backup push,
build) must then be run by hand once the conflict is resolved.

## `deploy.sh` — the ONE installer, for both Macs

```
trial-infra/deploy.sh --local  [--zip <path>] [--detach] [--force]
trial-infra/deploy.sh --remote <ssh-host> [--zip <path>] [--force]
```

Every install-step incident on record was a **dispatch bug in a hand-written throwaway
installer, not a build bug** (hazards #3, #4, #6). This is the one committed, tested installer;
do not improvise another.

It refuses to do the wrong thing rather than trusting the operator: aborts on active
orchestration runs (`--force` to override), rejects an artifact carrying `app-update.yml`,
refuses to overwrite a bundle it could not prove had quit, verifies the installed asar
hash equals the artifact's, and after relaunch checks readiness, `serverVersion`, the
migration ledger, `integrity_check`, **and that the app is still alive 20 s later** — the
last one is what catches a KeepAlive'd dispatcher quit-looping the app. Every run tees to
`/tmp/t3-deploy-<timestamp>.log` on the machine being installed, so evidence survives a
closed terminal or an interrupted session.

**Order matters: other machines first, the machine hosting your session LAST** — the
install quits the app, so installing the host machine ends any session running inside it.

```sh
# from the MBP (the build machine), after update.sh has produced release/*.zip
trial-infra/deploy.sh --remote mac-uni-auto   # work Mac: attached, full output here
trial-infra/deploy.sh --local                 # MBP last
#   ... or, when dispatching from a Pi thread hosted BY T3 Code itself:
trial-infra/deploy.sh --local --detach        # survives the app going away
#   ... and when a migration repair must run between quit and install:
trial-infra/install-from-inside.sh --repair trial-infra/fix-migration-<date>.sh --expect-asar <hash16>
```

`install-from-inside.sh` is the committed form of the "quit → repair → deploy" wrapper the
MBP needs after a renumber hazard; it runs in a new session like `--detach` (hazard #6).

## `fix-migration-*.sh` — the state-repair pattern

One script per incident, each kept as a worked example of the hazard class. All are
self-guarding: they no-op unless the DB ledger matches the exact pre-fix state, refuse
to run while the app is open, and back up the DB first. Run with the app **quit** and
**before** the new build's first launch, on every machine.

**The live DB is `~/.t3/userdata/statev2.sqlite`** (V2 split from V1 upstream in
15769fa10e); `state.sqlite` is the frozen V1 file. The scripts below predate the split and
name `state.sqlite` — they are kept as records of what ran. Any new repair script targets
`statev2.sqlite` (hazard #8).

| Script                                    | Shape         | What upstream did                                                                                                                                  |
| ----------------------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fix-migration-renumber-20260828.sh`      | renumber      | inserted 3 migrations before applied ones (41–49 → 44–52)                                                                                          |
| `fix-migration-consolidation-20260909.sh` | consolidation | folded 44–52 into one id 50, inserted 6 new at 44–49                                                                                               |
| `fix-migration-renumber-20260910.sh`      | renumber      | inserted 50 `ProjectionThreadPullRequests`, `OrchestrationV2` 50 → 51                                                                              |
| `fix-migration-renumber-20260913.sh`      | renumber      | inserted 51 `ProjectionThreadMessageContext`, `OrchestrationV2` 51 → 52                                                                            |
| `fix-migration-renumber-20260917.sh`      | renumber      | inserted 52 `ProjectionThreadTitleState`, `OrchestrationV2` 52 → 53                                                                                |
| `fix-migration-renumber-20260918.sh`      | renumber      | inserted 53 `PullRequestFilesViewed`, `OrchestrationV2` 53 → 54 (quit-guard applies to the live DB only — dry-runs on a copy work with the app up) |

A repair script may legitimately **refuse** when an inserted migration backfills data by
logic not reproducible in SQL — the 2026-09-10 one refuses if legacy linked-PR rows exist,
because migration 50 derives each PR's host by URL parsing. In that case migrate by running
the old build's logic or by hand, never by guessing. Plain guarded `ADD COLUMN` inserts
(2026-09-13) are fully reproducible and never need to refuse.

## The eight hazards of rebasing against this upstream

### 1. Force-pushes are routine — never plain-rebase across one

The V2 base branch is rebased onto main every so often, and the PR branch re-stacks on
top; both force-push. All the old commit SHAs vanish. `update.sh` handles this
automatically via `--onto`; if you ever rebase by hand, always use
`git rebase --onto <new-remote-head> <old-remote-head> trial`.

After any force-push, **diff your local patches against the new head before assuming
you still need them** — upstream absorbs fixes fast. Local patch count should _decay_ over
time if you report bugs upstream instead of hoarding fixes (every patch carries a drop-watch
item in Plane).

**Patch triage is about invariants and intent, not conflicts** — both directions have bitten:

- **A clean replay is NOT evidence a patch is still complete.** Upstream can add a new site
  for the same concept (a third `settledDeliveryCount` cap, once) and git replays the patch
  with zero conflicts while it silently stops covering its own invariant. **Grep the concept
  across the whole new base, not the hunk.**
- **A conflict does NOT mean the patch's intent is obsolete — often only its SHAPE is.** When
  upstream rewrites the file the patch touches (the usage transcript-dir resolver became a
  per-provider-instance loop), re-express the patch inside upstream's new structure; replaying
  the old structure reverts upstream's work. Expect the Pi-usage patch to conflict at every
  absorption.

Method note: `quartermaster/research/infra-reliability_fork-maintenance-invariants.md`.

### 2. Force-pushes can invalidate persistent state, not just code

The nastiest failure mode found: upstream inserted 3 new DB migrations _before_
already-applied ones, renumbering the tail of the sequence (41–49 became 44–52). The
migrator tracks progress by numeric id, so a database created under the old numbering
re-runs "new" migrations that already ran → `table ... already exists` → **the backend
crash-loops and the app launches with no window and no visible error** (the desktop
shell waits forever on backend readiness; the real error is only in today's
`~/.t3/userdata/logs/server.trace.ndjson`).

Repair pattern (see the fix script for a worked example):

1. Quit the app; back up `statev2.sqlite`.
2. Verify the shifted migrations are **byte-identical** between old and new base
   (`git diff <old> <new> -- .../Migrations/<file>` per pair) — if they are, this is
   renumber-only and safe to reconcile.
3. Manually apply whatever the newly-inserted migrations do (they were guarded
   `ALTER TABLE ADD COLUMN`s in our case).
4. Renumber the `effect_sql_migrations` ledger to match the new sequence and insert
   rows for the newly-applied ids (two-step offset update to dodge PK collisions).
5. `PRAGMA integrity_check`, relaunch.

`update.sh` step 3 now detects the condition at rebase time, before you build.

The hazard has a **second shape** (2026-09-09): upstream _consolidated_ nine already-applied
migrations (44–52) into one id (50) and inserted six new ones at 44–49. Effect's Migrator
runs only ids **greater than the ledger's max**, so a DB at 52 sees a code max of 50 and runs
_nothing_ — no crash, the new columns/indexes just never land and queries fail later. Same
repair pattern (verify the folded bodies are identical, apply the inserted migrations by
hand, rewrite the ledger); worked example: `fix-migration-consolidation-20260909.sh`.
`update.sh` warns about removed/consolidated migration names alongside the renumber check.

| Ledger vs code                                    | Symptom                                                            | Fix                                                                   |
| ------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------- |
| ledger max **below** the renumbered ids           | migrations re-run → `table already exists` → crash-loop, no window | renumber ledger, apply inserted ALTERs                                |
| ledger max **above** the code max (consolidation) | silent: nothing runs, schema drifts                                | apply inserted migrations by hand, rewrite ledger to the new sequence |

### 3. `/Applications` is `sunlnk` — never `rm -rf` the installed bundle

`/Applications` carries the `sunlnk` flag, so the app bundle **directory** cannot be
unlinked even by its owner. `rm -rf "/Applications/T3 Code (Alpha).app"` therefore
deletes every file _inside_ the bundle and then fails on the directory itself with
`Permission denied`. Under `set -e` that aborts the script **before** the copy step,
leaving a gutted, unlaunchable app (hit 2026-09-13 on the work Mac, mid-absorption).

Install by clearing the contents and populating the directory in place:

```sh
find "/Applications/$APP.app" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
ditto "$STAGED/$APP.app" "/Applications/$APP.app"
```

`deploy.sh` does this on both machines; it is the only installer.

### 4. Dispatching the MBP self-install: two traps that look like a broken build

The MBP installs itself from a script that **quits the app hosting the session that
dispatches it**, so the script must outlive both. Two ways that has gone wrong, both of
which present as "the new build is broken" rather than as a dispatch problem:

- **`launchctl submit` implies KeepAlive.** Handing the installer to launchd
  (`launchctl submit -l t3-mbp-install -- …`) makes launchd **re-run it every time it
  exits**. Since the script's first action is `osascript … quit`, the app is killed a few
  seconds after _every_ launch, forever — indistinguishable from a crash-on-startup until
  you notice the shutdown is graceful (`desktop.app` span exits `Success`,
  `backendInstance.stop`, no error). Cure: `launchctl remove t3-mbp-install`, then
  `pkill -f deploy.sh`. Use `deploy.sh --detach` (re-exec in a new session behind an env
  guard — see hazard #6 for why plain `nohup` is not enough) instead of launchd; macOS has
  no `setsid(1)`, so `nohup setsid …` fails with exit **127** and silently installs nothing.
- **`pgrep` cannot see the main app process at all.** On macOS `pgrep -f`/`pgrep -x` list
  only the `Helper` children of the Electron app, never the main `T3 Code (Alpha)` process or
  its server child (`ps -axo pid,comm` shows both). A "wait for the app to quit" loop written
  with `pgrep` returns instantly and the installer can clear the bundle **while the app is
  running**. `deploy.sh` matches the executable path in `ps -o comm` (`app_pids`). Verify any
  process guard against a _running_ app before trusting it — a check that can only ever
  return "gone" is worse than no check.

Diagnostic order when the app won't stay up after an install: is the shutdown graceful
(→ something is quitting it: this hazard) or is the backend dying (→ hazard #2, check
`server.trace.ndjson` / `desktop.trace.ndjson` for today's entries — `server-child.log`
is only written by the _old_ pre-trace builds and is easy to misread as current).

### 5. An unbounded readiness probe can hang a verified deploy

A backend that has bound port 3773 but is still starting accepts the TCP connection and
never answers; a bare `curl` blocks on that one probe forever while the install itself is
already complete and healthy. Every probe in `deploy.sh` is bounded (`--connect-timeout 2
--max-time 5`; the loop's worst case is ~5 min before an explicit failure) and `SIGPIPE` is
ignored before the `tee` fork, so a terminal or ssh channel that goes away cannot kill the
log writer either. If a deploy "sits there", look at the process tree (`pgrep -fl deploy.sh`,
then the children) before assuming the install failed: a lone stuck `curl` with `installed ✓`
already in the log is this hazard, not hazard #2.

### 6. `nohup` does not survive the app quitting when dispatched from inside it

A Pi bash tool inside a T3 Code thread runs its command in a process group; when the
installer quits the app, the thread dies, the tool call aborts, and the tool kills that whole
group — `nohup` only shields SIGHUP. Both `deploy.sh --detach` and `install-from-inside.sh`
re-exec through `perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV'`, which gives the installer its
own session and process group (`ps -o sess,pgid` to verify). Symptom to recognise: the log
stops mid-procedure with no error, the app is back up on the OLD build, and no `deploy.sh`
process exists.

### 7. `open -a` inherits the caller's environment — from inside T3, that relaunches the app as bare Node

`open` passes the caller's environment to the launched app (`man open`: "just as if you had
launched the application directly through its full path"). A Pi thread hosted by T3 Code
runs with `ELECTRON_RUN_AS_NODE=1` (T3 spawns Pi under its bundled Electron-as-node), so a
`--detach` install dispatched from inside T3 relaunched T3 Code as a Node process with no
script: it exited ~30 ms after launch with no `desktop.startup` span, `open` still returned 0,
and the only trace was Electron's `codesign_util.cc task_name_for_pid` line in the unified
log (the ELECTRON_RUN_AS_NODE signature check — absent from every healthy launch). The
2026-09-18 incident ("`open -a` returned 0, nothing launched for 37 min") was the same
mechanism; the 1 s poll never caught the 30 ms process. `--remote` (fresh ssh env) and hand
launches never carry the variable, which is why only `--detach` ever failed.

`deploy.sh` scrubs every `ELECTRON_*`/`T3_*` variable before `open` (logs which ones), then
still treats the exit code as no evidence: it polls `app_running` for 10 s, retries `open`
once, and fails with an "app did not launch" message that names the install as complete (so
it is not confused with hazard #2's no-window crash-loop). The readiness wait is a 300 s
wall-clock deadline (a connection-refused probe returns instantly, so an iteration count
burned out in 91 s). General form of the gotcha: **any agent running inside T3 that launches
an Electron app via `open` inherits `ELECTRON_RUN_AS_NODE`** — scrub it.

### 8. Upstream can move the DB out from under the installer's guards

Upstream 15769fa10e (2026-09-14) moved the V2 orchestrator into `statev2.sqlite`, leaving
`state.sqlite` as a frozen V1 file. `deploy.sh` kept reading `state.sqlite`: its active-run
pre-flight was **vacuous** (the V1 `orchestration_v2_projection_runs` table never changes,
so it never counted live work) and its ledger/integrity readout was stale — absorptions
#9–#11 recorded "ledger 54" from the dead file, correct by coincidence. Surfaced 2026-09-22
when migration 55 ran on `statev2.sqlite` while the readout still said 54. `deploy.sh` now
resolves `statev2.sqlite` first — which immediately exposed a second latent defect: the pre-flight's
"a `--detach` caller expects 1" rule existed only as a comment, so the first live count (1 = the
dispatching thread) would have killed every self-install; `--detach` now tolerates exactly one
run. The general form: **every path the installer verifies is an
upstream contract** — when a verify reading stops changing across deploys, suspect the
path, not the build. Check `apps/server/src/config.ts` (`dbPath`) at each absorption.

## Doctrine: ride the official force-pushes, don't out-rebase the maintainers

Merging upstream `main` into the stack yourself between official rebases does not pay:
**one day** of main drift measured 30 conflicted files against a stack that diverges from
main across ~900 files, the maintainer's own rebases are manual reconciliation work your
resolutions would duplicate, and the next official force-push **discards everything you
resolved**. The economical moves are riding the official force-pushes (this repo's default)
and **cherry-picking individual main commits** when something specific matters
(`git cherry-pick <sha>` onto `trial`; drop it at whatever rebase absorbs it).

## After every update — verify before trusting

`deploy.sh` already asserts readiness, `serverVersion`, the asar hash, the migration
ledger, `integrity_check` and 20 s survival — if it printed `DEPLOY OK`, those hold. What
is left for a human:

- App shows a **window** and About shows the expected version.
- Whatever your local patches touch still works (e.g. Pi appears in the Usage dashboard).
  Patch invariants to grep on the new base, not the hunk: Pi row in `UsageService`
  wherever `grok` is · zero `settledDeliveryCount` cap sites in trial · `PiAdapterV2`:
  resume fallback is upstream's own since #12933 (2026-09-22 drop) — `lifecycleRequest` at
  `PI_SESSION_TIMEOUT_MS`, `needsNewSession`, `getModelContextWindow` from
  `modelContextWindows`; nothing of ours to grep there.
- Both Macs report the **same asar hash** — that is the parity check worth recording.

**Where the truth is when something is wrong.** Use today's traces:
`~/.t3/userdata/logs/server.trace.ndjson` and `desktop.trace.ndjson`. **`server-child.log`
is NOT written by trace-era builds** — its newest lines are from an old incident, and on
2026-09-14 they showed a real 2026-08-28 migration crash-loop that looked exactly like a
current one. Check file mtimes before believing any log.

Triage order for "the app won't stay up":

1. Is the shutdown **graceful** (`desktop.app` span exits `Success`, `backendInstance.stop`)?
   Then something is _telling_ it to quit — hazard #4, not the build. Look for a dispatcher:
   `launchctl list | grep -i t3` and `pgrep -fl deploy.sh`.
2. Is the **backend dying** (readiness never reaches 200, migration errors in today's
   traces)? Then hazard #2 — reconcile the ledger with the matching `fix-migration-*.sh`.
3. Is the bundle **incomplete** (app won't launch at all)? Then hazard #3 bit a hand-rolled
   installer; just re-run `deploy.sh`, which is idempotent.
4. Did a deploy merely **stall** with `installed ✓` already logged? Hazard #5.

A second machine never needs a repo checkout or a hand-written script:
`trial-infra/deploy.sh --remote <ssh-host>` copies the artifact and itself, then runs the
identical verified path there.

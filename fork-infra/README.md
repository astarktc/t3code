# fork-infra — running our own build of T3 Code

We run a **personal packaged build** of T3 Code as the daily driver on two Macs and two Windows
remote environments: upstream `main` plus a small stack of our own patches, rebuilt whenever we
absorb upstream. Auto-update is dead by construction, so a release can never silently replace it.

Windows remote environments (Gaming PC, Alienware): `fork-infra/windows/README.md`.

## The stack

```
pingdotgg/t3code main     ← canonical upstream, several commits a day, never rewritten
        │
patched (this repo)       ← product patches, then ONE fork-infra commit
```

- **`patched`** — the branch we build. `git log upstream/main..patched` is the whole fork: the
  product-patch commits, and this directory as a single commit on top. A patch that is an open
  upstream PR is carried as that PR's commits, verbatim (never squashed): fix on the PR branch,
  then `git rebase --onto <PR branch> <old PR head> patched`.
- **Product patches** are debt we want to retire upstream. Each has an upstream issue, or an open
  upstream PR tied to an approved Ideas discussion, plus a drop row in the Quartermaster watch
  ledger. A patch offered upstream lives alone on its own branch (`main` + the patch; today
  `usage-group-by`, the branch of PR #15889) so upstream sees a clean diff.
- **Remotes:** `upstream` = pingdotgg/t3code, `origin` = astarktc/t3code (public fork, backup of
  `patched`). History before the stack moved onto `main` is preserved under the
  `archive/trial-*` tags on `origin` (including the worked migration-repair scripts).

Keep the stack consolidated: commit fork-infra edits as `git commit --fixup=':/^fork-infra:'`;
`update.sh` rebases with `--autosquash`, so they fold into the one fork-infra commit.

## Absorption checklist (run the scripts, never improvise)

1. `fork-infra/update.sh` — fetch, `--onto` rebase of exactly our commits, migration and
   auth-scope tripwires, backup push, `pnpm install`, packaged build. It **exits at a rebase conflict**; after
   resolving one, run its later steps by hand (the tripwire comparison is the one most easily
   skipped).
2. **Patch triage against the new base — by invariant and intent, not by conflict** (below).
3. **Verify**: `tsc --noEmit` in every package a patch touches, plus the suites covering them
   (`pnpm exec vp test run <paths>` from the app dir). If a test fails in a file you just
   resolved, **baseline first**: `git checkout <newbase> -- <files>`, re-run, restore with
   `git checkout HEAD -- …` — upstream ships red tests.
4. **Deploy** with `fork-infra/deploy.sh`: `--remote <host>` for other machines FIRST, `--local`
   (`--detach` from inside a T3-hosted thread) for the session host LAST.
5. **Record**: asar-hash parity on both Macs; prune superseded
   `~/.t3/userdata/statev2.sqlite.bak-*` on both, keeping the current schema's.

## `update.sh`

```
fork-infra/update.sh [--base <remote>/<branch>] [--old-base <sha>] [--no-build] [--install] [--no-push]
```

1. **Guard**: refuses to run on a dirty worktree.
2. **Rebase**: `git rebase --autosquash --onto <new base> <old base> patched`, replaying exactly
   our commits. The old base defaults to the merge-base with `upstream/main`, which cannot go
   stale because `main` is never rewritten. `--base` stacks on a long-lived upstream feature
   branch instead; such branches are force-pushed, so record the sha you sit on and pass
   `--old-base` at every absorption (squash merges mean the last head you rode is never an
   ancestor of the next base).
3. **Migration tripwires**: diffs the id/name table in
   `apps/server/src/persistence/Migrations.ts` between old and new base; warns on renumbered or
   removed migrations, and if the table can no longer be parsed at all. An **auth-scope
   tripwire** diffs the scope constants in `packages/contracts/src/auth.ts` and warns when
   upstream adds scopes (auth-scope hazard, below).
4. **Backup**: force-with-lease push of `patched` to `origin` (`--no-push` skips).
5. **Build**: unsigned arm64 packaged build with the publish-repo env vars unset, so
   electron-builder emits no `app-update.yml` and the updater self-disables; the bundle is
   checked for its absence. `--install` hands off to `deploy.sh --local`.

Gotchas encoded in the script: `~/.cargo/bin` on PATH (a native resource monitor needs cargo);
`pnpm install --config.confirmModulesPurge=false` (pnpm aborts headless when it wants to purge
`node_modules`). Commit fork-infra changes with `--no-verify` when the repo's pre-commit hook
gets in the way (it assumes app-code changes).

## Patch triage — invariants and intent, not conflicts

Both directions have bitten:

- **A clean replay is NOT evidence a patch is still complete.** Upstream can add a new site for
  the same concept and git replays the patch with zero conflicts while it silently stops
  covering its own invariant. **Grep the concept across the whole new base, not the hunk.**
- **A conflict does NOT mean the patch's intent is obsolete — often only its SHAPE is.** When
  upstream rewrites the file a patch touches, re-express the patch inside upstream's new
  structure; replaying the old structure reverts upstream's work.
- **A patch that changes a default keybinding does not reach installed hosts.** On first start
  the server writes every default into `~/.t3/userdata/keybindings.json`, and later starts never
  rebind a command that already has an entry (user customizations win). The client falls back
  to its built-in defaults only while the server config is missing, so the new key works briefly
  after launch and then stops. After deploying such a patch, rewrite that command's entry on every
  host (back up the file first; the server reloads it live), or rebind it in Settings → Keybindings.
- **Drop a superseded patch before running `update.sh`**, not mid-rebase:
  `git rebase -i <old-base> patched` with the patch set to `drop`, then
  `git diff <backup-ref> patched --stat` must list exactly that patch's files.

Per-patch invariants to grep on every new base:

- **Pi usage** (tracked in Ideas `pingdotgg/t3code#12288`): Pi is a `transcripts` usage
  reader on its driver, the shape upstream gave every provider in #17576. Grep: `"pi"` in
  `UsageProviderKind` (`packages/contracts/src/usage.ts`); `usage: piUsageReader` on `PiDriver`
  and `PiDriver` in both `BUILT_IN_USAGE_DRIVERS` and `BuiltInUsageReadersEnv`
  (`apps/server/src/provider/builtInDrivers.ts`; a driver missing from that list reads
  nothing, silently); in `packages/provider-pi/src/server/usage.ts`, `selectFields` covering
  every field the parser reads (a missing one drops the usage of oversized lines) and
  `mightCarryUsage` passing `session` and `model_change` lines (they carry the reducer
  state); the `./server/usage` package export and `TEST_FORMATS.pi`; the scan cache at v6
  (`usage-scan-cache-v6.json`, `PREVIOUS_SCAN_CACHE_FILE_NAMES`, and `SERVICE_TIER_SINCE_VERSION`
  so v5 Codex entries keep their resume position); the Pi record's fields matching
  `UsageRecord`; and both `usageProviders.ts` (web + mobile). Upstream adds usage providers
  regularly: expect a union-merge conflict in those lists, and grep every per-provider table
  upstream introduced. Drop the patch when upstream ships `pi` in `UsageProviderKind` itself.

## `deploy.sh` — the ONE installer, for both Macs

```
fork-infra/deploy.sh --local  [--zip <path>] [--detach] [--force] [--expect-asar <hash16>]
fork-infra/deploy.sh --remote <ssh-host> [--zip <path>] [--force]
```

Every install-step incident on record was a dispatch bug in a hand-written throwaway installer,
not a build bug (hazards 3, 4 and 6). This is the one committed, tested installer.

It refuses to do the wrong thing rather than trusting the operator: aborts on active
orchestration runs (`--force` overrides; a `--detach` self-install tolerates exactly one — its
own dispatching run), rejects an artifact carrying `app-update.yml`, refuses to overwrite a
bundle it could not prove had quit, verifies the installed asar hash equals the artifact's, and
after relaunch checks readiness, `serverVersion`, the migration ledger, `integrity_check`, and
that the app is still alive 20 s later. Every run tees to `/tmp/t3-deploy-<timestamp>.log` on
the machine being installed.

**Order: other machines first, the machine hosting your session LAST** — installing quits the
app, which ends any session running inside it (T3 resumes an interrupted Pi thread on the next
launch; only the dispatching tool call is lost).

```sh
# from the MBP (the build machine), after update.sh has produced release/*.zip
fork-infra/deploy.sh --remote mac-uni-auto   # work Mac: attached, full output here
fork-infra/deploy.sh --local                 # MBP last
fork-infra/deploy.sh --local --detach        # ... when dispatching from a Pi thread inside T3
fork-infra/install-from-inside.sh --repair <script> --expect-asar <hash16>   # quit → repair → deploy
# install-from-inside.sh gives deploy.sh the one-run --detach allowance (its own dispatching run);
# queued follow-ups from that same thread need --force, after checking they are that thread's.
```

## Migration hazard — rare on `main`, still checked every time

Effect's Migrator tracks progress by numeric id and runs only ids **greater than the ledger's
max**. Upstream rewriting already-applied migrations therefore breaks an installed DB in one of
two shapes:

| Ledger vs code                                       | Symptom                                                            | Repair                                                             |
| ---------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| existing migrations **renumbered** above the ledger  | migrations re-run → `table already exists` → crash-loop, no window | renumber the ledger, apply the inserted migrations by hand         |
| migrations **consolidated**, ledger max > code's max | silent: nothing runs, schema drifts                                | apply the inserted migrations by hand, rewrite the ledger to match |

`main` ships to every user, so it does not rewrite applied migrations — the hazard lived on the
force-pushed V2 preview branch (worked repair scripts: tag `archive/trial-2026-10-02`,
`trial-infra/fix-migration-*.sh`). It returns if we ever ride a feature branch with `--base`.

Repair pattern: quit the app; `sqlite3 .backup` the DB; verify the shifted migration bodies are
byte-identical between old and new base; apply what the inserted migrations do; rewrite
`effect_sql_migrations` (two-step offset update to dodge PK collisions); `PRAGMA
integrity_check`. Run it with the app **quit** and **before** the new build's first launch, on
every machine. A repair may legitimately **refuse** when an inserted migration backfills data by
logic not reproducible in SQL — then migrate by running the old build's logic, never by
guessing. Before writing one, check whether upstream already reconciles the shape
(`apps/server/src/persistence/reconcileV2PreviewMigration.ts` heals the V2-preview ledgers),
and dry-run `runMigrations()` on a `.backup` copy (a throwaway `@effect/vitest` test through
`NodeSqliteClient.layer({ filename })`).

The live DB is `~/.t3/userdata/statev2.sqlite`; `state.sqlite` is the frozen V1 file.

## Auth-scope hazard — new scopes strand every existing pairing

Upstream splits permissions into new scopes and never expands a stored grant. After a deploy
that adds scopes, every remote client paired earlier keeps its old grant and loses the features
behind the new scopes; Usage, for example, needs `diagnostics:read`. The client still shows
those controls, and the server denies them. Each host's own desktop session is exempt, because
it re-bootstraps on launch with the full set.

Re-pair each remote client **from an upgraded client**:

1. Mint a link on the host. On a Mac:
   `ELECTRON_RUN_AS_NODE=1 "/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)" "/Applications/T3 Code (Alpha).app/Contents/Resources/app.asar/apps/server/dist/bin.mjs" pair --label <client> --ttl 12h`.
   On Windows: `wps.sh <host> < windows/pair.ps1`.
2. The printed URL uses a LAN IP. Swap in the address the client already uses for that host
   (its tailnet name), then paste it via Add Environment; pairing the same environment
   replaces its grant.
3. Check `auth_sessions.scopes` on the host.

A client build that predates the split asks for the old scope list at token exchange. The
server grants only the intersection, so re-pairing that client changes nothing until the client
itself updates.

## Install and dispatch hazards (all handled by `deploy.sh`)

1. **`/Applications` is `sunlnk`** — the bundle directory cannot be unlinked, so
   `rm -rf "/Applications/T3 Code (Alpha).app"` guts the bundle and then fails, leaving an
   unlaunchable app. Clear the contents and `ditto` in place.
2. **`launchctl submit` implies KeepAlive** — launchd re-runs the installer every time it exits,
   and its first step quits the app: an endless quit loop that reads like a crash on startup
   (graceful `desktop.app` exit + `backendInstance.stop`). Cure: `launchctl remove <label>`,
   `pkill -f deploy.sh`. macOS has no `setsid(1)`; `nohup setsid …` exits 127 and installs
   nothing.
3. **`pgrep` cannot see the main Electron process** on macOS (only its Helper children), so a
   pgrep quit-guard always answers "gone". `deploy.sh` matches the executable path in
   `ps -o comm`. Verify any process guard against a _running_ app before trusting it.
4. **An unbounded readiness probe can hang a completed deploy** — a backend that has bound
   :3773 but is still starting holds a bare `curl` forever. Every probe is bounded; `SIGPIPE` is
   ignored before the `tee` fork. A lone stuck `curl` with `installed ✓` already logged is this.
5. **`nohup` does not survive the app quitting when dispatched from inside it** — the aborted
   tool call kills its whole process group. `--detach` and `install-from-inside.sh` re-exec
   through `perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV'`. Symptom: log stops mid-procedure,
   app back up on the OLD build, no `deploy.sh` process.
6. **`open -a` passes the caller's environment to the app** — a Pi thread hosted by T3 runs
   with `ELECTRON_RUN_AS_NODE=1`, so a relaunch from inside T3 starts T3 Code as a bare Node
   process that exits in ~30 ms with no `desktop.startup` span. `deploy.sh` scrubs every
   `ELECTRON_*`/`T3_*` variable before `open`, polls `app_running`, retries once, and waits on a
   300 s wall-clock readiness deadline; an "app did not launch" exit names the install as
   complete. General form: any agent inside T3 launching an Electron app via `open` inherits it.
7. **Every path the installer verifies is an upstream contract** — when upstream moved the
   orchestrator into `statev2.sqlite`, an installer still reading `state.sqlite` ran a vacuous
   active-run pre-flight and a stale ledger readout. When a verify reading stops changing across
   deploys, suspect the path, not the build; check `apps/server/src/config.ts` (`dbPath`) at
   each absorption.

## When something is wrong — fresh evidence first

Use today's `~/.t3/userdata/logs/server.trace.ndjson` and `desktop.trace.ndjson`.
`server-child.log` is NOT written by trace-era builds; its newest lines are from an old incident.
Check mtimes before believing any log. The server trace rotates (10 MB × 10 files) and holds only
the last ~40 min, so pull launch-time evidence right after the launch.

Triage order for "the app won't stay up":

1. **Graceful shutdown** (`desktop.app` exits `Success`, `backendInstance.stop`)? Something is
   _telling_ it to quit: `launchctl list | grep -i t3`, `pgrep -fl deploy.sh` (hazard 2).
2. **Backend dying** (readiness never 200, migration errors in today's traces)? Migration hazard.
3. **Won't launch at all**? Incomplete bundle — re-run `deploy.sh` (idempotent).
4. **Process appears and vanishes in milliseconds, no `desktop.startup` span**? Hazard 6.
5. **Deploy stalled with `installed ✓` logged**? Hazard 4.

A false provider-probe "timed out" at launch is an event-loop stall, not the provider: find the
long `sql.execute` (node:sqlite is synchronous) overlapping the probe span.

After `DEPLOY OK`, what is left for a human: a window appears and About shows the expected
version; the patches' features work (Pi appears in the Usage dashboard); both Macs report the
same asar hash.

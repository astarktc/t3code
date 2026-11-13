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
- **Product patches** come in two kinds (Quartermaster ADR-0011). An **upstream-bound fix** has an
  upstream issue or open PR and is dropped once upstream ships it. An **own quality-of-life patch**
  stays for as long as it serves us, whatever upstream decides. Every patch has a drop row in the
  Quartermaster watch ledger (trigger: upstream ships equivalent behaviour). Each patch also lives
  alone on its own reference branch (`main` + the patch; today `usage-model-family`,
  `auth-sliding-expiry`, `sidebar-collapse-pinned-patch`, `sidebar-collapse-drafts`,
  `claude-settings-provider-probe` (worktree `~/Projects/forks/t3code-pr2`), and
  `peer-link-sliding-expiry`, which stacks on the sliding pairing-session commit it builds on), so
  it can be offered upstream as a clean diff.
- **Remotes:** `upstream` = pingdotgg/t3code, `origin` = astarktc/t3code (public fork, backup of
  `patched`). History before the stack moved onto `main` is preserved under the
  `archive/trial-*` tags on `origin` (including the worked migration-repair scripts).

Keep the stack consolidated: commit fork-infra edits as `git commit --fixup=':/^fork-infra:'`;
`update.sh` rebases with `--autosquash`, so they fold into the one fork-infra commit. Outside
`update.sh`, autosquash onto the current base sha:
`GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash $(git merge-base patched upstream/main)`, never
onto `upstream/main` itself, which is often fetched ahead and silently moves the base. After any
rebase outside `update.sh`, run `pnpm install` once before parallel typechecks: `pnpm exec`
auto-installs in each shell, and the installs race.

**Reference branches** stay where they were last offered and lag `patched` in between. Before
offering a patch upstream, move its branch onto the current base, carrying over any conflict
resolution its `patched` commit got. `usage-model-family` is checked out in the worktree
`~/Projects/forks/t3code-pr1`, so move it there (`git reset --keep`), not with `git branch -f`.
To restack `patched` onto an already-rebased PR branch:
`update.sh --ticket <N> --base origin/usage-model-family --old-base <old PR head>`.

**Git hooks.** `fork-infra/githooks/pre-commit` runs gitleaks on the staged changes (warns and
passes when gitleaks is missing), then chains to upstream's Vite+ dispatcher
(`.vite-hooks/_/pre-commit` → `vp staged`). Enable it per clone from the main checkout with an
absolute path, so it also runs in the PR worktrees: `git config core.hooksPath
"$PWD/fork-infra/githooks"`. `vp config` (the `prepare` script) leaves a `core.hooksPath` it does
not own alone, so `pnpm install` cannot reset it. Rebase picks and autosquash fixups never run
pre-commit (only `git commit` does), so `update.sh` is unaffected.

## Absorption checklist (run the scripts, never improvise)

1. `fork-infra/update.sh --ticket <N>` — rollback branch `backup/pre-qm<N>` at the deployed head
   (pushed), fetch, `--onto` rebase of exactly our commits, migration and
   auth-scope tripwires, backup push, `pnpm install`, packaged build. It **exits at a rebase conflict**; after
   resolving one, run its later steps by hand (the tripwire comparison is the one most easily
   skipped). `main` moves several times a day, so an absorption can fall a few commits behind
   while it runs; `update.sh --ticket <N> --no-build` plus `git range-diff` absorbs that tail cheaply.
2. **Patch triage against the new base — by invariant and intent, not by conflict** (below).
3. **Verify**: `tsc --noEmit` in every package a patch touches, plus the suites covering them
   (`<repo>/node_modules/.bin/vp test run <paths>` from the app dir). Typecheck the way each
   package's `typecheck` script does, with the repo's own binary run from each package dir:
   `<repo>/node_modules/.bin/effect-tsgo tsrs --noEmit` (`apps/web` declares the same command
   as a Vite+ task in its `vite.config.ts`); count only `error TS` lines, since Effect's rules
   print suggestions too. `pnpm exec …` auto-installs in every shell, so parallel runs race;
   discard the `pnpm-lock.yaml` churn those auto-installs leave. If a test fails in a file you just
   resolved, **baseline first**: `git checkout <newbase> -- <files>`, re-run, restore with
   `git checkout HEAD -- …` — upstream ships red tests. Known local red: `ClaudeSkills.test.ts`
   "merges plugin enablement…" fails on pure upstream on the MBP while upstream CI is green
   (Quartermaster QM-327). Full-suite failures are not baselined (QM-230), so claim only the
   suites you ran. After upstream bumps Playwright, the browser project fails to launch until
   `node_modules/.bin/playwright install chromium-headless-shell` runs once from `apps/web`.
   Usage and Settings are route modals (`AppRouteModal` portals to `body`), so page tests read
   `[data-app-modal]`.
4. **Deploy** with `fork-infra/deploy.sh`: `--remote <host>` for other machines, `--local`
   (`--detach` from inside a T3-hosted thread) for the session host, in any order.
5. **Record**: asar-hash parity on both Macs. Rollback sets rotate on their own: `update.sh`
   keeps the newest 3 `backup/pre-qm*` branches and `windows/install.ps1` the newest 2
   `statev2.sqlite.bak-*` sets per Windows host, so nothing is pruned by hand. At one or two
   absorptions a day an older set is no realistic rollback: it drops days of upstream fixes, and
   restoring an older DB backup loses every thread since.
6. **Refresh our open upstream PRs** onto the base just absorbed
   (`gh pr list -R pingdotgg/t3code --author astarktc --state open`): rebase a branch that is ours
   alone and `--force-with-lease` it; on a branch a maintainer has taken over, push only a plain
   merge of `main`. A PR left behind gets `needs-rebase`, closes after 7 days in conflict, and an
   old one is bulk-closed (Quartermaster `research/dev-workflow_t3code-upstream-contribution.md`,
   lesson 6).

## `update.sh`

```
fork-infra/update.sh --ticket <N> [--base <remote>/<branch>] [--old-base <sha>] [--no-build] [--install] [--no-push] [--no-backup]
```

1. **Guard**: refuses to run on a dirty worktree.
   **Rollback branch**: creates `backup/pre-qm<N>` at the current `patched` head, before the
   rebase, and pushes it to `origin`. `--ticket` takes the absorption's work item (`QM-380`,
   `qm380` or `380`) and is required unless `--no-backup`. A branch of that name that already
   exists, here or on `origin`, stays where it is, so a re-run within one absorption
   (`--no-build` for the tail) keeps pointing at the deployed build; the script stops when the
   two copies disagree. The branch is the only way back to that build: a
   rebuild of the same version overwrites the release zip and the Windows exe under the same
   names, so a rollback rebuilds from it.
   **Rotation**: right after, it keeps the newest 3 `backup/pre-qm*` branches by ticket number,
   here and on `origin`, and deletes the older ones (`--no-push` deletes only local copies). The
   branch it just made is always kept. A build deployed outside an absorption (a patch added on
   the same base) gets no branch of its own; roll it back by reverting the patch.
2. **Rebase**: `git rebase --autosquash --onto <new base> <old base> patched`, replaying exactly
   our commits. The old base defaults to the merge-base with `upstream/main`, which cannot go
   stale because `main` is never rewritten. `--base` stacks on a long-lived upstream feature
   branch instead; such branches are force-pushed, so record the sha you sit on and pass
   `--old-base` at every absorption (squash merges mean the last head you rode is never an
   ancestor of the next base).
3. **Migration tripwires**: diffs the id/name table in
   `apps/server/src/persistence/Migrations.ts` between old and new base; warns on renumbered or
   removed migrations, and if the table can no longer be parsed at all. An **auth-scope
   tripwire** diffs the scope constants in `packages/contracts/src/auth.ts` and the members of
   `AuthStandardClientScopes`, and warns when upstream adds scopes or a new pairing starts
   granting more (auth-scope hazard, below).
4. **Backup**: force-with-lease push of `patched` to `origin` (`--no-push` skips this and the
   rollback branch's push).
5. **Build**: unsigned arm64 packaged build with the publish-repo env vars unset, so
   electron-builder emits no `app-update.yml` and the updater self-disables; `sign-mac.sh` then
   signs the zip's app with our Apple team identity (Code signing), and the bundle is checked for the
   feed's absence. `--install` hands off to `deploy.sh --local`.

Gotchas encoded in the script: `~/.cargo/bin` on PATH (a native resource monitor needs cargo);
`pnpm install --config.confirmModulesPurge=false` (pnpm aborts headless when it wants to purge
`node_modules`). With a self-managed pnpm, `pnpm install` adds `@pnpm/exe` to
`pnpm-lock.yaml`'s `packageManagerDependencies`; that is local noise, never committed, and it
trips the next run's dirty-worktree guard, so discard it after every install
(`git checkout -- pnpm-lock.yaml`). Commit fork-infra changes with `VP_GIT_HOOKS=0 git commit …` when upstream's `vp staged`
hook gets in the way (it assumes app-code changes); that keeps the gitleaks step, which
`--no-verify` would skip too.

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
  A client's shortcuts come from its primary (local) server's file.
- **Drop a superseded patch before running `update.sh`**, not mid-rebase:
  `git rebase -i <old-base> patched` with the patch set to `drop`, then
  `git diff <backup-ref> patched --stat` must list exactly that patch's files.

Per-patch invariants to grep on every new base:

- **Usage Group by: Model** (own quality-of-life patch; upstream closed its PR #18254 unmerged): a
  client-only grouping by model vendor beside the harness view. Grep: `usageModelFamily.ts`
  and its `./usageModelFamily` export in `packages/shared`; `families` and per-period
  `byFamily` in `mergeUsage` (`packages/shared/src/usageMerge.ts`), filled from the same
  bucket loop as `providers`/`byProvider`; every hand-built `DailyTotals`/`HourlyTotals`
  carrying `byFamily` (mobile's 24-hour chart builds one); `seriesFor` /
  `periodSeriesTotals` in web `usageProviders.ts`, used by `UsageProviderChart` and the
  page's rows and Day/Hour table; the summary rows ranked by the selected metric in both
  groupings (harness through upstream's `rankProvidersByMetric`, families through
  `rankSeriesByMetric`), while the chart and table keep reading order; `usage.group.harness` / `usage.group.family` in
  `STATIC_KEYBINDING_COMMANDS`, the `h`/`m` defaults, and `GROUP_BY_OPTIONS` in
  `usageShortcuts.ts` and the Settings order. When upstream adds a per-provider surface to
  the Usage page, it must take a `UsageSeries` too, or Model mode silently shows harness
  data there. The Usage header renders Group by leftmost and drops it and the period on
  Limits, so the metric tabs never move; `UsagePage.groupBy.browser.test.tsx` covers that order
  and the Limits header. Drop the patch if upstream ships its own model/vendor grouping on Usage.
- **Sliding pairing-session expiry** (own quality-of-life patch; branch `auth-sliding-expiry`,
  server-only, no migration): a paired client lapses only after `SESSION_IDLE_TTL` (90 days)
  idle, not a fixed term after pairing. Grep `apps/server/src/auth/SessionStore.ts`:
  `SESSION_IDLE_TTL` feeding `DEFAULT_SESSION_TTL`; `renewOnConnect` called from
  `markConnected` on every disconnected→connected transition, gated by
  `isSlidingSessionMethod` (cookie and bearer slide, DPoP keeps its fixed deadline); `verify`
  reading the deadline from the stored row (`row.value.expiresAt`), never from the token's
  `exp` claim; `AuthSessionRepository.renewExpiry` in `persistence/AuthSessions.ts` (`expires_at
  < new` guard, so renewal never shortens). Every other reader of `expires_at`
  (`loadActiveSession`, `listActive`, `verifyWebSocketToken`, `awaitInvalidation`) already reads
  the row. If upstream adds a second place that trusts `claims.exp`, or a new connect path that
  bypasses `markConnected`, the patch has stopped covering its invariant. Drop it when upstream
  ships renewable or sliding sessions.
- **Peer-link sliding expiry** (own quality-of-life patch; branch `peer-link-sliding-expiry`,
  stacked on the sliding pairing-session commit, whose `renewExpiry`, `SESSION_IDLE_TTL` and
  row-owned `verify` it reuses; server-only, no migration, no contract change): a linked
  environment's link lapses only after 90 days unused, on both machines. MCP client sessions
  never open the RPC WebSocket, so `markConnected` never renews them. Grep the target side:
  `MCP_CLIENT_SESSION_TTL = SessionStore.SESSION_IDLE_TTL` and `authenticateMcpClient` calling
  `sessions.renewOnUse` (`auth/EnvironmentAuth.ts`; `rejectMcpClientAudience` refuses MCP client
  sessions everywhere else); `renewOnUse` in `SessionStore.ts`, gated by `isSlidingSessionMethod`
  and the `SESSION_USE_RENEWAL_INTERVAL` (1 h) throttle, renewing through `renewOnConnect`;
  `withSessionExpiry` in `mcp/McpHttpServer.ts`'s auth middleware, reading the admitted
  invocation's `client` (the mode ceiling is applied inside `authenticateRequest`), setting
  `SESSION_EXPIRES_AT_HEADER` (`t3-session-expires-at`, `mcp/McpInvocationContext.ts`) from
  `McpClientCaller.expiresAt`, which `McpOAuth.layerMcpClientAuthenticator` fills. The driver
  side: `PeerMcpClient.call` reading the header off the tool-call answer (`reportedExpiry`) into
  `PeerLinks.extendExpiry` (`expires_at <` guard, so it never shortens). If upstream adds a
  second path that authenticates MCP client sessions, or a driver-to-peer call path beside
  `PeerMcpClient.call`, the patch has stopped covering its invariant. Drop it when upstream ships
  renewable or sliding MCP/peer-link sessions; if the sliding pairing-session patch drops first,
  re-express this one on upstream's renewal.
- **Collapsible Pinned** (own quality-of-life patch; upstream closed PR #19690 unmerged as
  stale, head `0c586b3e0a`; branch `sidebar-collapse-pinned-patch` carries its diff as one
  commit; web-only): the Pinned
  shelf collapses like Working/Snoozed/Settled. Grep `apps/web/src/components/Sidebar.tsx`:
  `PINNED_SHELF_EXPANDED_KEY` (`t3code:sidebar:pinned-expanded`), `pinnedShelfExpanded` beside
  `workingShelfExpanded` at every site (the `routeThreadOnly` filter, the `useSidebarThreads`
  return, the `pinned-header` case rendering `CollapsibleSectionHeader` with
  `data-testid="sidebar-pinned-shelf-toggle"`), `collapsedPinnedOrder` passed into
  `resolveSidebarDropTarget` / `planSidebarThreadDrop` (`Sidebar.logic.ts`), and the
  pinned-toggle clamp in `createSidebarCollisionDetection` (`Sidebar.drag.ts`). The header
  carries `data-sidebar-row="shelf:pinned"` and no ARIA role, like the other shelves'
  `SidebarListMarkers.tsx` headers (since #26690 the threads sidebar has no `treeitem` roles,
  and its keyboard navigation finds rows by `data-sidebar-row`), and shows its count as the
  header accessory. When upstream changes the other shelf headers' attributes, Pinned's must
  follow. Upstream's Boring sidebar
  (project folders, #21039) renders Pinned through the same `pinned-header` case, with drag
  off, so it is not a separate site. When upstream
  adds a shelf-header site (a mobile sidebar, an extracted header component), Pinned must get
  the toggle there too. No command ids or keybindings. Drop it if upstream ships a collapsible
  Pinned shelf.
- **Collapsible Drafts** (own quality-of-life patch; branch `sidebar-collapse-drafts`; web-only):
  the unsent new-thread drafts at the top of the inbox sit under a **Drafts** header that
  collapses them to a count, like Pinned. Grep `apps/web/src/components/Sidebar.tsx`:
  `DRAFTS_SHELF_EXPANDED_KEY` (`t3code:sidebar:drafts-expanded`, default expanded),
  `draftsShelfExpanded` in `listMotionLayoutKey`, and `expanded` / `onToggleExpanded` passed
  to `SidebarDraftBlock`. In `sidebar/SidebarDraftBlock.tsx`: the `CollapsibleSectionHeader`
  with `data-sidebar-row="shelf:drafts"`, `data-testid="sidebar-drafts-shelf-toggle"` and
  the draft count as accessory, and `visibleDrafts` keeping only `routeDraftId` while
  collapsed. Drafts with an unsent reply in a started thread are composer state, not
  `draftThreadsByThreadKey` sessions, so they never reach this block. When upstream renders
  draft sessions anywhere other than `SidebarDraftBlock` (a folder view, mobile), that site
  needs the header too. Drop it if upstream ships collapsible drafts.
- **Claude `--settings` in the provider probe** (upstream-bound fix, issue #36279; branch
  `claude-settings-provider-probe`; server-only): a gateway profile passed only as the Claude
  instance's `--settings` launch arg (`env.ANTHROPIC_BASE_URL`, `apiKeyHelper`, `modelPicker`)
  reaches the status check and the model picker, not only turns. Grep: `readClaudeLaunchArgSettings`
  exported from `provider/Drivers/ClaudeSkills.ts` (one copy; the adapter imports it);
  `readClaudeSettingsEnv` layering the `--settings` env after the non-managed files and before
  `claudeManagedSettingsPath`; `claudeProbeLaunchArgSettings` in `provider/ClaudeProvider.ts`
  forwarding only validated `env`, `apiKeyHelper`, `modelPicker`, spread before
  `disableAllHooks: true` in `buildClaudeCapabilitiesProbeQueryOptions`. When #30127 merges it
  moves the same reader (the move should replay cleanly) and forwards `enabledPlugins` to the
  probe; both keys must then reach the probe's `settings`. If upstream adds another reader of
  Claude settings env, or a second probe, it needs the layer too. Drop it when upstream ships
  equivalent behaviour.
- **Short-lived Pi spawns stay offline** (upstream code since #30187, which was our patch; no
  longer carried). `rg -n 'buildPiRpcLaunch\(\{' -g '!*.test.ts' packages apps` lists every Pi
  spawn site (four today). Any new one that T3 stops once it has answered must pass
  `shortLived: true`, or it can lose a rotated OAuth refresh token (`invalid_grant`, QM-301);
  file that upstream.

## Upstream PR evidence — UI before/after on the same data

CONTRIBUTING asks UI PRs for before/after evidence. Capture `main` and the PR branch from dev
servers, one worktree each:

- **Fresh state per side:** `rm -rf .t3` in the worktree, then `pnpm dev` with the hosting T3's
  env stripped:
  `env -u ELECTRON_RUN_AS_NODE -u T3_MCP_URL -u T3_MCP_BEARER_TOKEN -u T3_PI_RUNTIME_MODE`.
  The pairing URL is in the dev log. A fresh link, from `apps/server`:
  `T3CODE_HOME=<worktree>/.t3 node src/bin.ts auth pairing create --ttl 15m --base-url <url>`.
- **Freeze the inputs**, or the totals drift between shots: Pi sessions grow while you capture.
  Point both servers at one APFS clone (`cp -cR ~/.pi/agent/sessions /tmp/<name>/`, then
  `PI_CODING_AGENT_SESSION_DIR=/tmp/<name>/sessions`), so a grouping change can be shown to
  match `main` to the cent.
- **Capture one side at a time.** Cookies are scoped by host, not port: two dev servers on
  `localhost` share one auth cookie, so pairing one signs the other out.
- **Sidebar/thread UI needs demo data, not ours.** `node apps/server/scripts/migrate-dev-db.ts`
  (server stopped) copies real projects into the worktree's `.t3`. Rename them and replace the
  threads with invented ones by writing `orchestration_v2_projection_threads` rows (copy a real
  row's `payload_json`, edit `pinnedAt` / `settledOverride` / `snoozedUntil`) before first start.
  For one diff, a single worktree is enough: `git stash` flips it to `main` under Vite HMR.
- **Capture with agent-browser at 2x.** `agent-browser --session <s> set viewport 1280 800 2`,
  `set media dark`, then full-viewport `screenshot` and crop with Pillow. Its element-selector
  screenshot did not resolve CSS selectors. The T3 preview panel captures only 1x, and on
  2026-10-14 it disconnected repeatedly mid-capture. Clicking a row's **Settle** button hangs its
  automation on `main` too, because of the sweep gesture.
- Before posting, check the page text and screenshots for private provider and project names.
  Host images on an orphan `assets-<branch>` branch of `origin` and embed the raw URLs.

## `deploy.sh` — the ONE installer, for both Macs

```
fork-infra/deploy.sh --local  [--zip <path>] [--detach] [--force] [--expect-asar <hash16>] [--allow-unsigned]
fork-infra/deploy.sh --remote <ssh-host> [--zip <path>] [--force] [--allow-unsigned]
```

Every install-step incident on record was a dispatch bug in a hand-written throwaway installer,
not a build bug (hazards 3, 4 and 6). This is the one committed, tested installer.

It finds the app by bundle id (`com.t3tools.t3code`), never by name. The bundle and executable
are named after upstream's `productName` ("T3 Code (Beta)" since 0.1.0), so a rebrand renames
the artifact's app. `deploy.sh` installs it into the existing bundle directory and renames
that directory to the new name where `/Applications` allows it. Where it does not (hazard 1),
the directory keeps its old name, and only the app inside changes.

It refuses to do the wrong thing rather than trusting the operator: aborts on active
orchestration runs (`--force` overrides; a `--detach` self-install tolerates exactly one — its
own dispatching run), rejects an artifact carrying `app-update.yml`, rejects an app not signed
with our Apple team identity (Code signing, below; `--allow-unsigned` overrides), refuses to overwrite a
bundle it could not prove had quit, verifies the installed asar hash equals the artifact's, and
after relaunch checks readiness, `serverVersion`, the migration ledger, `integrity_check`, and
that the app is still alive 20 s later. Every run tees to `/tmp/t3-deploy-<timestamp>.log` on
the machine being installed.

The active-run guard counts `queued` runs too. A run that is queued for hours while nothing is
running is an orphan, not work: a scheduled thread can deliver twice, and the second run queues
behind a sibling that then fails, and survives restarts (`select run_id, status from
orchestration_v2_projection_runs where status in ('queued','running')` on the host's DB). Pass
`--force` for that case once the query shows no `running` row. Never `--force` past another
thread's running run without the operator's word; wait for the host to go idle instead. One
orphan has occurred (work Mac, 2026-10-28). A second on any host is the trigger to file the
non-draining queued run upstream, with the run rows and the matching
`scheduled_task_webhook_deliveries` rows as evidence (Quartermaster QM-288).

**Order does not matter.** Installing on the machine hosting your session quits the app and
cuts off the dispatching tool call, and T3 resumes the thread where it left off on relaunch, so
the session host can go first while another host waits for its active runs to finish.

```sh
# from the MBP (the build machine), after update.sh has produced release/*.zip
fork-infra/deploy.sh --remote mac-uni-auto   # work Mac: attached from a terminal (agents: below)
fork-infra/deploy.sh --local                 # MBP
fork-infra/deploy.sh --local --detach        # ... when dispatching from a Pi thread inside T3
fork-infra/install-from-inside.sh --repair <script> --expect-asar <hash16>   # quit → repair → deploy
# install-from-inside.sh gives deploy.sh the one-run --detach allowance (its own dispatching run);
# queued follow-ups from that same thread need --force, after checking they are that thread's.
```

**From an agent's tool call, run anything that can outlast the call in its own session.** An
agent's shell call ends at its tool timeout (typically 600 s), and the abort kills the call's
whole process group, `&` background jobs included (hazard 5). `deploy.sh --remote mac-uni-auto` waits out the
work Mac's `integrity_check` of its ~10 GB DB after relaunch (minutes when the host is busy), and `wps.sh <host> < install.ps1` runs for
minutes per Windows host, so an attached run can be cut off after the host's work is done, and
its final report is lost. Start such runs under `setsid` with a log, then poll in short calls:

```sh
perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' fork-infra/deploy.sh --remote mac-uni-auto \
  > /tmp/t3-remote-uni.log 2>&1 < /dev/null &
# wps.sh the same way, with `< install.ps1` REPLACING `< /dev/null` (a second stdin redirect
# wins silently and the host runs an empty script); then `tail` the log in short calls
```

If a call was cut off anyway, read the host's own log before re-running anything
(`/tmp/t3-deploy-*.log` on a Mac, `%TEMP%\t3-install-*.log` on Windows) and verify the installed
asar hash, readiness, ledger and integrity on the host.

## Code signing — our Apple team identity keeps privacy grants and Keychain access

Upstream's unsigned build is ad-hoc signed: its designated requirement is the build's cdhash,
so every deploy is a new program to macOS. Privacy (TCC) grants and Keychain ACLs record the
designated requirement, so each install re-prompts for every folder or device grant and for the
"t3code Safe Storage" item (Electron `safeStorage`, holding saved environments' bearer tokens).
The grants include Pi's, because T3 runs Pi under its own executable (`ELECTRON_RUN_AS_NODE`).
That item is a legacy login-keychain item, so it also has a **partition list**, which admits code
by Team ID, or, for code without one, by per-build `cdhash:` ID. A self-signed certificate never
carries a Team ID, so it fixes TCC and the ACL but still prompts once per deploy. Only an
Apple-issued certificate removes that prompt.

`update.sh` builds unsigned, then `fork-infra/sign-mac.sh <zip>` re-signs the app inside the zip,
in place. It signs the `Contents/Frameworks` bundles and their Mach-O files deepest first, then
the app, with no hardened runtime and no entitlements. Mach-O files under `Contents/Resources`
keep their own signatures and are sealed as resources. The designated requirement pins the
**team**, not one certificate:
`identifier "com.t3tools.t3code" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = N66437Y9GD`
(the helpers carry the same with their own identifiers). A renewed or re-issued certificate of
the team therefore keeps every grant. The script picks the newest valid Apple Development
identity whose certificate OU is the team, and it verifies the Team ID and every requirement.
Upstream's signed path (`T3CODE_DESKTOP_SIGNED`) is not used: it wants a Developer ID, a
provisioning profile and passkey entitlements. `deploy.sh` refuses an app without the team
requirement, and checks it again after install. The dmg stays unsigned; nothing installs from it.

| | |
| --- | --- |
| Identity | `Apple Development: <operator's Apple ID> (SGXP9K48V2)`, the operator's free Apple personal team **N66437Y9GD**; certificate valid to 2027-11-08 |
| Where | the MBP's login keychain (the build machine), created by Xcode → Settings → Accounts. The work Mac installs the MBP-built zip and needs no key. |
| Chain | Apple's WWDR G3 intermediate (`https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer`) in the login keychain. Without it `find-identity -v` lists 0 valid identities and codesign fails with errSecInternalComponent. |
| Backup | none needed: Xcode issues a new certificate of the same team at any time, and the requirement pins the team. |

**Renewal** (before 2027-11-08, or on a new build Mac): Xcode → Settings → Accounts → (Personal
Team) → Manage Certificates → + → Apple Development. Nothing in the scripts changes, and no
grant resets. A different team (a paid Developer Program team has its own id) means a new
`TEAM_ID` in `sign-mac.sh` and `deploy.sh`, and one round of prompts on every host.

**Switching signatures costs one round of prompts per host**: macOS asks again for each folder,
device and Accessibility grant, and the Keychain asks once for "t3code Safe Storage" (answer
Always Allow). Later builds of the team cost nothing. A rollback to an artifact with another
signature (`--allow-unsigned`) pays the switch again.

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
and dry-run the new migrations on copies first: `fork-infra/dry-run-migrations.sh <copy>...`
opens each copy through the server's real startup layer and reports the ledger, the
migration time and `integrity_check` (how to make the copies: the script's header).

Since upstream `bf8ffe81a6` the server refuses to start (`BadState`) when a recorded migration id
55 or above carries a name different from the code's, so a ledger renamed by a repair script
crash-loops instead of silently drifting.

The live DB is `~/.t3/userdata/statev2.sqlite`; `state.sqlite` is the frozen V1 file.

## Auth-scope hazard — new scopes strand every existing pairing

Upstream splits permissions into new scopes and never expands a stored grant. After a deploy
that adds scopes, every remote client paired earlier keeps its old grant and loses the features
behind the new scopes; Usage, for example, needs `diagnostics:read`. Upstream can also widen
what a pairing grants by moving existing scopes into `AuthStandardClientScopes` (#20432 added
`access:read`, `access:write` and `relay:write`). `update.sh` warns on both. The client still
shows those controls, and the server denies them. Each host's own desktop session is exempt, because
it re-bootstraps on launch with the full set.

Re-pair each remote client **from an upgraded client**:

1. Mint a link on the host. On a Mac:
   `APP=$(ls -d /Applications/T3\ Code*.app | head -1)` (the bundle's name varies, hazard 1), then
   `ELECTRON_RUN_AS_NODE=1 "$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)" "$APP/Contents/Resources/app.asar/apps/server/dist/bin.mjs" pair --label <client> --ttl 12h`.
   On Windows: `wps.sh <host> < windows/pair.ps1`.
2. The printed URL uses a LAN IP. Swap in the address the client already uses for that host
   (its tailnet name), then paste it via Add Environment; pairing the same environment
   replaces its grant.
3. Check `auth_sessions.scopes` on the host.

A client build that predates the split asks for the old scope list at token exchange. The
server grants only the intersection, so re-pairing that client changes nothing until the client
itself updates.

**Pairings also expire — after 90 days idle.** Our build slides a paired session's
`auth_sessions.expires_at` to connect time + `SESSION_IDLE_TTL` (90 days) on every client
connect (patch-triage list, "Sliding pairing-session expiry"); upstream's own sessions are a
fixed term with no renewal. Since upstream #17370 an open connection drops at expiry, so a
client left unconnected for 90 days must be re-paired with the same steps. Linked environments
slide on use instead (at most hourly; patch-triage list, "Peer-link sliding expiry"): the
target's `T3 Code · <linking machine>` row moves to last use + 90 days, and the linking machine
copies that date into `peer_environment_links.expires_at` from each answer, so a link unused
for 90 days needs a new pairing code from its target. Check a host with
`sqlite3 ~/.t3/userdata/statev2.sqlite "select client_label, last_connected_at, expires_at from
auth_sessions where revoked_at is null"`: a session whose `expires_at` has not moved past its
issue-time value has not connected since this build was installed. Each host's own desktop
session is exempt, because it re-bootstraps at every launch. Listing links (Settings,
`t3_environment_links`) renews nothing; a real tool call over the link does.

## Install and dispatch hazards (all handled by `deploy.sh`)

1. **Our user may be unable to write `/Applications` on the work Mac.** `/Applications` is
   `root:admin 775`, and our user's `admin` membership there is not guaranteed (check with
   `id -Gn`). Without it the bundle directory is still ours, so its contents can be
   replaced, but the directory itself can be neither removed, renamed nor created: `rm -rf` on
   the bundle guts it and then fails, leaving an unlaunchable app. Clear the contents and
   `ditto` in place.
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
   process that exits in ~30 ms with no `desktop.startup` span; the thread's `PI_*` variables
   (`PI_OFFLINE`, `PI_SESSION_ID`, `PI_MODEL`, `PI_CACHE_RETENTION`) would reach every Pi the
   app starts. `deploy.sh` scrubs every `ELECTRON_*`/`T3_*`/`PI_*` variable before `open`, polls `app_running`, retries once, and waits on a
   300 s wall-clock readiness deadline; an "app did not launch" exit names the install as
   complete. General form: any agent inside T3 launching an Electron app via `open` inherits it.
7. **Every path the installer verifies is an upstream contract** — when upstream moved the
   orchestrator into `statev2.sqlite`, an installer still reading `state.sqlite` ran a vacuous
   active-run pre-flight and a stale ledger readout. When a verify reading stops changing across
   deploys, suspect the path, not the build; check `apps/server/src/config.ts` (`dbPath`) at
   each absorption.

## Host model preferences — `model-prefs.mjs`

`node fork-infra/model-prefs.mjs` writes the canonical model preferences (favourites in order,
visible-only rows, hidden ids, the new-thread default and the text-generation model) into the
host's `~/.t3/userdata/settings.json`; the server watches the file, so no restart. It is
idempotent and keeps every other key. The set is the same on all four hosts. Only the budget
router's `auto/*` models are visible, and new threads start on `auto/opus-5-5`. Each auto
model picks subscription or Cortex per request (QM-306). Text generation runs on the built-in
`openai/gpt-6-luna`: T3 starts text-generation Pi with `--no-extensions`, where the
extension-registered `auto/*` and `cortex*/*` models do not exist, and a failed title silently
keeps the raw first prompt (QM-325). The physical `anthropic/*`, `openai/*` and `cortex*/*` rows
are hidden but still addressable by name. Copy it to a
remote host with `scp` and run it there; edit the script, not the hosts, when the canonical set
changes.

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

Other symptoms, and where to look first:

- **A feature disappeared** → upstream's settings defaults, before the patch list: a default
  flip is invisible in the carried diff.
- **A thread says "Continue where you left off." after a deploy or restart** → upstream #18461
  defaults `continueThreadsAfterServerUpdate` to true (at most 3 chained continuations; skipped
  while a thread waits on the user). Turn it off in Settings if unwanted.
- **A shortcut works briefly after launch, then stops** → the keybinding hazard (Patch triage).
- **A remote environment lost Usage, file views or settings after an upgrade** → the auth-scope
  hazard: re-pair that client, then check `auth_sessions.scopes` on the host.
- **A paired client disconnected and cannot reconnect** → it sat idle 90 days (Pairings also
  expire): check `expires_at` and `last_connected_at` on the host, and re-pair.
- **Unknown "LAN · found automatically" routes on a remote environment** → the server host's
  virtual adapters (VirtualBox host-only 192.168.56.x, Windows Mobile hotspot 192.168.137.x, a
  VPN or security client's utun in 198.18.0.0/15), which upstream advertises (#17246). They are
  unreachable but harmless while a working route exists.
- **`deploy.sh` aborts on active runs while the host looks idle** → the orphan query in the
  `deploy.sh` section.
- **Windows** symptoms (a silent `install.ps1`, `FAILED:` on a native command's progress output)
  → `windows/README.md`.

After `DEPLOY OK` nothing is routinely left for a human. The agent compares the asar hash
across both Macs, and each patch's feature is proven by its tests at absorption (Group by:
Model: `UsagePage.groupBy.browser.test.tsx`, real Chromium). Ask the operator for a hand check
only when a change has a visible effect that no test covers.

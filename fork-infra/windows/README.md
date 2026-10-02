# fork-infra/windows — Windows remote environments

The Gaming PC (`ssh gpc`) and the Alienware (`ssh alien`) run a Windows build of the fork
as **network-accessible T3 servers on :3773**, paired into the MBP app as remote
environments. They are not part of the absorption pipeline (`deploy.sh` is macOS-only):
they are rebuilt on demand with the steps below, from the same `patched` branch the Macs run.

## Build (on the Gaming PC — `C:\src\t3code`)

Build from `patched` (after `update.sh` has pushed it to `origin`).

Toolchain on the GPC: Node 26, pnpm 11.10.0 (npm global), Rust stable-msvc, VS 2022 Build
Tools (VCTools workload + `VC.Runtimes.x86.x64.Spectre`), Python 3.13 (user scope). The
build script's preflight names anything missing.

From the MBP: `./wps.sh gpc < build.ps1` (fetch `origin/patched`, install, build; ~5 min, and
the output arrives only at the end). Stage the installer with matching hashes on each host's
`%TEMP%`, then upgrade each one (next section). By hand on the GPC, the equivalent is:

```powershell
cd C:\src\t3code; git fetch --depth 1 origin patched; git checkout -B patched FETCH_HEAD
$env:Path = "$env:LOCALAPPDATA\Programs\Python\Python313;$env:APPDATA\npm;$env:USERPROFILE\.cargo\bin;$env:Path"
pnpm install --frozen-lockfile --config.confirmModulesPurge=false
pnpm dist:desktop:win:x64   # -> release\T3-Code-<ver>-x64.exe (~8 min)
```

## Upgrade an installed host (from the MBP)

1. No active runs on the host, and its migration ledger checked: `scp` its
   `.t3/userdata/statev2.sqlite*` to the MBP, read `effect_sql_migrations`, and dry-run the
   new build's `runMigrations()` on a `.backup` copy (`fork-infra/README.md`, migration
   hazard section). Windows hosts skip absorptions, so their ledgers lag the Macs'. The dry
   run is redundant only when `git diff --quiet <host's base> <new base> --
   apps/server/src/persistence/` holds and the ledger already matches: then the new build
   runs the migration code the host's last launch already accepted.
2. Copy `T3-Code-<ver>-x64.exe` into the host's `%TEMP%` (`scp … 'alien:AppData/Local/Temp/'`;
   the Alienware gets it via the MBP from the Gaming PC).
3. `wps.sh <host> < install.ps1` — quits the app, backs up `statev2.sqlite`, installs
   silently, refuses an `app-update.yml`, relaunches via the logon task, waits for readiness
   and checks the app survives 20 s.
4. Verify from the MBP: the health-check URL below reports the new `serverVersion`, and the
   pulled DB shows the expected ledger and `integrity_check` ok.

## First install + launch (per machine, from the MBP)

`wps.sh <host> < script.ps1` runs a PowerShell script over SSH with errors rendered as
text (raw `powershell -Command` over Windows OpenSSH hides them in CLIXML).

1. Copy the installer over and run it silently (`/S`); it installs per-user to
   `%LOCALAPPDATA%\Programs\t3code`. The artifact carries no `app-update.yml`, so the
   updater stays off.
2. `wps.sh <host> < setup.ps1` — writes `serverExposureMode: network-accessible`, adds an
   inbound firewall rule for the app, scoped to the tailnet (`100.64.0.0/10`), registers
   the **"T3 Code (Alpha)" logon task**, starts it, and waits for readiness.
3. `wps.sh <host> < pair.ps1` — mints a 12 h pairing link (`/pair#token=…`); paste it into
   the MBP app's add-environment flow.

Launch facts:

- The app must run in the **console session**. A process started from SSH lives in the
  SSH logon session and dies with it. The logon task (Interactive principal,
  `ExecutionTimeLimit 0` — the default would kill it after 3 days — battery-safe, a single
  instance) is both autostart and the way to start it remotely (`Start-ScheduledTask`).
- The task principal must be `COMPUTERNAME\user`. `USERDOMAIN` reads `WORKGROUP` inside
  SSH sessions.
- JSON written from PowerShell 5.1 must be BOM-free (`[IO.File]::WriteAllText` with
  `UTF8Encoding($false)`).

Health check from the MBP: `curl http://alex-gpc23:3773/.well-known/t3/environment` /
`http://desktop-mlolprc:3773/...` — the endpoint returns 200 with `serverVersion`. State and
traces live in `%USERPROFILE%\.t3\userdata\` (`statev2.sqlite`, `logs\server.trace.ndjson`).

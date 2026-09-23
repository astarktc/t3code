# trial-infra/windows — one-shot Windows remote environments

The Gaming PC (`ssh gpc`) and the Alienware (`ssh alien`) run a Windows build of the fork
as **network-accessible T3 servers on :3773**, paired into the MBP app as remote
environments. They are deployed **once** and are not refreshed at absorptions — the next
update is the switch to release builds when V2 + the Pi provider merge to upstream main.

## Build (on the Gaming PC — `C:\src\t3code`)

Branch **`trial-win`** = `trial` + one Windows-only fix: `resolveUserDataPath` does async fs
on win32, so Electron emits `ready` before the Clerk bridge calls
`registerSchemesAsPrivileged` and every Windows launch exits with
`DesktopClerkBridgeInitializationError` (`DesktopClerk.ts` provides a synchronous
`node:fs` FileSystem for that one call). Rebase it onto `trial` before any rebuild; drop
it when upstream fixes the ordering (#13195).

Toolchain on the GPC: Node 26, pnpm 11.10.0 (npm global), Rust stable-msvc, VS 2022 Build
Tools (VCTools workload + `VC.Runtimes.x86.x64.Spectre`), Python 3.13 (user scope). The
build script's preflight names anything missing.

```powershell
cd C:\src\t3code; git fetch --depth 1 origin trial-win; git checkout -B trial-win FETCH_HEAD
$env:Path = "$env:LOCALAPPDATA\Programs\Python\Python313;$env:APPDATA\npm;$env:USERPROFILE\.cargo\bin;$env:Path"
pnpm install --frozen-lockfile; pnpm dist:desktop:win:x64   # -> release\T3-Code-<ver>-x64.exe
```

## Install + launch (per machine, from the MBP)

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

# install.ps1 — upgrade an already-set-up Windows host to the installer in $env:TEMP.
# Run from the MBP:  ./wps.sh <host> < install.ps1   (copy T3-Code-<ver>-x64.exe to the
# host's %TEMP% first). Quits the app, backs up statev2.sqlite, installs silently, refuses
# an app-update.yml, relaunches via the logon task, waits for readiness, checks 20 s survival.
# Before running: no active runs on the host, and a dry run of the new migrator on a copy of
# its statev2.sqlite (fork-infra/README.md, migration hazard section).
$ErrorActionPreference = 'Stop'
$exe = (Get-ChildItem "$env:TEMP\T3-Code-*-x64.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if (-not $exe) { throw "no installer in TEMP" }
"installer: $exe"
$app = "$env:LOCALAPPDATA\Programs\t3code"
$ud  = "$env:USERPROFILE\.t3\userdata"
Stop-ScheduledTask -TaskName "T3 Code (Alpha)" -ErrorAction SilentlyContinue
Get-Process | Where-Object { $_.Path -like "$app*" } | Stop-Process -Force
for ($i=0; $i -lt 30 -and (Get-Process | Where-Object { $_.Path -like "$app*" }); $i++) { Start-Sleep 1 }
if (Get-Process | Where-Object { $_.Path -like "$app*" }) { throw "app did not quit" }
"quit ok"
$bak = "$ud\statev2.sqlite.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item "$ud\statev2.sqlite" $bak; foreach ($s in '-wal','-shm') { if (Test-Path "$ud\statev2.sqlite$s") { Copy-Item "$ud\statev2.sqlite$s" "$bak$s" } }
"db backed up -> $bak"
$p = Start-Process $exe -ArgumentList '/S' -Wait -PassThru
"installer exit $($p.ExitCode)"
Get-ChildItem $app -Recurse -Filter app-update.yml | ForEach-Object { throw "app-update.yml present: $($_.FullName)" }
(Get-Item "$app\T3 Code (Alpha).exe").VersionInfo.ProductVersion
Get-Process | Where-Object { $_.Path -like "$app*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2
Start-ScheduledTask -TaskName "T3 Code (Alpha)"
$ok = $false
for ($i=0; $i -lt 150; $i++) { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 http://127.0.0.1:3773/.well-known/t3/environment; if ($r.StatusCode -eq 200) { $ok=$true; break } } catch {}; Start-Sleep 2 }
if (-not $ok) { throw "readiness never 200" }
"readiness 200 after ~$($i*2)s: " + ($r.Content | ConvertFrom-Json).serverVersion
Start-Sleep 20
if (-not (Get-Process | Where-Object { $_.Path -like "$app*" })) { throw "app died within 20s" }
"stable 20s"

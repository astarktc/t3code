# install.ps1 — upgrade an already-set-up Windows host to the installer in $env:TEMP.
# Run from the MBP:  ./wps.sh <host> < install.ps1   (copy T3-Code-<ver>-x64.exe to the
# host's %TEMP% first). Quits the app, backs up statev2.sqlite, installs silently, refuses
# an app-update.yml, re-points the logon task and the firewall rule at the installed exe,
# relaunches via the logon task, waits for readiness, checks 20 s survival.
# Before running: no active runs on the host, and a dry run of the new migrator on a copy of
# its statev2.sqlite (fork-infra/README.md, migration hazard section).
$ErrorActionPreference = 'Stop'
# wps.sh returns output only when the script ends, so a hung run shows nothing on the MBP.
# The transcript shows how far it got: Get-Content $env:TEMP\t3-install-*.log on the host.
Start-Transcript -Path "$env:TEMP\t3-install-$(Get-Date -Format yyyyMMdd-HHmmss).log" | Out-Null
$exe = (Get-ChildItem "$env:TEMP\T3-Code-*-x64.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if (-not $exe) { throw "no installer in TEMP" }
"installer: $exe"
$app = "$env:LOCALAPPDATA\Programs\t3code"
$ud  = "$env:USERPROFILE\.t3\userdata"
$task = "T3 Code"
# The exe is named after upstream's productName ("T3 Code (Alpha).exe" until 0.1.0,
# "T3 Code (Beta).exe" since), and older setups named the task after it too.
# Bounded: Stop-ScheduledTask once hung an upgrade indefinitely (Alienware, 2026-10-19).
# The app is killed below either way.
$stop = Start-Job { Get-ScheduledTask -TaskName "T3 Code*" -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue }
if (-not (Wait-Job $stop -Timeout 60)) { "Stop-ScheduledTask still running after 60 s; killing the app directly"; Stop-Job $stop }
Remove-Job $stop -Force
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
$appExe = (Get-ChildItem "$app\T3 Code*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if (-not $appExe) { throw "no T3 Code*.exe in $app" }
"app: $appExe $((Get-Item $appExe).VersionInfo.ProductVersion)"
Get-Process | Where-Object { $_.Path -like "$app*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2
# Both name the exe by path, so a renamed exe needs them re-pointed. Same as setup.ps1.
Get-NetFirewallRule -DisplayName "T3 Code server (tailnet)" -EA SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "T3 Code server (tailnet)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3773 -RemoteAddress 100.64.0.0/10 -Program $appExe -Profile Any | Out-Null
$me = "$env:COMPUTERNAME\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $appExe
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Get-ScheduledTask -TaskName "T3 Code*" | Where-Object { $_.TaskName -ne $task } | Unregister-ScheduledTask -Confirm:$false
"task '$task' and firewall rule -> $appExe"
Start-ScheduledTask -TaskName $task
$ok = $false
for ($i=0; $i -lt 150; $i++) { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 http://127.0.0.1:3773/.well-known/t3/environment; if ($r.StatusCode -eq 200) { $ok=$true; break } } catch {}; Start-Sleep 2 }
if (-not $ok) { throw "readiness never 200" }
"readiness 200 after ~$($i*2)s: " + ($r.Content | ConvertFrom-Json).serverVersion
Start-Sleep 20
if (-not (Get-Process | Where-Object { $_.Path -like "$app*" })) { throw "app died within 20s" }
"stable 20s"
Stop-Transcript | Out-Null

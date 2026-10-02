# Configure + launch the T3 Code fork on a Windows host (see README.md). Run via: wps.sh <host> < setup.ps1
$exe = "$env:LOCALAPPDATA\Programs\t3code\T3 Code (Alpha).exe"
if (-not (Test-Path $exe)) { throw "not installed: $exe" }
$ud = "$env:USERPROFILE\.t3\userdata"
"pre-existing .t3: " + (Test-Path "$env:USERPROFILE\.t3")
New-Item -ItemType Directory -Force $ud | Out-Null
$ds = "$ud\desktop-settings.json"
$obj = if (Test-Path $ds) { Get-Content $ds -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$obj | Add-Member -NotePropertyName serverExposureMode -NotePropertyValue "network-accessible" -Force
[IO.File]::WriteAllText($ds, ($obj | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
"desktop-settings: " + (Get-Content $ds -Raw)
Get-NetFirewallRule -DisplayName "T3 Code server (tailnet)" -EA SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName "T3 Code server (tailnet)" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3773 -RemoteAddress 100.64.0.0/10 -Program $exe -Profile Any | Out-Null
"firewall rule: ok"
$me = "$env:COMPUTERNAME\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $exe
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "T3 Code (Alpha)" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "T3 Code (Alpha)"
$deadline = (Get-Date).AddSeconds(90); $ready = $false
while ((Get-Date) -lt $deadline) {
  try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 http://127.0.0.1:3773/.well-known/t3/environment; if ($r.StatusCode -eq 200) { $ready = $true; break } } catch {}
  Start-Sleep 2
}
"ready: $ready"
if ($ready) { $r.Content }
Get-Process | Where-Object { $_.Path -eq $exe } | Group-Object SessionId | % { "session $($_.Name): $($_.Count) procs" }
Get-NetTCPConnection -LocalPort 3773 -State Listen -EA SilentlyContinue | Select LocalAddress,OwningProcess
if (Test-Path "$ud\server-runtime.json") { Get-Content "$ud\server-runtime.json" -Raw }

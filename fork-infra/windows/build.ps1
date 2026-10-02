# build.ps1 — build the Windows installer from origin/patched on the Gaming PC.
# Run from the MBP:  ./wps.sh gpc < build.ps1   (~5 min; output arrives at the end)
# -> C:\src\t3code\release\T3-Code-<ver>-x64.exe, no app-update.yml (publish envs unset).
# ErrorActionPreference stays Continue: on PowerShell 5.1, git/pnpm progress on stderr
# under Stop becomes a terminating error whose CLIXML wps.sh filters out — the script
# would die silently with exit 1. Native steps are checked via $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
cd C:\src\t3code
git fetch --depth 1 origin patched 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { "FETCH FAILED $LASTEXITCODE"; return }
# -f: a build regenerates tracked files (AnnotationStyles.generated.ts), and this clone is
# build-only, so local changes are always build drift and must not block the checkout.
git checkout -f -B patched FETCH_HEAD 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { "CHECKOUT FAILED $LASTEXITCODE"; return }
git log --oneline -1
$env:Path = "$env:LOCALAPPDATA\Programs\Python\Python313;$env:APPDATA\npm;$env:USERPROFILE\.cargo\bin;$env:Path"
Remove-Item Env:GITHUB_REPOSITORY -ErrorAction SilentlyContinue
Remove-Item Env:T3CODE_DESKTOP_UPDATE_REPOSITORY -ErrorAction SilentlyContinue
pnpm install --frozen-lockfile --config.confirmModulesPurge=false 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 5
"pnpm install exit $LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { return }
# Upstream cross-builds Windows on Linux, where afterPack skips the prepared server compile
# cache; a native build adds those ~14 files and, since the transcription DLLs, exceeds the
# 80-file payload guard. Raise the guard in this build-only clone (README, "Payload guard").
$guard = 'scripts\build-desktop-artifact.ts'
$src = [IO.File]::ReadAllText("C:\src\t3code\$guard")
$raised = $src -replace 'WINDOWS_PACKAGED_PAYLOAD_FILE_LIMIT = \d+;', 'WINDOWS_PACKAGED_PAYLOAD_FILE_LIMIT = 120;'
if ($raised -ne $src) {
  [IO.File]::WriteAllText("C:\src\t3code\$guard", $raised, (New-Object System.Text.UTF8Encoding($false)))
  "payload guard raised to 120"
} else { "payload guard not found (upstream reshaped it) - building with upstream's limit" }
pnpm dist:desktop:win:x64 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 15
"dist exit $LASTEXITCODE"
Get-ChildItem release\*.exe | Select-Object Name, LastWriteTime, Length | Format-Table -AutoSize | Out-String

# Mint a 12 h pairing link for the running T3 server on a Windows host. Run via: wps.sh <host> < pair.ps1
$env:ELECTRON_RUN_AS_NODE = "1"
$app = "$env:LOCALAPPDATA\Programs\t3code"
# The exe is named after upstream's productName ("T3 Code (Beta).exe" since 0.1.0).
$exe = (Get-ChildItem "$app\T3 Code*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$bin = "$app\resources\server.asar\apps\server\dist\bin.mjs"
$out = "$env:TEMP\t3-pair-out.txt"
$p = Start-Process -Wait -PassThru -NoNewWindow $exe -ArgumentList "`"$bin`"","pair","--label","MBP","--ttl","12h" -RedirectStandardOutput $out -RedirectStandardError "$env:TEMP\t3-pair-err.txt"
Get-Content $out

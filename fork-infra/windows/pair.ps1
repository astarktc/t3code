# Mint a 12 h pairing link for the running T3 server on a Windows host. Run via: wps.sh <host> < pair.ps1
$env:ELECTRON_RUN_AS_NODE = "1"
$exe = "$env:LOCALAPPDATA\Programs\t3code\T3 Code (Alpha).exe"
$bin = "$env:LOCALAPPDATA\Programs\t3code\resources\server.asar\apps\server\dist\bin.mjs"
$out = "$env:TEMP\t3-pair-out.txt"
$p = Start-Process -Wait -PassThru -NoNewWindow $exe -ArgumentList "`"$bin`"","pair","--label","MBP","--ttl","12h" -RedirectStandardOutput $out -RedirectStandardError "$env:TEMP\t3-pair-err.txt"
Get-Content $out

#!/bin/bash
# run stdin as PowerShell on a Windows host; errors rendered as text on stdout
host=$1; body=$(cat)
script="\$ProgressPreference='SilentlyContinue'
& {
$body
} 2>&1 | Out-String -Width 220"
enc=$(printf '%s' "$script" | iconv -t UTF-16LE | base64 | tr -d '\n')
ssh -o ConnectTimeout=8 -o ServerAliveInterval=30 "$host" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" 2> >(grep -v -e CLIXML -e '<Objs' >&2)

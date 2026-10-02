#!/bin/bash
# Run stdin as PowerShell on a Windows host, errors rendered as text on stdout.
# The script travels over ssh's stdin, not the command line: Windows OpenSSH runs the
# remote command through cmd.exe, whose 8191-character limit an -EncodedCommand of
# install.ps1 exceeds ("The command line is too long."). A thrown error prints as
# "FAILED: …" and exits 1; raw PowerShell errors over ssh arrive as CLIXML on stderr.
# The base64 travels as ONE newline-terminated line read with ReadLine(): ReadToEnd()
# waits for stdin EOF, which Windows OpenSSH sometimes never delivers (the Alienware hung
# at 0 CPU before the script's first line).
host=$1; body=$(cat)
script="\$ProgressPreference='SilentlyContinue'
\$global:wpsFailed = \$false
& {
  try {
$body
  } catch {
    \"FAILED: \$(\$_.Exception.Message)\"
    \"\$(\$_.InvocationInfo.PositionMessage)\"
    \$global:wpsFailed = \$true
  }
} 2>&1 | Out-String -Width 220
if (\$global:wpsFailed) { exit 1 }"
{ printf '%s' "$script" | iconv -t UTF-16LE | base64 | tr -d '\n'; echo; } \
  | ssh -o ConnectTimeout=8 -o ServerAliveInterval=30 "$host" \
    'powershell -NoProfile -NonInteractive -Command "$s = [Console]::In.ReadLine(); Invoke-Expression ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($s.Trim())))"' \
    2> >(grep -v -e CLIXML -e '<Objs' >&2)

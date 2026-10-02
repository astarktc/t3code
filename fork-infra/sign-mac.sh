#!/usr/bin/env bash
# Sign the macOS app inside a build zip with our Apple Development identity, in place.
#
#   fork-infra/sign-mac.sh <release/T3-Code-*-arm64.zip>
#
# Why: upstream's unsigned build is ad-hoc signed, and its designated requirement
# is the build's cdhash, so every deploy is a new program to macOS. Privacy (TCC)
# grants and Keychain ACLs record the designated requirement, and a legacy Keychain
# item ("t3code Safe Storage", Electron safeStorage) also has a partition list that
# admits code by Team ID, or, for code without one, by per-build cdhash. A
# self-signed certificate never carries a Team ID, so only an Apple-issued
# certificate stops the per-deploy Keychain prompt (QM-352). T3 runs Pi under its
# own executable, so Pi's grants are T3's too.
#
# The designated requirement pins the TEAM, not one certificate:
#   identifier "com.t3tools.t3code" and anchor apple generic and
#   certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = <team>
# so a renewed or re-issued Apple Development certificate of the same team keeps
# every grant. The identity is picked by team; the newest valid one wins.
# README "Code signing" explains the identity and the one-time switching cost.
#
# Scope: the bundles in Contents/Frameworks (Electron Framework, helpers) and every
# Mach-O inside them, deepest first, then the app. Mach-O files under
# Contents/Resources (node addons, rg, the resource monitor) keep their own
# signatures and are sealed as resources. No hardened runtime and no entitlements:
# nothing is notarized, and the hardened runtime would deny the camera and
# microphone to the app and its children without entitlements.
# deploy.sh refuses an artifact this script has not signed.

set -euo pipefail

TEAM_ID="N66437Y9GD"   # the operator's Apple personal team (Xcode → Settings → Accounts)
BUNDLE_ID="com.t3tools.t3code"
TEAM_REQ="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '== %s\n' "$*"; }

ZIP="${1:?usage: fork-infra/sign-mac.sh <zip>}"
[[ -f "$ZIP" ]] || die "no such artifact: $ZIP"

# The newest valid Apple Development identity whose certificate's OU is our team.
pick_identity() {
  python3 - "$TEAM_ID" <<'PY'
import re, subprocess, sys
team = sys.argv[1]
valid = set(re.findall(r'\b([0-9A-F]{40})\b "Apple Development:',
    subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                   capture_output=True, text=True).stdout))
out = subprocess.run(["security", "find-certificate", "-a", "-Z", "-p", "-c", "Apple Development:"],
                     capture_output=True, text=True).stdout
best = None
for sha, pem in re.findall(r'SHA-1 hash: ([0-9A-F]{40}).*?(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)', out, re.S):
    if sha not in valid:
        continue
    info = subprocess.run(["openssl", "x509", "-noout", "-subject", "-enddate", "-nameopt", "sep_multiline"],
                          input=pem, capture_output=True, text=True).stdout
    if not re.search(r'^\s*OU=' + re.escape(team) + r'\s*$', info, re.M):
        continue
    end = subprocess.run(["date", "-j", "-f", "%b %d %T %Y %Z",
                          re.search(r'notAfter=(.*)', info).group(1).replace("  ", " "), "+%s"],
                         capture_output=True, text=True).stdout.strip() or "0"
    if best is None or int(end) > best[1]:
        best = (sha, int(end))
print(best[0] if best else "")
PY
}
IDENTITY_SHA1="$(pick_identity)"
[[ -n "$IDENTITY_SHA1" ]] || die "no valid Apple Development identity of team $TEAM_ID in this Mac's keychain.
  Do not ship an ad-hoc or self-signed build: the Keychain would prompt on every deploy.
  Create one: Xcode → Settings → Accounts → (Personal Team) → Manage Certificates → + → Apple Development.
  'Valid identities: 0' with the certificate present means Apple's WWDR G3 intermediate is missing (README, Code signing)."

EX=$(mktemp -d /tmp/t3code-sign.XXXXXX)
trap 'rm -rf "$EX"' EXIT
ditto -x -k "$ZIP" "$EX" || die "cannot extract $ZIP"
apps=("$EX"/*.app)
[[ ${#apps[@]} -eq 1 && -d "${apps[0]}" ]] || die "expected one .app in $ZIP"
APP="${apps[0]}"
FW="$APP/Contents/Frameworks"
[[ -d "$FW" ]] || die "no Contents/Frameworks in $(basename "$APP")"

# $1 = path; $2 = signing identifier for an explicit team requirement (bundles only).
sign() {
  local args=(--force --sign "$IDENTITY_SHA1" --timestamp=none)
  [[ -n "${2:-}" ]] && args+=(-r="designated => identifier \"$2\" and $TEAM_REQ")
  codesign "${args[@]}" "$1" 2>&1 | grep -v ': replacing existing signature$' || true
}
bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Resources/Info.plist" 2>/dev/null; }
by_depth() { awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-; }

# 1. Every Mach-O file inside the bundles, deepest first.
n=0
while IFS= read -r f; do
  [[ "$(file -b "$f")" == Mach-O* ]] || continue
  sign "$f"; n=$((n + 1))
done < <(find "$FW" -type f | by_depth)
# 2. The bundles themselves, deepest first; helper apps get the team requirement.
b=0
while IFS= read -r d; do
  if [[ "$d" == *.app ]]; then sign "$d" "$(bundle_id "$d")"; else sign "$d"; fi
  b=$((b + 1))
done < <(find "$FW" -type d \( -name '*.framework' -o -name '*.app' \) | by_depth)
# 3. The app.
sign "$APP" "$BUNDLE_ID"
log "signed $n Mach-O files, $b bundles and $(basename "$APP") with $IDENTITY_SHA1 (team $TEAM_ID)"

# Verify: the seal holds, the Team ID is recorded, and the app and every helper
# carry the team requirement.
codesign --verify --deep --strict "$APP" || die "signature does not verify"
[[ "$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$TEAM_ID" ]] \
  || die "the signature carries no Team ID $TEAM_ID"
designated() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
WANT="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and certificate leaf[subject.OU] = $TEAM_ID"
DR=$(designated "$APP")
[[ "$DR" == "$WANT" ]] || die "unexpected designated requirement: ${DR:-none}"
while IFS= read -r h; do
  [[ "$(designated "$h")" == *"certificate leaf[subject.OU] = $TEAM_ID" ]] \
    || die "$(basename "$h") does not carry the team requirement"
done < <(find "$FW" -maxdepth 1 -name '*.app')
log "designated requirement: $DR"

# Re-zip in place (same shape as electron-builder's zip: the .app at the top).
TMP_ZIP="$ZIP.signing.tmp"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP_ZIP" || die "re-zip failed"
mv -f "$TMP_ZIP" "$ZIP"
log "re-zipped $ZIP (sha256 $(shasum -a 256 "$ZIP" | cut -c1-16))"

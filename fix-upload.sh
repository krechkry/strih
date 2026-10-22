#!/bin/bash
# Re-signs an exported Bombocut.ipa so App Store Connect accepts it.
#
# Why: the team name "KRYŠTOF KRECHLER" has a letter with a háček. Xcode writes the signature's
# "designated requirement" with that letter in a different Unicode form than the certificate has,
# so Apple rejects the upload with "Invalid Signature (90035)". Known Apple bug (FB24633162,
# developer.apple.com/forums/thread/843700). This script signs again with a requirement that names
# the team by its ID (plain letters and digits) instead of by name, so the Š is never compared.
#
# Usage:
#   1. Xcode Organizer: Distribute App → Custom → App Store Connect → Export → save it.
#   2. ~/strih/fix-upload.sh path/to/Bombocut.ipa      (or no path: newest Bombocut.ipa on Desktop / Downloads)
#   3. Drag the new Bombocut-fixed.ipa into the Transporter app and press Deliver.
set -euo pipefail

IPA="${1:-}"
if [ -z "$IPA" ]; then
  IPA=$(ls -t ~/Desktop/*/Bombocut.ipa ~/Desktop/Bombocut.ipa ~/Downloads/*/Bombocut.ipa ~/Downloads/Bombocut.ipa 2>/dev/null | head -1 || true)
  [ -n "$IPA" ] || { echo "No Bombocut.ipa found. Export it from Xcode first, or pass its path."; exit 1; }
fi
[ -f "$IPA" ] || { echo "Not found: $IPA"; exit 1; }
IPA="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
echo "Using $IPA"
cd "$(dirname "$0")"

TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig 2>/dev/null | head -1)
TEAM="${TEAM:-4VB98YF5CY}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/ipa"
ditto -x -k "$IPA" "$WORK/ipa"
APP=$(ls -d "$WORK"/ipa/Payload/*.app | head -1)

# What Xcode produced (expected: "does not satisfy its designated Requirement")
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "Note: Xcode's signature already checks out locally. Re-signing anyway."
else
  echo "Xcode's signature fails the check, as expected. Fixing it."
fi

# The certificate the provisioning profile allows, if its private key is on this Mac.
security cms -D -i "$APP/embedded.mobileprovision" > "$WORK/profile.plist"
ALLOWED=$(/usr/bin/python3 - "$WORK/profile.plist" <<'PY'
import hashlib, plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
for c in p.get('DeveloperCertificates', []):
    print(hashlib.sha1(c).hexdigest().upper())
PY
)
IDENTITY=""
while read -r _ HASH NAME; do
  case "$NAME" in *"Apple Distribution"*|*"iPhone Distribution"*) ;; *) continue ;; esac
  if echo "$ALLOWED" | grep -qx "$HASH"; then IDENTITY="$HASH"; break; fi
done < <(security find-identity -v -p codesigning | grep -E '^ *[0-9]+\)')
if [ -z "$IDENTITY" ]; then
  echo
  echo "The distribution certificate's private key is not on this Mac (Xcode signed in the cloud)."
  echo "Fix: Xcode → Settings → Accounts → your team → Manage Certificates → + → Apple Distribution."
  echo "Then export the archive again and run this script on the new Bombocut.ipa."
  exit 1
fi
echo "Signing with certificate $IDENTITY (team $TEAM)"

# New build number, so it is always newer than anything uploaded before.
BUILD=$(date -u +%y%m%d%H%M)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Info.plist"

sign() {
  local item="$1" ident ent=""
  ident=$(codesign -d -v "$item" 2>&1 | sed -n 's/^Identifier=//p')
  [ -n "$ident" ] || ident=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$item/Info.plist" 2>/dev/null || basename "$item")
  codesign -d --entitlements - --xml "$item" > "$WORK/ent.plist" 2>/dev/null \
    || codesign -d --entitlements :- "$item" > "$WORK/ent.plist" 2>/dev/null || true
  if [ -s "$WORK/ent.plist" ]; then ent="$WORK/ent.plist"; fi
  local req="=designated => identifier \"$ident\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
  if [ -n "$ent" ]; then
    codesign -f -s "$IDENTITY" --timestamp=none --generate-entitlement-der --entitlements "$ent" -r "$req" "$item"
  else
    codesign -f -s "$IDENTITY" --timestamp=none -r "$req" "$item"
  fi
  rm -f "$WORK/ent.plist"
}

# inside first (frameworks, libraries, extensions), the app last
while IFS= read -r item; do
  sign "$item"
done < <(find "$APP" -depth -mindepth 1 \( -name "*.framework" -o -name "*.dylib" -o -name "*.appex" \))
sign "$APP"

codesign --verify --deep --strict "$APP"
echo "Signature checks out. Requirement now:"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  /p'

OUT="$(dirname "$IPA")/Bombocut-fixed.ipa"
rm -f "$OUT"
(cd "$WORK/ipa" && zip -qry "$OUT" .)
echo
echo "Done: $OUT  (build $BUILD)"
echo "Upload it with the Transporter app: sign in, drag the file in, press Deliver."
open -R "$OUT" 2>/dev/null || true

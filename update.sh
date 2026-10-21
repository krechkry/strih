#!/bin/bash
# Pull the newest Bombocut code and regenerate the Xcode project, keeping your signing team.
# Usage:  ~/strih/update.sh      then press ▶ in Xcode.
set -e
cd "$(dirname "$0")"

if [ ! -f Config/Local.xcconfig ]; then
  TEAM=$(grep -ho 'DEVELOPMENT_TEAM = [A-Z0-9]*' Bombocut.xcodeproj/project.pbxproj \
         ~/Downloads/strih-main/Bombocut.xcodeproj/project.pbxproj 2>/dev/null | head -1 | awk '{print $3}')
  if [ -n "$TEAM" ]; then
    echo "DEVELOPMENT_TEAM = $TEAM" > Config/Local.xcconfig
    echo "Saved your signing team ($TEAM)."
  else
    echo "No signing team found yet. Pick your Team once in Xcode (Signing & Capabilities), then run this again."
  fi
fi

# Xcode rewrites the string catalog while building (it adds the strings it finds in the code).
# Those edits are not yours, so drop them before pulling; the repo has the real translations.
git checkout -- Bombocut/Localizable.xcstrings 2>/dev/null || true
git pull --ff-only
xcodegen generate
echo "Up to date. Press ▶ in Xcode."

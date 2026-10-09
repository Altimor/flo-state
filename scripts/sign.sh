#!/bin/zsh
# Codesign an app bundle inside-out (Sparkle's helpers first, then the app).
# Ad-hoc by default; with DEVELOPER_ID="Developer ID Application: … (TEAMID)"
# it signs with that identity + hardened runtime + secure timestamp (notarizable).
# SIGN_IDENTITY (local installs, see install.sh): a plain signature with that identity, so the
# designated requirement stays the same across builds (ad-hoc = a new app to macOS every build, which
# forgot privacy grants like Downloads access).
set -euo pipefail
APP="$1"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  SIGN=(codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp)
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN=(codesign --force --sign "$SIGN_IDENTITY")
else
  SIGN=(codesign --force --sign -)
fi
# codesign rejects xattrs (Finder info, iCloud/File Provider tags)
xattr -cr "$APP"
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
  for x in "$FW"/Versions/B/XPCServices/*.xpc(N); do
    if [[ "${x:t}" == Downloader.xpc ]]; then "${SIGN[@]}" --preserve-metadata=entitlements "$x"
    else "${SIGN[@]}" "$x"; fi
  done
  "${SIGN[@]}" "$FW/Versions/B/Autoupdate"
  "${SIGN[@]}" "$FW/Versions/B/Updater.app"
  "${SIGN[@]}" "$FW"
fi
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

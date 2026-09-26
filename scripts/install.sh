#!/bin/zsh
# Install build/Flo State Native.app as /Applications/Flo State.app (named "Flo State").
# An existing Tauri build of writer-computer at that path is kept as /Applications/Flo State Legacy.app.
set -euo pipefail
cd "$(dirname "$0")/.."
# relaunch afterwards if it was running
SRC="${SRC:-build/Flo State Native.app}"
DST="/Applications/Flo State.app"
LEGACY="/Applications/Flo State Legacy.app"
if [[ -d "$DST" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DST/Contents/Info.plist")" == "com.writer-computer" ]]; then
  mv "$DST" "$LEGACY"
  /usr/libexec/PlistBuddy -c "Set CFBundleDisplayName Flo State Legacy" "$LEGACY/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add CFBundleDisplayName string Flo State Legacy" "$LEGACY/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleName Flo State Legacy" "$LEGACY/Contents/Info.plist" 2>/dev/null || true
  codesign --force --deep --sign - "$LEGACY" 2>/dev/null
fi
WAS_RUNNING=0; pgrep -f "Flo State.app/Contents/MacOS/FloStateNative" >/dev/null && WAS_RUNNING=1
pkill -f "Flo State.app/Contents/MacOS/FloStateNative" 2>/dev/null || true
rm -rf "$DST"
cp -R "$SRC" "$DST"
/usr/libexec/PlistBuddy -c "Set CFBundleName Flo State" "$DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleDisplayName Flo State" "$DST/Contents/Info.plist"
codesign --force --deep --sign - "$DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST" "$LEGACY" 2>/dev/null || true
echo "installed: $DST (legacy: $LEGACY)"
[[ $WAS_RUNNING == 1 ]] && open -a "$DST" || true

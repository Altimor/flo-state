#!/bin/zsh
# Build a release and assemble "build/Flo State Native.app".
# INSTALL=1 also copies it to /Applications (scripts/install.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# per-machine defaults (gitignored), e.g. INSTALL=1 THROTTLE=slowbuild
[[ -f "$ROOT/.local.env" ]] && source "$ROOT/.local.env"
SCRATCH=$ROOT/.build-release
# APP_NAME / APP (output path) are overridable: scripts/release.sh builds "Flo State".
APP_NAME="${APP_NAME:-Flo State Native}"
APP="${APP:-$ROOT/build/$APP_NAME.app}"
ICON_SRC="$ROOT/Resources/AppIcon.icns"

# JOBS caps parallel compile jobs; wrap with $THROTTLE (e.g. a nice/taskpolicy wrapper) if set
${=THROTTLE:-} swift build -c release -j "${JOBS:-4}" --product FloStateNative --scratch-path "$SCRATCH"
BIN_DIR=$(swift build -c release --product FloStateNative --scratch-path "$SCRATCH" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/FloStateNative" "$APP/Contents/MacOS/FloStateNative"
# Sparkle (SwiftPM binary target): embed the framework, symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# rpaths: only the OS Swift runtime + the embedded Frameworks (drop SwiftPM's
# @loader_path and absolute toolchain paths — XProtect flags dangling rpaths).
EXE="$APP/Contents/MacOS/FloStateNative"
for rp in ${(f)"$(otool -l "$EXE" | awk '/cmd LC_RPATH/{getline; getline; print $2}')"}; do
  [[ "$rp" == /usr/lib/swift ]] || install_name_tool -delete_rpath "$rp" "$EXE"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
# SwiftPM resource bundles go in Contents/Resources (FloResources looks there;
# codesign rejects anything extra at the bundle root).
for b in "$BIN_DIR"/*.bundle(N); do
  cp -R "$b" "$APP/Contents/Resources/"
done
[[ -f "$ICON_SRC" ]] && cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
# Localization: the UI strings live in the FloCore bundle's Resources/<lang>.lproj; the app
# bundle gets matching <lang>.lproj (InfoPlist.strings: document-type names) so
# AppKit, Sparkle and System Settings' per-app language see the same languages.
# Binary .strings load faster than the text source.
LANGS=()
for d in "$ROOT"/Sources/FloCore/Resources/*.lproj(N); do LANGS+=("${${d:t}%.lproj}"); done
for l in $LANGS; do
  mkdir -p "$APP/Contents/Resources/$l.lproj"
  if [[ -f "$ROOT/Resources/$l.lproj/InfoPlist.strings" ]]; then cp "$ROOT/Resources/$l.lproj/InfoPlist.strings" "$APP/Contents/Resources/$l.lproj/"; fi
done
for f in "$APP"/Contents/Resources/**/*.strings(N); do plutil -convert binary1 "$f"; done
LOCALIZATIONS=""
for l in $LANGS; do LOCALIZATIONS+="<string>$l</string>"; done

# CFBundleShortVersionString from VERSION; CFBundleVersion = git commit count
# (monotonic, what Sparkle compares).
SHORT_VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
FEED_URL=${FEED_URL:-https://flocrivello.com/flostate/appcast.xml}
SU_PUBLIC_ED_KEY=${SU_PUBLIC_ED_KEY:-555mr7A0qvjV4aGSyDX3YK4rBrXP7BrTTkF9Bu1UhSo=}
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS}</array>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>app.flostate.native</string>
  <key>CFBundleExecutable</key><string>FloStateNative</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>md</string><string>mdx</string><string>markdown</string></array>
      <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

"$ROOT/scripts/sign.sh" "$APP"
echo "built: $APP"

if [[ "${INSTALL:-0}" == 1 ]]; then "$ROOT/scripts/install.sh"; fi

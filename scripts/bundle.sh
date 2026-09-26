#!/bin/zsh
# Build a release and assemble "build/Flo State Native.app".
# INSTALL=1 also copies it to /Applications (scripts/install.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
# per-machine defaults (gitignored), e.g. INSTALL=1 THROTTLE=slowbuild
[[ -f "$ROOT/.local.env" ]] && source "$ROOT/.local.env"
SCRATCH=$ROOT/.build-release
APP="$ROOT/build/Flo State Native.app"
ICON_SRC="$ROOT/Resources/AppIcon.icns"

# JOBS caps parallel compile jobs; wrap with $THROTTLE (e.g. a nice/taskpolicy wrapper) if set
${=THROTTLE:-} swift build -c release -j "${JOBS:-2}" --product FloStateNative --scratch-path "$SCRATCH"
BIN_DIR=$(swift build -c release --product FloStateNative --scratch-path "$SCRATCH" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FloStateNative" "$APP/Contents/MacOS/FloStateNative"
# SwiftPM resource bundles go in Contents/Resources (FloResources looks there;
# codesign rejects anything extra at the bundle root).
for b in "$BIN_DIR"/*.bundle(N); do
  cp -R "$b" "$APP/Contents/Resources/"
done
[[ -f "$ICON_SRC" ]] && cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

VERSION=$(git describe --tags --always 2>/dev/null || echo 0.1)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Flo State Native</string>
  <key>CFBundleDisplayName</key><string>Flo State Native</string>
  <key>CFBundleIdentifier</key><string>app.flostate.native</string>
  <key>CFBundleExecutable</key><string>FloStateNative</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
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

codesign --force --deep --sign - "$APP" 2>&1 || {
  echo "codesign failed" >&2; exit 1; }
codesign --verify --verbose=2 "$APP" || true
echo "built: $APP"

if [[ "${INSTALL:-0}" == 1 ]]; then "$ROOT/scripts/install.sh"; fi

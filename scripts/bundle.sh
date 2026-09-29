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
# App icon: Resources/AppIcon.icon (Icon Composer bundle) compiled by Xcode 26's actool into
# Assets.car (macOS 26 Liquid Glass icon + pre-rendered rounded-rect images for macOS <=15)
# + AppIcon.icns. Without actool, fall back to Resources/AppIcon.icns: the same rounded-rect
# artwork pre-masked (Tahoe then shows it inside its generic squircle frame).
ICON_SRC="$ROOT/Resources/AppIcon.icon"
ICON_FALLBACK="$ROOT/Resources/AppIcon.icns"

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
ICON_NAME_PLIST=""
ICON_OUT="$SCRATCH/appicon"
rm -rf "$ICON_OUT"; mkdir -p "$ICON_OUT"
if xcrun actool "$ICON_SRC" --compile "$ICON_OUT" --app-icon AppIcon --platform macosx \
     --target-device mac --minimum-deployment-target 14.0 \
     --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null 2>&1 \
   && [[ -f "$ICON_OUT/Assets.car" && -f "$ICON_OUT/AppIcon.icns" ]]; then
  cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
  ICON_NAME_PLIST="<key>CFBundleIconName</key><string>AppIcon</string>"
else
  echo "warning: actool (Xcode 26) failed; using pre-masked $ICON_FALLBACK" >&2
  cp "$ICON_FALLBACK" "$APP/Contents/Resources/AppIcon.icns"
fi
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
  ${ICON_NAME_PLIST}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
      <key>UTTypeDescription</key><string>Markdown Document</string>
      <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>md</string><string>markdown</string><string>mdown</string><string>mkd</string><string>mkdn</string><string>mdwn</string><string>mdx</string></array>
        <key>public.mime-type</key><array><string>text/markdown</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>CFBundleTypeExtensions</key><array><string>md</string><string>mdx</string><string>markdown</string><string>mdown</string><string>mkd</string><string>mkdn</string><string>mdwn</string></array>
      <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Plain Text Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>txt</string><string>text</string><string>csv</string><string>log</string></array>
      <key>LSItemContentTypes</key><array><string>public.plain-text</string><string>public.comma-separated-values-text</string><string>com.apple.log</string></array>
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

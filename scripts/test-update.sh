#!/bin/zsh
# Headless Sparkle end-to-end test (no windows, no Dock icon):
# copies the built app (version N) to a temp dir, makes a re-signed N+1 copy,
# zips + EdDSA-signs it (sign_update, key from the login keychain), serves an
# appcast on localhost, runs the N app with --sparkle-probe pointed at it via
# FLOSTATE_FEED_URL, and checks the temp copy was replaced by N+1.
# Run scripts/bundle.sh first (INSTALL=0).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC="${SRC:-$ROOT/build/Flo State Native.app}"
SPARKLE_BIN="$ROOT/.build-release/artifacts/sparkle/Sparkle/bin"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/flostate-update-test.XXXXXX")
trap '[[ -n "${SERVER:-}" ]] && kill $SERVER 2>/dev/null; [[ -n "${KEEP:-}" ]] && echo "kept $WORK" || rm -rf "$WORK"' EXIT

APP="$WORK/installed/Flo State.app"
mkdir -p "$WORK/installed" "$WORK/serve" "$WORK/next"
ditto "$SRC" "$APP"
N=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
NEXT=$((N + 1))
ditto "$SRC" "$WORK/next/Flo State.app"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $NEXT" -c "Set CFBundleShortVersionString 99.0.0" "$WORK/next/Flo State.app/Contents/Info.plist"
"$ROOT/scripts/sign.sh" "$WORK/next/Flo State.app" >/dev/null 2>&1
ZIP="$WORK/serve/FloState-99.0.0.zip"
ditto -c -k --keepParent "$WORK/next/Flo State.app" "$ZIP"

SIG=$("$SPARKLE_BIN/sign_update" --account flostate -p "$ZIP")
"$SPARKLE_BIN/sign_update" --account flostate --verify "$ZIP" "$SIG" && echo "sign_update: signature verifies"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 "$ROOT/scripts/appcast.py" "$WORK/serve/appcast.xml" --version 99.0.0 --build $NEXT \
  --url "http://localhost:$PORT/${ZIP:t}" --ed-signature "$SIG" --length $(stat -f%z "$ZIP") >/dev/null
(cd "$WORK/serve" && exec python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
sleep 1

echo "installed: $N -> offering $NEXT"
FLOSTATE_FEED_URL="http://localhost:$PORT/appcast.xml" "$APP/Contents/MacOS/FloStateNative" --sparkle-probe || {
  echo "FAIL: probe exited with an error" >&2; exit 1; }
# the installer finishes after the app quits
for i in {1..60}; do
  V=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "")
  [[ "$V" == "$NEXT" ]] && break
  sleep 0.5
done
if [[ "$V" == "$NEXT" ]]; then
  codesign --verify --deep --strict "$APP" && echo "PASS: updated $N -> $NEXT, signature valid"
else
  echo "FAIL: still at $V" >&2; exit 1
fi

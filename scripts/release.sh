#!/bin/zsh
# Build, sign and publish a release of Flo State.
#
#   scripts/release.sh [X.Y.Z]      # version defaults to the VERSION file; given → written to VERSION
#
# 1. builds "Flo State.app" (throttled: slowbuild, 4 jobs on efficiency cores), version from VERSION,
#    build number = git commit count
# 2. signs it: ad-hoc, or with DEVELOPER_ID (hardened runtime) and, when
#    NOTARY_PROFILE is set too, notarizes + staples before zipping
# 3. zips it (ditto -c -k --keepParent), EdDSA-signs the zip (Sparkle sign_update,
#    private key "flostate" in the login keychain)
# 4. creates the GitHub release vX.Y.Z on $GH_REPO with the zip attached
# 5. prepends the release to the appcast (history kept) in the website repo
#    ($SITE_DIR/public/flostate/appcast.xml) + release notes next to it
# 6. commits + deploys the website (Cloudflare Pages) and purges the CDN cache, so the
#    update is live; SKIP_DEPLOY=1 leaves that to you.
#
# Env: DEVELOPER_ID="Developer ID Application: Name (TEAMID)", NOTARY_PROFILE=<notarytool keychain profile>,
#      NOTES_FILE=<markdown notes> (default: release-notes/X.Y.Z.md if present),
#      SITE_DIR, GH_REPO, DRY_RUN=1 (build/sign/appcast into build/release only; no GitHub, no site).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
GH_REPO=${GH_REPO:-Altimor/flo-state}
SITE_DIR=${SITE_DIR:-$HOME/agent/2026.09.26 flocrivello-site}
SPARKLE_BIN="$ROOT/.build-release/artifacts/sparkle/Sparkle/bin"

if [[ $# -ge 1 ]]; then
  [[ "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must be X.Y.Z" >&2; exit 64; }
  echo "$1" > "$ROOT/VERSION"
fi
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
TAG="v$VERSION"
OUT="$ROOT/build/release"
APP="$OUT/Flo State.app"
ZIP="$OUT/FloState-$VERSION.zip"
URL="https://github.com/$GH_REPO/releases/download/$TAG/${ZIP:t}"

if [[ -z "${DRY_RUN:-}" ]]; then
  gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1 && { echo "release $TAG already exists on $GH_REPO" >&2; exit 1; }
  [[ -d "$SITE_DIR/public" ]] || { echo "website repo not found: $SITE_DIR" >&2; exit 1; }
fi
[[ -n "$(git status --porcelain --untracked-files=no)" ]] && echo "warning: uncommitted changes are included in this build" >&2

# 1-2. build + sign (bundle.sh → sign.sh uses DEVELOPER_ID when set)
rm -rf "$OUT"; mkdir -p "$OUT"
APP_NAME="Flo State" APP="$APP" INSTALL=0 THROTTLE=slowbuild JOBS=${JOBS:-4} "$ROOT/scripts/bundle.sh"
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle tools missing: $SPARKLE_BIN" >&2; exit 1; }

NOTARIZED=0
if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  rm -f "$OUT/notarize.zip"
  NOTARIZED=1
elif [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "warning: DEVELOPER_ID without NOTARY_PROFILE: signed but not notarized" >&2
fi

# 3. zip + EdDSA signature
ditto -c -k --keepParent "$APP" "$ZIP"
SIG=$("$SPARKLE_BIN/sign_update" --account flostate -p "$ZIP")
"$SPARKLE_BIN/sign_update" --account flostate --verify "$ZIP" "$SIG"
LENGTH=$(stat -f%z "$ZIP")

# release notes
NOTES_MD="$OUT/notes.md"
if [[ -n "${NOTES_FILE:-}" ]]; then cp "$NOTES_FILE" "$NOTES_MD"
elif [[ -f "$ROOT/release-notes/$VERSION.md" ]]; then cp "$ROOT/release-notes/$VERSION.md" "$NOTES_MD"
else echo "Flo State $VERSION." > "$NOTES_MD"; fi
GH_NOTES="$OUT/gh-notes.md"
cp "$NOTES_MD" "$GH_NOTES"
if [[ $NOTARIZED == 0 ]]; then
  printf '\n**Not notarized yet: on first launch right-click the app → Open.**\n' >> "$GH_NOTES"
fi
printf '\nDownload `%s`, unzip, and move **Flo State.app** to /Applications. Later versions install from inside the app (Flo State → Check for Updates…).\n' "${ZIP:t}" >> "$GH_NOTES"

# 5a. appcast (history kept: start from the published one)
APPCAST="$OUT/appcast.xml"
SITE_APPCAST="$SITE_DIR/public/flostate/appcast.xml"
[[ -f "$SITE_APPCAST" ]] && cp "$SITE_APPCAST" "$APPCAST"
python3 "$ROOT/scripts/appcast.py" "$APPCAST" --version "$VERSION" --build "$BUILD" --url "$URL" \
  --ed-signature "$SIG" --length "$LENGTH" --notes-file "$NOTES_MD"
xmllint --noout "$APPCAST"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "dry run: $ZIP ($LENGTH bytes, build $BUILD), $APPCAST"; exit 0
fi

# 4. GitHub release
gh release create "$TAG" "$ZIP" --repo "$GH_REPO" --title "Flo State $VERSION" --notes-file "$GH_NOTES"

# 5b. website files (deployed separately)
mkdir -p "$SITE_DIR/public/flostate/release-notes"
cp "$APPCAST" "$SITE_APPCAST"
cp "$NOTES_MD" "$SITE_DIR/public/flostate/release-notes/$VERSION.md"
echo "released $TAG (build $BUILD): https://github.com/$GH_REPO/releases/tag/$TAG"
[[ -n "${SKIP_DEPLOY:-}" ]] && { echo "appcast written: $SITE_APPCAST (SKIP_DEPLOY: deploy the website to publish it)"; exit 0; }

# 6. publish the appcast: commit + deploy the site, purge the CDN
(
  cd "$SITE_DIR"
  git add public/flostate && git commit -qm "Flo State $VERSION appcast" || true
  npm run build >/dev/null
  npx wrangler pages deploy dist --project-name flocrivello --branch main 2>&1 | tail -1
)
source <(grep -E "^export CLOUDFLARE" ~/.zshrc)
ZONE=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=flocrivello.com" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')
curl -s -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/purge_cache" -d '{"purge_everything":true}' | grep -q '"success":true' || echo "warning: cache purge failed" >&2
curl -s "https://flocrivello.com/flostate/appcast.xml" | grep -q "<sparkle:shortVersionString>$VERSION<" && echo "live: appcast serves $VERSION" || echo "warning: live appcast doesn't show $VERSION yet" >&2

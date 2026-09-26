#!/bin/sh
# Rebuild Sources/FloCore/Resources/htmlblock/sanitize.js from the web app's
# html-block-decorations.ts (ALLOWED_TAGS/ATTR + sanitizeHTML are extracted
# verbatim, so the native renderer sanitises exactly like the web).
set -e
cd "$(dirname "$0")"
# writer-computer checkout (pnpm install done): $WRITER_REPO, default ../writer-computer next to this repo
R="${WRITER_REPO:-$(cd ../../.. && pwd)/writer-computer}"
P="$R/node_modules/.pnpm"
W="$R/apps/desktop"
SRC="$W/src/components/editor-area/html-block-decorations.ts"
[ -e node_modules ] || ln -s "$W/node_modules" node_modules
python3 - "$SRC" > entry.ts <<'PY'
import re, sys
s = open(sys.argv[1]).read()
start = s.index("const ALLOWED_TAGS")
end = s.index("class HtmlBlockWidget")
print('import DOMPurify from "dompurify";')
print(s[start:end])
print("(window as any).floSanitize = sanitizeHTML;")
PY
OUT=../../Sources/FloCore/Resources/htmlblock
mkdir -p $OUT
"$P"/@esbuild+darwin-arm64@0.27.4/node_modules/@esbuild/darwin-arm64/bin/esbuild entry.ts --bundle --format=iife --minify --target=es2020 --outfile=$OUT/sanitize.js

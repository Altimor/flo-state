#!/bin/sh
# Rebuild Sources/FloCore/Resources/mermaid/ from the web app's source + node_modules.
set -e
cd "$(dirname "$0")"
# writer-computer checkout (pnpm install done): $WRITER_REPO, default ../writer-computer next to this repo
R="${WRITER_REPO:-$(cd ../../.. && pwd)/writer-computer}"
P="$R/node_modules/.pnpm"
W="$R/apps/desktop"
[ -e node_modules ] || ln -s "$R/node_modules" node_modules
OUT=../../Sources/FloCore/Resources/mermaid
mkdir -p $OUT
"$P"/@esbuild+darwin-arm64@0.27.4/node_modules/@esbuild/darwin-arm64/bin/esbuild entry.ts --bundle --format=iife --minify --target=es2020 \
  --alias:@="$W/src" --loader:.css=empty --outfile=$OUT/mermaid-widget.js
cp "$W/src/components/editor-area/mermaid-canvas.css" $OUT/

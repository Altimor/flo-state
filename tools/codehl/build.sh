#!/bin/sh
# Rebuild Sources/FloCore/Resources/codehl.js from the web app's node_modules.
set -e
cd "$(dirname "$0")"
# writer-computer checkout (pnpm install done): $WRITER_REPO, default ../writer-computer next to this repo
R="${WRITER_REPO:-$(cd ../../.. && pwd)/writer-computer}"
P="$R/node_modules/.pnpm"
[ -e node_modules ] || ln -s "$R/node_modules" node_modules
"$P"/@esbuild+darwin-arm64@0.27.4/node_modules/@esbuild/darwin-arm64/bin/esbuild entry.js --bundle --format=iife --minify --target=es2020 \
  --alias:@lezer/highlight="$P/@lezer+highlight@1.2.3/node_modules/@lezer/highlight" \
  --alias:@lezer/yaml="$P/@lezer+yaml@1.0.4/node_modules/@lezer/yaml" \
  --outfile=../../Sources/FloCore/Resources/codehl.js

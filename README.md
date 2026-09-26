# Flo State Native

A native macOS rewrite of Flo State, a customised build of
[writer.computer](https://github.com/joelbqz/writer-computer)'s markdown editor.
The original is a Tauri app (React + CodeMirror 6 in a web view); this one is
Swift, AppKit and TextKit 2, with no web view in the editing path.

The goal is behavioural parity with the web app: the same live-preview
rendering (syntax marks hide per line, and tables, math, Mermaid, images and
HTML blocks fold into widgets), the same editing commands and keymaps, and the
same app shell (sidebar, tabs, command palette, outline rail, settings,
find/replace). Parity is measured against the real web frontend: see
[Testing](#testing).

## Layout

| Path | What |
|---|---|
| `Sources/FloCore` | Platform-independent core: a Swift port of `@lezer/markdown` (plus GFM and the app's extensions), editor state/transactions/history, editing commands and keymaps, the render planner (per-character styles), and the app model (settings, workspace FS, `.gitignore`, search index, sessions). |
| `Sources/FloKit` | AppKit/TextKit 2 editor: text view, layout, widgets (tables, KaTeX math, Mermaid, HTML blocks, images), find overlay, wiki-link autocomplete, paste handling. |
| `Sources/FloStateNative` | The app: window, sidebar, tabs, palette, settings, menus, plus headless CLI modes (`--snapshot`, `--batch-geometry`, `--replay-keys`, `--perf <file>`, `--fuzz-edit <file> <seed> <steps>`, `--shell-snapshot`) used by the parity harness. |
| `Tests/` | Unit and parity tests (XCTest). `Tests/FloTestSupport` generates synthetic documents. |
| `fixtures/` | Behaviour recorded from the web app (syntax trees, per-char render styles, keystroke results, find/paste/menu/wiki-link behaviour). |
| `oracle/` | The harness that runs the real web frontend headless and records or compares fixtures. |
| `tools/` | Scripts that rebuild the bundled JavaScript (code highlighting, HTML sanitizer, Mermaid) from a writer-computer checkout. |
| `docs/` | `SPEC.md` (behavioural spec of the web app), `KEYS-DEVIATIONS.md`. |

## Build

Requires macOS 14+ and Swift 6 (Xcode 16 or a matching toolchain).

```sh
swift build --product FloStateNative        # debug build
swift run FloStateNative                    # run it (unbundled)
scripts/bundle.sh                           # release build -> "build/Flo State Native.app"
INSTALL=1 scripts/bundle.sh                 # ...and install it as /Applications/Flo State.app
```

`scripts/bundle.sh` builds with `-j ${JOBS:-2}`; set `THROTTLE` to a wrapper
command (for example `nice -n 10`) to lower its priority. The app is ad-hoc
signed.

## Testing

### Unit and parity tests

```sh
swift test
```

The parity tests replay the recorded web behaviour in `fixtures/` through the
native code and assert that nothing differs: syntax trees node for node,
render styles character by character, keystroke results, find/replace, paste,
context menu and wiki-link autocomplete. The tests need no network, no browser
and no files outside the repo; large documents are generated in code
(`Tests/FloTestSupport`).

### The oracle harness (re-recording fixtures)

`oracle/` runs the real web frontend against a mock Tauri backend
(`oracle/server.py`) and drives it through headless Chrome (CDP) or an
offscreen `WKWebView` (`oracle/wk`, the engine the Tauri app uses on macOS).

1. Check out and build writer-computer next to this repo (or anywhere, and
   point `WRITER_REPO` at it). The fixtures were recorded against the
   customised build described in `docs/SPEC.md` §5, so an unmodified
   upstream checkout will show some expected differences.

   ```sh
   git clone https://github.com/joelbqz/writer-computer ../writer-computer
   (cd ../writer-computer && vp install && vp run build -r)   # see its README; needs apps/desktop/dist
   export WRITER_REPO=$PWD/../writer-computer                # optional when it is a sibling
   ```

2. Python deps: `python3 -m venv .venv && .venv/bin/pip install websocket-client numpy pillow`.
   The WebKit driver: `swiftc -O oracle/wk/main.swift -o oracle/wk/wkoracle`
   (or use Chrome with `ORACLE_ENGINE=chrome`).

3. Generate the sample workspace the mock backend serves. It is synthetic
   (notes with headings, lists, tasks, links, wiki links, a table, code,
   frontmatter, an `Archive/` folder, an image attachment and a ~110 KB dated
   journal) and is regenerated deterministically:

   ```sh
   python3 oracle/make_sandbox.py          # -> oracle/sandbox/Sample (gitignored)
   ```

   Set `ORACLE_SANDBOX=/path/to/folder` to run the oracle on another workspace
   instead. The mock backend only ever reads and writes inside that folder.

4. Start the backend, then run a generator or a comparison:

   ```sh
   python3 oracle/server.py &              # serves $WRITER_REPO/apps/desktop/dist on :5288
   cd oracle
   python3 gen_trees.py                    # -> fixtures/trees.json
   python3 gen_render.py                   # -> fixtures/render.json
   python3 gen_keys.py                     # -> fixtures/keys.jsonl
   python3 shell_parity.py                 # app shell: web vs `FloStateNative --shell-snapshot`
   python3 geom_parity.py                  # glyph positions: web vs native
   ```

Other environment variables: `ORACLE_TMP` (scratch and screenshot output,
default `<system temp>/flo-oracle`), `NATIVE` (the `FloStateNative` binary to
compare, default the most recent debug build in the repo), `CHROME` (Chrome
executable path), `FLO_ORACLE_PORT` (backend port, default 5288; set the same
value for the server and the scripts). The server overlays the local writer-computer config
(`~/Library/Application Support/com.writer-computer/config`) on the schema
defaults; set `FLO_DEFAULT_SETTINGS=1` to ignore it.

`oracle/extract_spec.mjs` extracts the CommonMark/GFM examples from
`@lezer/markdown`'s test suite in `$WRITER_REPO/node_modules` into
`oracle/corpus-spec.json`.

## License

Flo State Native is free software, licensed under the **GNU General Public
License v3.0 or later** (GPL-3.0-or-later). See [LICENSE](LICENSE).

It is a derivative work of
[writer-computer](https://github.com/joelbqz/writer-computer) by Joel
([@joelbqz](https://github.com/joelbqz)) and contributors, licensed under GPL-3.0. Its behaviour, settings
schema (`Sources/FloCore/Resources/settings.schema.json`), themes, and parts
of its source (for example the Mermaid canvas and the HTML-block sanitizer
configuration, bundled via `tools/`) are taken from that project.

Bundled or ported third-party code:

| Component | Where | License |
|---|---|---|
| [KaTeX](https://github.com/KaTeX/KaTeX) 0.16 (JS, CSS, fonts) | `Sources/FloCore/Resources/katex/` | MIT |
| [beautiful-mermaid](https://www.npmjs.com/package/beautiful-mermaid), bundled with [elkjs](https://github.com/kieler/elkjs) and [entities](https://github.com/fb55/entities) | `Sources/FloCore/Resources/mermaid/mermaid-widget.js` | MIT; elkjs: EPL-2.0; entities: BSD-2-Clause |
| [CodeMirror 6](https://codemirror.net) (`@codemirror/language`, `language-data`, `lang-*`) and [Lezer](https://lezer.codemirror.net) parsers (`@lezer/*`) | `Sources/FloCore/Resources/codehl.js` (bundled); `Sources/FloCore/Markdown` is a Swift port of `@lezer/markdown` | MIT |
| [DOMPurify](https://github.com/cure53/DOMPurify) | `Sources/FloCore/Resources/htmlblock/sanitize.js` | MPL-2.0 or Apache-2.0 |
| CommonMark/GFM spec examples from `@lezer/markdown`'s tests | `oracle/corpus-spec.json`, `fixtures/trees.json` | MIT |

The bundled JavaScript files are minified builds; their sources are the npm
packages above at the versions pinned by writer-computer's lockfile, and
`tools/*/build.sh` rebuilds them.

# Flo State: behavioural spec for the native (Swift/AppKit/TextKit 2) rewrite

## 0. Architecture facts that affect the port
- **Frontmatter lives outside the editor text.** `parseDocument` (`src/lib/frontmatter.ts:17-40`) splits the file into `frontmatter` and `body`. The editor only ever holds the body. Frontmatter is edited in a key/value panel above the editor (`frontmatter-panel.tsx`). On save the file is rebuilt as `---\n{fm}\n---\n{body}` (`serializeFile`).
- **Markdown source is the only model.** All rendering is decorations over a Lezer markdown tree (GFM plus custom extensions: frontmatter, space-in-link destinations, nested links as plain text, escape, emoji, dash, math, HTML blocks). Parser config is at `use-prosemark-editor.ts:583-589`.
- **`.csv` opens with no language at all** (`isPlainTextPath`, `paths.ts:199`). No decorations are applied; the file shows as stored.
- **Rendering is "live preview".** Hidden syntax marks are revealed per line: if the caret or any selection range shares a line with a node, its marks show (`hide/core.ts:47-55`, commit 03c6d23). The fold widgets (emoji, dash, image, math, table, HTML) instead reveal only when the selection touches the node's character range (`fold/core.ts`, `utils.ts selectionTouchesRange`, inclusive at both ends).
- **Decisions freeze during a mouse drag.** From pointerdown to pointerup, reveal/hide decisions are frozen so text doesn't reflow under the cursor. One rebuild runs on mouseup (`drag-selection-gate.ts`, `unfurlFreezeFacet`).

## 1. Rendering

### 1.1 Global typography and layout (defaults, light and dark)
| Property | Value | Source |
|---|---|---|
| Editor font | `"SF Pro", -apple-system-body, ui-sans-serif, …` (setting `fonts.editor`) | settings.schema.json #24 → `--editor-font` |
| UI font | same stack (`fonts.ui`) | #23 |
| Code font | `"SF Mono", ui-monospace, SFMono-Regular, Menlo, …` (`fonts.mono`) | #25 |
| Font size | 16px (`editor.font-size`, min 10, max 32). Cmd+=/−/0 step ±1 or reset | schema #0; `use-menu-events.ts:36-68` |
| Line height | **1.5** (`editor.line-height`; the CSS fallback of 1.8 is overridden) | schema #1 |
| Letter spacing | 0em (`App.css:133` overrides the −0.03em fallback in `prosemark-theme.css:133`) | |
| Blank line | `line-height: 1` (a blank separator line is shorter) | `prosemark-theme.css:158` |
| Text column | max 734px text width; side padding `clamp(1.5rem, 4vw, 4rem)`; centred; bottom padding 40vh | `App.css:124-129`, `prosemark-theme.css:111-135` |
| Top of document | frontmatter panel wrapper `pt-32` (8rem), `md:pt-[9rem]`, `pb-6` above the editor | `editor-pane.tsx` |
| Scroll container | 12px transparent top/bottom borders, `scrollbar-gutter: stable both-edges`; scrollbar 18px wide, thumb only on hover | `editor-scroll-container.tsx`, `App.css:208-227` |
| Paragraph spacing | `padding-bottom: var(--writer-paragraph-spacing)`, default **0px**, on non-heading, non-list lines | `prosemark-theme.css:490` |
| List line spacing | `padding-bottom` **12px** (`editor.bullet-spacing`) on bullet, task **and ordered** lines | `prosemark-theme.css:496-499` (uncommitted) |
| Heading spacing | padding-top `1rem + heading-space-before` (default 0) = 16px; padding-bottom `heading-space-after` = **8px** | `prosemark-theme.css:256-266` |
| Body text colour | `--text-secondary` = fg-base at 80% alpha | `App.css:58` |
| Muted | fg 54%; icon-muted fg 40% | |
| Selection | accent at 30% alpha | `App.css:113` |
| Caret | `--text-primary` (fg-base) | `prosemark-theme.css:33-36` |
| Autocorrect/spellcheck | forced **on**, so macOS Text Replacements and smart quotes work | `use-prosemark-editor.ts:612`; `macos.rs enable_text_substitutions` plus an Edit ▸ Substitutions menu |
| Control characters | C0 characters render as nothing (stay in the file) | `use-prosemark-editor.ts:629-635` |
| Tab character | fixed 4ch-wide blank | `tabWidthExtension.ts` |
| Auto-close brackets | **off**; bracketMatching only highlights existing pairs | `basicSetup.ts:40-45` |

**Theme tokens.** Values are pushed to `:root` by `theme.ts`. `bg-opacity = 1 − translucent/100 × 0.95`; `contrast = 0.2 + slider/100 × 0.8`.

| Token | Light (Writer preset) | Dark (Writer preset) |
|---|---|---|
| accent | #FF6A00 | #FF6A00 |
| bg-base | #FFFFFF, translucent 10 → opacity 0.905 | #111111, translucent 20 → 0.81 |
| fg-base | #0D0D0D | #FCFCFC |
| H1 colour | #191919 | #F0F0F0 |
| contrast slider | 20 → 0.36 | 16 → 0.328 |

- **Other presets** (`shared/themes/*/*.json`): default, high-contrast, warm-paper.
- **Window background** is `--bg` (bg-base at bg-opacity) over the macOS `hudWindow` vibrancy.
- **Derived overlays** are all `fg-base × contrast × k%`: border 24, subtle surface 18, hover 16, active 26, tab-active 24 (34 in dark), code-bg 16, blockquote bar 58, scrollbar thumb 58.

### 1.2 Inline syntax (hide rules: `src/lib/prosemark-core/hide/index.ts:22-97`)
Every row below: marks hidden when the caret is off the node's lines, shown when any selection shares a line.

| Syntax | Off-line rendering | Hide technique | Notes |
|---|---|---|---|
| `**bold**`, `__b__` | bold (weight **600**, via the Prec.highest style at `use-prosemark-editor.ts:722-735`) | marks **removed from layout** (`removeFromDOM`) | wrapper class `cm-emphasis` |
| `*it*`, `_it_` | italic | removed | |
| `~~strike~~` | line-through **and muted colour** | removed | `prosemark-theme.css:468-471` |
| `` `code` `` | mono font, same size as body, padding 0.2rem, radius 0.4rem, bg `--code-bg`, ligatures off | backticks font-size 0 | |
| `[text](url)` | text in accent colour, underlined, pointer cursor | `[`, `](`, `)` and the URL at font-size 0 | On the caret line the raw source shows. The URL part is still accent + underline + clickable (`.cm-url`). |
| Bare/auto URLs | accent + underline, clickable | n/a | |
| `\*` escape | backslash hidden; the escaped char in body colour | font-size 0 | Reveal zone is the WORD, but the check is still per line (commit 29e7c48) |
| `:smile:` | emoji glyph (node-emoji); unknown names stay literal | replace widget | reveals when the selection touches the range |
| `--` / `---` inline | en dash – / em dash — | replace widget | only runs of 2–3 not preceded by `-`; reveals on touch |
| `$x^2$` | KaTeX inline; `$$…$$` display with 0.5em margins | replace widget | Inline needs non-space content, and the closing `$` must not be followed by a digit. On a render error: raw source in mono, invalid colour. Clicking selects the whole node (reveals it). `math-decorations.ts` |
| `[[Note]]` / `[[Note\|Alias]]` / `[[Note#H]]` | display text (alias, else path, else `#frag`) in accent colour, **no underline** | replace widget; while the selection is **inside** the brackets (position-based), raw text in accent colour | `wiki-link-extension.ts` |
| `![[img.png]]` | embedded image (png jpg jpeg gif webp svg). Unresolved: raw text in muted colour | | Resolution order in `wiki-links.ts resolveWikiImage` |
| `![alt\|400](path)` | image; `\|400` sets display width in px. Block-level if alone on its line. Resize handle bottom-right (14px, visible on hover, min 40px); on release it rewrites the `\|N` alt suffix in the source | When the selection touches, the **source shows and the image renders after it** | `fold/image.ts`. Relative paths resolve against the note's folder (asset protocol, `image-src-resolver.ts`). Heights are cached per URL to avoid scroll jumps. Clicking an image selects its source. |

### 1.3 Block syntax
- **ATX headings** (`heading-decorations.ts`, `syntaxHighlighting.ts:36`):
  - Sizes: H1 1.6em, H2 1.4em, H3 1.2em, H4–H6 1em (body size). All weight 600.
  - Colours: H1 `theme.*.heading-color`. H2 and H3 `editor.subheading-color` (default #3a3a3a, the same in both modes; see §9). H4–H6 body colour.
  - **Hash marks hang in the left margin**: absolutely positioned at `right: 100%`, 0.4em right padding, muted colour. The highlight style adds opacity 0.4. They are visible **only while the caret is on that heading line**; otherwise opacity 0 (never font-size 0), `prosemark-theme.css:268-283, 396-399`. Heading text is always flush with body text.
  - **No-go zone** `[lineStart, hashEnd)`: a transaction filter clamps any caret or selection endpoint inside it to the first heading character (`heading-decorations.ts:238-252`).
    - Example: clicking before `## Foo` puts the caret before `F`.
    - Left arrow at the first heading character jumps to the end of the previous line; Shift-Left extends the selection there (`:275-307`).
    - Clicking the margin hash places the caret at the first heading character (`:189-219`).
  - Setext headings get the same line classes; their underline marker line is block-hidden.
- **Heading fold chevron** (`heading-fold.ts`, `prosemark-theme.css:288-378`):
  - A CSS triangle sits left of each foldable heading (0.34em × 0.52em, muted colour). Opacity 0; 0.75 when the line is hovered; 1 when the chevron itself is hovered. Rotated 90° when expanded; 120ms transitions.
  - Vertical position: `top = pad-top + 0.5lh + 4px`, then translateY −50%.
  - Mousedown toggles the fold.
  - A section runs from the end of the heading line to the line before the next heading of the same or shallower depth, or to end of document. Headings with nothing beneath them are not foldable.
  - The folded placeholder is invisible (it must still occupy a navigable position so Down-arrow works).
  - Setting `editor.show-heading-chevrons=false` hides the chevrons; folding still works from the menu.
- **Horizontal rule** `---` / `***` on its own line: replaced by a 1.4em-tall flex row with `<hr>` at opacity 0.2. Hidden unless the selection touches it; clicking selects its source (`fold/horizontalRule.ts`).
- **Blockquote**:
  - Each line gets `.cm-blockquote-line`: a 0.3em vertical bar in `--blockquote-border` colour at inset 0 (theme override), text inset 1em.
  - Nested `>` get additional bars at the measured x offset.
  - `>` marks are transparent (opacity 0, keep their width) unless the caret is on any line of the blockquote block.
- **Fenced code**:
  - Every line: mono font at body size, bg `--code-bg`, padding 0 12px. First line rounded at the top, last line at the bottom (0.4rem).
  - The fences and info string are transparent (space kept) unless the caret is on any line of the block.
  - Language label and copy button exist but are `display:none`.
  - The body is syntax-highlighted for any `@codemirror/language-data` language, using the dark oklch palette in `prosemark-theme.css:14-27` **in both modes** (the light palette is not installed).
- **Mermaid** (```` ```mermaid ````): always replaced by a 480px canvas with drag-pan, wheel and pinch zoom, zoom buttons, reset, an "Edit code" toggle (nested editor panel that rewrites the whole fence) and a fullscreen button (`mermaid-*.ts`). The source is never revealed by the caret.
- **GFM tables**:
  - Rendered as a `<table>`: 1px border, radius 8, cells padded 0.5em / 0.8em, min-width 6em, line-height 1.4. Header row weight 600 on the subtle surface colour. Column alignment from the `:--:` delimiters. Inline markdown renders inside cells.
  - When the selection touches the table: source lines shown in mono on code-bg, 12px padding, rounded ends.
  - Clicking the rendered table selects the whole table source (`table-decorations.ts:470-548`).
- **HTML blocks**: sanitised (DOMPurify; allowed tags and attributes at `html-block-decorations.ts:1-99`) and rendered. The source shows when the selection touches it. `<details>` spans until `</details>`. Self-closing tags such as `<br/>` count as blocks. Links inside are followable.
- **Bullets and tasks** (`list/index.ts:17-244`, `syntaxHighlighting.ts:117-165`):
  - `-`, `*`, `+` all draw **"•"** in muted colour, centred in a 3ch column. Depth = number of ancestor ListItem nodes.
  - The source prefix (indent + marker + space, plus `[ ] ` for tasks) is one inline-block span of width `(depth+1)×3ch`, source text transparent. The glyph sits at `depth×3ch`.
  - The line gets a hanging indent: `padding-left: (depth+1)×3ch; text-indent: −(depth+1)×3ch`, so wrapped lines align with the body text.
  - A marker without its trailing space/tab is not rendered as a list.
  - **Task box**: 18×18px, 1.5px muted border, radius 5px, left at `markerOffset + (3ch − 28px)/2`, vertically centred. Checked (`[x]`/`[X]`): accent fill and border, white check SVG (stroke 3) at 20px. Checked text is **not** struck through.
- **Ordered lists** `1.` / `1)`: marker text stays visible (muted, `padding-left: 1ch`), min-width 3ch, centred. Line style `padding-left: 3ch; text-indent: −3.4ch`. No depth-based indent: leading spaces render as-is.
- **Frontmatter panel**:
  - Rows show key (w-36, 13px, muted) and value (13px, primary), 1.5px vertical padding, subtle background on focus. An × to remove appears on hover. An "+ Add property" button follows the rows.
  - Enter on the last value adds a row. Backspace on an empty row removes it. Blur on a row with an empty key removes the row. Removing the last row deletes the frontmatter block and focuses the editor.
  - Values are coerced (`true`/`false`/`null`/numbers). Nested YAML values are shown as YAML text (`yaml-entries.ts`).

## 2. Editing behaviour
**Keymap precedence**, highest first:
1. Prec.highest: list keys, list-prefix arrows, heading escape-left, link/wiki mousedown, Cmd-F/G.
2. Prec.high: app formatting keymap and input handlers, Cmd-Shift-D, Cmd-Alt-←/→.
3. Default: prosemark's own formatting keymap (shadowed by the app's), then `defaultKeymap`, `searchKeymap`, `historyKeymap`, `foldKeymap`, `completionKeymap`, `lintKeymap`, `indentWithTab`.
4. `lang-markdown`: Enter = `insertNewlineContinueMarkup`, Backspace = `deleteMarkupBackward`. These handle ordered lists and blockquotes whenever the bullet handlers return false.

**macOS native-menu accelerators always win over the editor**: Cmd-N, T, W, K, \\, ",", Shift-D, Alt-C, =, −, 0, Alt-←, Alt-→.

### 2.1 Lists (`list/index.ts`)
- **Enter** (`:700-747`), single empty caret on a bullet/task line only:
  - `- foo|` → `- foo\n- |`
  - `  * [x] done|` → `  * [x] done\n  * [ ] |` (a new task is always unchecked; marker character and indent preserved)
  - `- fo|o` → `- fo\n- |o`
  - Caret inside the prefix → default behaviour.
  - Empty item `- `, `  - [ ] ` → the **whole line is cleared** (indent included) and the caret goes to the line start: exits the list rather than outdenting.
  - Selections and multiple cursors → default newline.
  - Ordered lists (lang-markdown): `1. a|` → `1. a\n2. |`, following items renumbered. An empty ordered item removes its marker. Blockquotes continue with `> `.
- **Backspace** (`:749-797`):
  - Caret at content start with indent: removes `min(2, indent)` spaces **and** the marker. `  - |foo` → `|foo`; `    - |foo` → `  |foo`.
  - Top level: `- |foo` → `|foo`.
  - Caret just before the marker with indent: `  |- foo` → `|- foo` (outdents by 2).
  - A caret sitting inside the indent or marker is treated as if at the next boundary.
- **Cmd-Backspace** (`:672-698`): on any list line (including ordered and task) with the caret after content start, deletes back to content start and keeps the marker: `- buy milk|` → `- |`. Otherwise default (which deletes an empty bullet).
- **Tab** (`:592-616`), empty caret on a list line: indents to the **previous list item's content column**, i.e. its indent + marker + following spaces. Always consumes Tab on a list line, even when nothing changes.
  - `- a\n- |b` → `  - b`
  - `-  a\n- b` → 3 spaces
  - `-   a` → 4 spaces
  - With a selection, each selected bullet line goes to its own target column (`:392-418`).
  - The lookup stops at a blank line or after 256 lines.
  - Non-list lines: default `indentWithTab`.
- **Shift-Tab** (`:620-648`): outdents to the indent of the nearest previous item with a strictly smaller indent, else 0. With a selection: removes `min(2, indent)` per line.
- **Caret geometry**:
  - Atomic ranges: each indent level (the leading whitespace split evenly by depth) and the marker+space (+ task box) are single units.
  - A transaction filter clamps a caret inside the indent to marker start, and a caret inside the marker to content start (`:351-377`).
  - Left at content start → marker start → line start. Right is the mirror image.
  - Clicking in the prefix snaps to the nearest of line start, marker start or content start (`:481-517`).
- **Checkbox click**: a `click` (not mousedown, so drags still work) on the task prefix toggles `[ ]` ↔ `[x]` (`:803-843`).

### 2.2 Formatting (`src/components/editor-area/markdown-formatting.ts`)
| Command | Chord | Behaviour |
|---|---|---|
| Bold | Cmd-B | **With a selection** (`wrapSelectionPerLine`, `:192-226`): each line wrapped separately; skips indent and list marker; trims whitespace. Triple-clicking `- buy milk   ` gives `- **buy milk**   `. Already wrapped → unwrapped. **No selection** (`inlineWrapCommand`, `:33-95`): caret inside a StrongEmphasis node unwraps it. Else the word under the caret: `hel\|lo` → `**hello**` with `hello` selected. No word → `****` with the caret between the pairs. |
| Italic | Cmd-I | same, with `*` (not `_`). Asterisk counting per `hasWrapper` (`:173-181`): italic on `x` → `*x*`; on `**x**` → `***x***`; on `***x***` → `**x**`. Bold on `*x*` → `***x***`; on `***x***` → `*x*`. |
| Strikethrough | Cmd-Shift-X | per line with a selection; word/caret logic without. |
| Inline code | Cmd-E | `inlineWrapCommand` only: wraps the raw selection, not per line. |
| Link | Cmd-K (**shadowed by the menu's Search…**) | empty → `[](url)` with `url` selected; selection `foo` → `[foo](url)` with `url` selected; inside a link → no-op (`:424-455`). Reachable from the context menu. |
| Bullet list | Cmd-Shift-8 | toggle `- ` on every selected line (removes only if all lines have it) |
| Numbered list | Cmd-Shift-7 | adds `1. `, `2. `… by line index; removes if all have one |
| Blockquote | Cmd-Shift-. | toggle `> ` |
| Task list | Cmd-Shift-Enter | toggle `- [ ] ` (prepends even on a `- ` line: `- [ ] - foo`) |
| H1–H6 | Cmd-Alt-1…6 | replaces an existing `#…` prefix or adds one |
| Paragraph | Cmd-Alt-0 | strips the heading prefix |
| Clear formatting | context menu | regex-strips `**…**`, `*…*`, `~~…~~`, `` `…` `` inside the selection |
| Code block | context menu | wraps the selected lines in ```` ``` ```` fences; unwraps if the first line starts with ```` ``` ```` and the last line is ```` ``` ```` |
| Table | context menu | inserts at the caret `\| Column 1 \| Column 2 \| Column 3 \|\n\| --- \| --- \| --- \|\n\|  \|  \|  \|`, caret after the first `\| ` of row 3 |
| Horizontal rule | context menu | inserts `---\n` at the caret, preceded by `\n` if the line is non-empty |
| Current date / time | context menu | inserts `YYYY-MM-DD` / `HH:MM` (local time) |

**Input handlers** (all Prec.high):
- **`~` with a selection** strikes through the selection per line instead of replacing it. Layout-independent (`:281-285`).
- **Space typed just inside a closing marker** hops outside (`spaceTargetOutsideEmphasis`, `:314-352`). `**bold|**` + space → `**bold** |`. Applies to `***`, `**`, `*`, `~~`, `` ` ``.
  - Only when the previous character is not a space.
  - Only when the run ends exactly there.
  - Only when the same marker appears earlier on the line (so `2 * 3` is left alone).
- **Closing marker typed after a space** (uncommitted, `closeMarkerAfterSpaceEdit`, `:370-418`). The trailing space moves outside once the full closing marker is complete and a matching opener exists: `**this |` + `*` → `**this *` (not yet complete), then + `*` → `**this** |`. The same applies to `~~` and `` ` ``.

### 2.3 Other editor commands and keys
- **Cmd-Shift-D (Go to Today)**, `daily-note.ts:65-91`:
  - If a line trimEnd-equals `## YYYY.MM.DD` (local date), put the caret at its end and scroll to it.
  - Otherwise append, padding so there is exactly one blank line before: `…text` → `…text\n\n## 2026.09.25\n\n|`.
  - **Auto-insert** (`ensureTodayHeading`, `:45-63`) does the same append without moving the caret. Guards: the doc already contains at least one `## dddd.dd.dd` heading, today's heading is missing, and `editor.auto-insert-daily-heading` is on. Triggered on window focus and whenever a pane becomes active.
- **Jump to bottom on return** (`use-jump-to-bottom.ts`): on window focus, if more than `editor.jump-to-bottom-after-minutes` (default 10; 0 disables) have passed since the last activation, move the caret to the end of the document and scroll there. The last-activation time is kept in localStorage `writer:last-activated-at`.
- **Typewriter scrolling**, **on by default**, toggled with Cmd-Alt-C (`use-center-mode.ts`): after input, or a keyup that actually moved the caret, scroll so the caret sits at **70%** of the viewport height. 8px deadzone.
- **Collapse all headings** Cmd-Alt-←: folds every section of depth ≥2 in one transaction. **Expand all** Cmd-Alt-→: unfolds everything.
- **Arrow up/down next to block widgets** (`revealBlockOnArrow.ts`): if the caret is adjacent to (or separated only by whitespace from) a block-replace widget (image, HR, table…), Up/Down moves into the widget's source range, revealing it.
- **Typing `-` as the third dash on line 1**: with line 1 exactly `--` and the caret at column 2, typing `-` creates empty frontmatter and deletes the `--` (`use-prosemark-editor.ts:320-339`).
- **Undo**: CodeMirror history, reset per file (on file switch the setup compartment is reconfigured). Document swaps and external reloads are not added to history.
- **Built-in CodeMirror keys that remain active**: Alt-↑/↓ move line; Shift-Alt-↑/↓ copy line; Cmd-Shift-K delete line; Cmd-Enter insert blank line; Cmd-[ / Cmd-] indent less/more; Cmd-D select next occurrence; Cmd-Shift-L select all matches; Cmd-Alt-G go to line; Cmd-Alt-[ / ] fold/unfold at the caret; Ctrl-Alt-[ / ] fold/unfold all; Cmd-Z / Cmd-Shift-Z; Ctrl-Space completion.

### 2.4 Paste and drop (`use-prosemark-editor.ts:252-318, 760-780`)
Paste handlers run in this order:
1. **Frontmatter paste**: clipboard text starts with `---…---` and the file has no frontmatter → set the frontmatter and insert only the body.
2. **Image paste**: first `image/*` item, ≤5MB → Rust `save_clipboard_image` writes `attachments/YYYYMMDD-HHMMSS-xxxx.{png|jpg|webp}` next to the note (timestamp is **UTC**). Inserts `![{clipboard filename}](attachments/…)` and puts the caret after it. Destinations containing whitespace or `<>` are wrapped in `<…>`.
3. **Rich HTML → markdown** (`html-to-markdown.ts`), only if the HTML contains one of strong, b, em, i, del, s, strike, code, pre, a, img, h1–6, ul, ol, li, blockquote, table, hr, and the result differs from the plain text:
   - b/strong → `**`; i/em → `*`; s/del/strike → `~~`
   - code → backticks (fence widened if needed)
   - pre → fenced block with a `language-x` class used as the info string
   - h1–6 → `#`
   - ul/ol → `- ` / `N. ` with 2-space nesting per level; a leading checkbox becomes `[ ]`/`[x]`
   - a bare `li` → `- item`
   - blockquote → `> `
   - table → GFM (an empty header row is added if the source had none)
   - br → two spaces + newline; hr → `---`
   - Escaping: `\`, `` ` ``, `*`, `_` always; `[x]` only when followed by `(` or `[`; leading `#`/`>`; `N.` at line start. Runs of 3+ newlines collapse to one blank line.
4. Otherwise plain-text paste.

The context menu's "Paste" and "Paste as plain text" both insert plain text.

**Finder image drop**: Rust emits `image:dropped`. Each image is copied to `attachments/` keeping its name (`name-1.ext`, `name-2.ext` on collision). Inserts `![stem](attachments/…)`, each on its own line (a newline is prepended if the caret isn't at line start), caret after (`use-image-drop.ts`).

### 2.5 Links (`use-prosemark-editor.ts:413-492`, `paths.ts:124-197`)
- **Mousedown** on a rendered link, `.cm-url` or an HTML `<a>` is captured, so the caret doesn't move and the link doesn't unfold. Navigation happens on **click**.
- **Link targets**:
  - `#slug` → smooth-scroll to the heading, landing 24px below the top. If missing, a banner: `Heading "#x" not found in this document`.
  - Slugs follow the GFM rules, except that duplicates become `-2`, `-3` (`heading-slug.ts`).
  - `.md`/`.markdown` inside the workspace (relative, absolute or with `#anchor`) → `navigateToFile` in the current tab, then scroll to the anchor.
  - Extensionless paths are probed as `.md`, `.markdown`, `/index.md`, `/index.markdown`, `/README.md`, also root-relative for absolute paths.
  - A URL scheme opens in the default browser. Anything else opens with the system default app.
- **Wiki link click**:
  - If the target contains `/`: workspace-relative `.md`/`.markdown`.
  - Otherwise resolved only when **exactly one** file's stem matches case-insensitively (fuzzy search, 50 results).
  - The `#fragment` is ignored. Unresolved → no-op.
- **Wiki autocomplete** (`:234-305`):
  - Triggered by `[[q` with a non-empty query, outside code.
  - Shows 20 fuzzy results. Label = file stem; detail = relative directory.
  - Inserts `stem]]`, or the relative path without extension when the stem is ambiguous, consuming a following `]]`.
  - Tooltip: UI font 13px, radius 16, blur 16, items 6/10px padding, radius 8.

### 2.6 Find/replace overlay (`editor-search-*.ts(x)`)
- Cmd-F opens it (editor focused). Cmd-G / Cmd-Shift-G go to next/previous, or open it if closed.
- Card at the bottom-right: `bottom 8px`, `right 12px`, width `min(560px, 100% − 1.5rem)`, radius 16, blur 16, `bg-base` at 55%.
- Pre-filled with the selection if it's a single line. Literal, **case-insensitive**.
- Enter / Shift-Enter: next / previous. Esc closes and refocuses the editor.
- "Replace" toggles a second row where Enter = replace next; a Replace All button is in that row.
- Match counter shows current/total. Match ticks appear in the scrollbar overview, capped at 5000.
- Navigation scrolls the match into a band 24px inside the scroller edges, only if it's outside that band.

### 2.7 Editor context menu (`editor-context-menu.ts:36-230`)
- Cut, Copy, Paste, Paste as plain text
- **Format ▸** Bold ⌘B, Italic ⌘I, Strikethrough ⌘⇧X, Inline code ⌘E | Insert link… ⌘K | Clear formatting
- **Paragraph ▸** H1–H6 ⌘⌥1–6, Paragraph ⌘⌥0 | Bullet ⌘⇧8, Numbered ⌘⇧7, Task ⌘⇧↩ | Blockquote ⌘⇧., Code block
- **Insert ▸** Link…, Table, Horizontal rule | Current date, Current time
- Select all
- If right-clicking a link: Open link, Copy link

## 3. App shell

### 3.1 Window and chrome
- **Window** (`src-tauri/tauri.conf.json`): product "Flo State", 1200×800, minimum 400×500. Overlay title bar with hidden title; traffic lights at (20, 29). Transparent, `hudWindow` vibrancy following window-active state. Created hidden and shown after startup.
- **Secondary windows** are placed at a random position within the work area of the monitor under the cursor.
- **Title** (`window-title/index.tsx`): `{filename} - Writer`, `{filename} (unsaved) - Writer`, `{page label} - Writer`, or `Flo State` when there is no tab.
- **Drag region**: the top 72px (`--chrome-drag-height`). Under the tabs, a backing strip 52px tall (`--bg` + blur 24px) starts at the sidebar's right edge.

### 3.2 Tabs (`editor-tabs.tsx`, `editor-store.ts`)
- **Tab kinds**: `file` (kept alive while hidden), `launcher` ("New tab": "Create new note ⌘N" and "Search ⌘O" buttons), `settings` ("Preferences" page).
- **Tab title** = the document title: frontmatter `title:`, else a leading `# ` heading (the first non-blank body line), else the filename (`frontmatter.ts:43-58, 116-126`).
- **Tab look**: 32px tall, max 180px, padding 0 14px, 13px, radius 8. Active: `--tab-active-bg` + backdrop blur. Inactive: muted colour. Hover: a × slides in at the right (the label is masked); a red 6px dot means a save error; the label pulses while loading. A "+" button (36px wide) follows the tabs.
- **Tab strip position**: left = 132px when the sidebar is collapsed, else sidebar width + 12px. Animated over 140ms.
- **Opening files**:
  - **File-tree click**: `openFileInTabOrFocus`. Focuses an existing tab for the file, fills a launcher tab if that's the active one, else opens a new tab.
  - **Pinned/Recents click**: `openFile`. Navigates **in place** in the active file tab (pushes a back-history entry).
  - **Cmd+O / Cmd+K palette**: file results open in a tab or focus the existing one.
  - Files opened from Finder or `open` land as a tab in the window that has a workspace (commit fa649ea).
- **Per-tab history**: back/forward stacks. Alt-← / Alt-→ when no editable element is focused; the View menu has Back and Forward.
- **Closing**:
  - Close tab: the tab to the right becomes active, else the one to the left.
  - **Closing the last tab closes the window** (`editor-store.ts:597-644`).
  - Clean files no longer referenced are pruned from memory.
- **Tab context menu**: Close, Close others, Close all | Reveal in sidebar (expands ancestor folders, shows the sidebar, scrolls to the file), Copy path (workspace-relative).
- **Keyboard**: Cmd-Shift-[ / ], Ctrl-Tab / Ctrl-Shift-Tab cycle tabs with wrap-around. Cmd-1…9 jump to tab N (`use-keyboard-shortcuts.ts`).
- **Drag to reorder** was added in 214de80 and is **removed in the working tree (staged)**.

### 3.3 Sidebar
- **Layout** (`sidebar/index.tsx`, `app-layout.tsx`, `App.css:76-88`):
  - Floating rounded panel: inset 8px (4px on the right), radius 10, bg `fg × contrast × 7%`, 1px border `fg × contrast × 18%`, no shadow.
  - The gutter around it is painted `--bg`.
  - Top row is 56px with the sidebar toggle at its right. Body is the navigator. Bottom is the workspace switcher ("Open Folder…" and recent workspaces).
- **Width**: setting default 240. Drag clamp: 220 to `min(420, max(280, 35% of viewport))`. The resize hit area is 8px wide and shows a 2px #2a6fd6 line on hover or drag. Width transitions take 140ms.
- **Visibility**:
  - `appearance.sidebar-visible` (default true). Toggled by Cmd-\\ (menu), Cmd-. (web view) and the button.
  - **Auto-hidden below 850px window width** without changing the setting (uncommitted, `use-sidebar.ts`).
  - When collapsed, the toggle moves next to the traffic lights (left padding 92px).
- **Sections**:
  - **Pinned** (6 per page, "show more"; stored per workspace in localStorage `writer:pref:workspace:{root}:sidebar-pinned-files`).
  - **Recents** (4 per page, workspace files by mtime; toggle `appearance.sidebar-show-recents`).
  - The **file tree**, with no header.
  - Optional search button (`appearance.sidebar-show-search`, default off).
  - Right-clicking empty space shows check items for those two toggles.
- **Tree rows** (`file-tree-node.tsx`):
  - 32px tall, 13px, radius 8. Indent: 10px at depth 0, else `depth×12+6`.
  - 16px icons at opacity 0.6 (1 on hover). Hovering a folder swaps its icon for a chevron (rotated 90° when open).
  - Labels at opacity 0.6 unless active, selected or hovered.
  - Active file: `--surface-subtle` background. Multi-selected: `--surface-selected`.
  - Label = document title, else the stem (`appearance.sidebar-file-label=filename` forces the stem).
- **Tree interactions**:
  - Shift-click selects a range; Cmd-click toggles a row; Esc clears the selection.
  - Pointer-drag (4px threshold) moves items onto folders, with 28px edge auto-scroll.
  - Multi-selection context menu: Copy relative/absolute paths, Delete.
- **Tree content**: dotfiles hidden; folders listed only if they contain supported files anywhere below; folders first, then case-insensitive alphabetical; `.gitignore` rules respected per directory (`ignore.rs`).
- **File menu**: Open, Open in new tab, Pin/Unpin | Duplicate | Copy relative path, Copy absolute path | Reveal in Finder | Rename…, Delete (to Trash; confirms if the file has unsaved changes).
- **Folder menu**: New File (`Untitled.md`, then `Untitled 2.md`…, created with content `# ` and then renamed inline), New Folder (`Untitled Folder`) | copy paths | Reveal | Rename…, Delete.
- **Stepping through files**: Cmd-Alt-↑/↓ steps through files in the visible tree order in the current tab. It stops at the ends rather than wrapping.

### 3.4 Files, saving and reloading
- **Supported extensions**: from `files.associations` (default `*.md`, `*.mdx`, `*.markdown`, `*.csv`); the Rust fallback also accepts `txt` (`open_target.rs:99`).
- **New file** content is exactly `# ` (`fs.rs:390`). On first open the caret goes to position 2.
- **Autosave**, throttled per file to **1000ms** (`save.ts`):
  - Every edit sets the file dirty and schedules a save: immediately if more than 1s since the last save, else when the 1s elapses. One write in flight at a time; changes made during a write trigger a follow-up save.
  - Before writing: if `files.trim-trailing-whitespace` (default **false**), strip trailing whitespace from every line; if `files.insert-final-newline` (default **true**), append `\n` if missing.
  - Write is atomic: a temp file `.~{uuid}` in the same directory, then rename.
  - On error the tab shows the red dot. Close/quit does not prompt.
- **External change** (`use-file-watcher.ts`, `watcher.rs`):
  - Watcher debounce 300ms. The app's own writes are suppressed for 2s.
  - On `fs:file-changed` for an open file with no save in flight: cancel the pending save, re-read, and if the content differs from the last saved/loaded disk content, **replace the buffer** (discarding unsaved edits). Caret is kept, clamped to the new length. Not added to undo history.
  - Deletions are ignored.
  - A directory change refreshes that directory and its parent in the tree.
  - A change to `.writer/config` reloads settings.
- **Session** (`workspace-store.ts:392-413`, Rust `save_session`):
  - Saved 500ms after any tab-list or active-tab change, and on window unload.
  - Stored in `{app_data}/sessions.json`, keyed by workspace root: each tab's location plus back/forward stacks, and the active index. Launcher tabs are not saved. Cursor and scroll positions are **not** persisted.
  - Restored on launch (active tab loaded first) if `workspace.restore-open-files`. The last workspace is reopened if `window.restore-workspace`.
- **Recents**:
  - Recent workspaces: `recent_workspaces.json`, max 10.
  - Global recent files: `recent_files.json`, max 30, used by the compact window's picker.
- **Compact window**: when a file is opened with no workspace. No tabs or sidebar; a file-picker header. The command palette searches global recents.

### 3.5 Outline rail (`section-rail.tsx`)
- Right edge, left of the 18px scrollbar gutter. Shown only if `editor.show-outline` is on and the document has H1–H3 headings.
- **Ticks**: one per heading, 1px tall with 6px gaps, vertically centred. Active tick 20px wide at opacity 1; others scaled to 10px at opacity 0.35. 300ms transition.
- The active heading is the last one whose top has scrolled above scroller-top + 28px, else the first.
- **Popover**: opens on hover (stays open while the pointer moves between rail and popover; Esc closes). Width 260px, `max-h 70vh`, rows 13px with line-height 1.5 and 4px gap. Indent `max(0, level−2) × editor.outline-indent-per-level` (default 12). Opens scrolled so the active row is centred.
- Clicking a tick or row scrolls to the heading, 24px below the top. Right-click: "Copy heading link" → `[text](#slug)`.
- Headings inside code fences are ignored.

### 3.6 Status bar and stats
- A footer at the bottom-right, 44px tall, 13px muted text. Shows words, characters and/or paragraphs, each off by default (`statusbar.show-*`). Right-click toggles each.
- **Stats** (`document-stats.ts`): strip heading/list/quote prefixes, backticks, `[[x]]` → `x`, `[t](u)` → `t`. Words = runs of non-whitespace. Characters = code points after collapsing whitespace to single spaces. Paragraphs = blocks separated by blank lines.

### 3.7 Command palette (Cmd-O = search, Cmd-K = menu Search…, Cmd-N = create)
- **Look**: fixed at top 16%, width `min(560px, 90vw)`, radius 16, blur. Input 13px; list max-height 320px; items 10/12px padding, radius 10.
- **Search mode**: commands shown when the query is empty, filtered by substring otherwise:
  - Toggle Sidebar, Create New File, Open File in Compact Window, Close Current Tab, Close All Tabs, Open Workspace, Close Workspace, Toggle Dark Mode (cycles system → light → dark), Settings.
  - Then fuzzy file results.
- **Fuzzy search** (`search.rs:84-147`): case-insensitive substring over the relative path, also trying the query with spaces→hyphens and hyphens→spaces. Score: +1,000,000 if the match is in the filename, + (10,000 − match offset), + (1,000 − path length). Matched characters are highlighted in accent colour.
- **Create mode**: `Create: {name}.md` in the workspace root (or next to the active file in a compact window). The file is created with `# ` and opened in a tab.

### 3.8 Menus (`lib.rs:339-518`)
- **Writer**: About, Check for Updates…, Preferences… ⌘, (opens or focuses the Settings tab), Install/Uninstall `writer` CLI, Services, Hide, Hide Others, Show All, Quit.
- **File**: New Note ⌘N (palette in create mode), New Tab ⌘T, Go to Today ⌘⇧D, Search… ⌘K, Close Tab ⌘W.
- **Edit**: Undo, Redo, Cut, Copy, Paste, Select All, plus Substitutions.
- **View**: Toggle Sidebar ⌘\\, Toggle Typewriter Scrolling ⌘⌥C | Increase ⌘=, Decrease ⌘−, Reset ⌘0 font size | Collapse All Headings ⌘⌥←, Expand All Headings ⌘⌥→ | Back, Forward.
- **Window**: Minimize, Fullscreen, Close.
- Items are routed as `menu:*` events to the focused window.
- The Dock menu lists recent workspaces. The app is single-instance: a second launch with a path is routed to the running app.

### 3.9 Settings (all keys and defaults)
The Preferences page shows a section per category (13px muted header); the Theme section is custom. Values are stored in a Ghostty-style `key = value` file: global at `{app_data}/config`, workspace overrides at `{root}/.writer/config`.

- **Editor**:
  - `editor.font-size` 16
  - `editor.line-height` 1.5
  - `editor.tab-size` 2 (**unused anywhere**)
  - `editor.auto-insert-daily-heading` true
  - `editor.show-outline` true
  - `editor.show-heading-chevrons` true
  - `editor.outline-indent-per-level` 12
  - `editor.jump-to-bottom-after-minutes` 10
  - `editor.heading-space-before` 0px
  - `editor.heading-space-after` 8px
  - `editor.subheading-color` #3a3a3a
  - `editor.paragraph-spacing` 0px
  - `editor.bullet-spacing` 12px
- **Status bar**: `statusbar.show-words`, `statusbar.show-characters`, `statusbar.show-paragraphs`, all false.
- **Appearance**:
  - `appearance.theme` system
  - `appearance.sidebar-width` 240
  - `appearance.sidebar-visible` true
  - `appearance.sidebar-file-label` title
  - `appearance.sidebar-show-search` false
  - `appearance.sidebar-show-recents` true
  - `appearance.editor-width` full (see §9)
- **Fonts**: `fonts.ui`, `fonts.editor`, `fonts.mono` (stacks in §1.1).
- **Theme**: `theme.{light,dark}.{preset, accent, background, foreground, heading-color, translucent, contrast}` (values in §1.1).
- **Files**:
  - `files.associations` [*.md, *.mdx, *.markdown, *.csv]
  - `files.default-encoding` utf-8
  - `files.insert-final-newline` true
  - `files.trim-trailing-whitespace` false
- **Workspace / window**: `workspace.restore-open-files` true, `workspace.max-recent-workspaces` 10, `window.restore-workspace` true.
- **Search**: `search.debounce-ms` 150, `search.max-results` 50.

## 4. Tauri backend commands (`src-tauri/src/lib.rs:725-767`)
| Command | Semantics |
|---|---|
| `read_directory(path)` | One level. Skips dotfiles and ignored paths; folders only if they contain supported files; files carry `title` (frontmatter `title:` or a leading `# `), `modified_at`; folders first, then alphabetical (case-insensitive). |
| `read_file(path)` | `{path, content, modified_at}` |
| `write_file(path, content)` | Atomic temp-file + rename; records the write so the watcher suppresses it for 2s; updates the index mtime; emits `sidebar:metadata-changed`. |
| `read_recent_files(limit=8, offset)` | Workspace files by index mtime, newest first. |
| `read_file_entries(paths)` | `DirEntry` for paths inside the root. |
| `create_file(path)` | Fails if it exists; creates parent folders; content `# `. |
| `create_directory`, `rename_entry(old,new)` | Rename fails if the target exists. |
| `delete_entry(path)` | Moves to Trash. |
| `file_exists`, `reveal_in_file_manager` | Reveal uses `open -R`. |
| `open_workspace(path)` | Canonicalises the path; resets per-window state; loads `.writer/config`; pushes to recent workspaces; in the background starts the watcher, gitignore matcher and file index, then emits `index:complete(count)`. |
| `restore_workspace`, `get_startup_state` | Startup bundle: settings, recent workspaces, then either a standalone file or the directory listing + session + prefetched active file. |
| `get_recent_workspaces`, `remove_recent_workspace` | |
| `take_pending_open` | Drains the queued open payloads (`{workspace?, file?}`) from drops, Dock, argv or Finder. |
| `open_workspace_in_new_window(path, file?)` | Focuses an existing window for that workspace, else creates a new window. |
| `open_file_in_standalone_window`, `watch_standalone_file` | Compact window; single-file watcher. |
| `save_session(root, tabs, active_index)` / `load_session` | `sessions.json`, locked read-modify-write. An empty session deletes the key. |
| `list_system_fonts` | Cached list of font families. |
| `record_recent_file`, `remove_recent_file`, `get_recent_files_global` | `recent_files.json`, max 30; entries that can't be stat'ed are hidden but kept. |
| `index_workspace`, `fuzzy_search(query, limit)` | Parallel gitignore-aware walk; scoring in §3.7. |
| `find_file_by_name(root, name)` | Case-insensitive exact basename match; the shallowest path wins. |
| `save_clipboard_image(md_path, bytes, format)` | `attachments/YYYYMMDD-HHMMSS-xxxx.ext` (UTC). The Rust tests still expect `note-assets/`, so they are stale. |
| `import_image_file(md_path, src)` | Copies into `attachments/`, keeping the name, adding `-N` on collision. |
| `get_settings`, `get_setting`, `set_setting(key, value, scope)`, `reset_setting` | Global or workspace scope. |
| `cli_status`, `install_cli`, `uninstall_cli` (macOS) | The `writer` shell command. |

**Events emitted to the frontend**: `fs:file-changed`, `fs:directory-changed` (`{path, kind}`), `settings:changed`, `index:complete`, `sidebar:metadata-changed`, `open:from-drop`, `image:dropped`, `menu:*`.

## 9. Quirks to decide on (copy or fix)
1. **Cmd-K never inserts a link.** The menu's Search… takes the key equivalent first.
2. **`appearance.editor-width` has no effect.** `--writer-editor-max-width` is set on a child element, but `--writer-editor-outer-width` was already resolved at `:root`, so the column stays 734px.
3. **Subheading colour #3a3a3a is the same in both modes**, so H2 and H3 are nearly invisible on a dark background.
4. **The syntax palette for code blocks is the dark one in light mode too** (`lightTheme` is never installed).
5. **`editor.tab-size` is unused.** Indent on non-list lines uses CodeMirror's default indent unit.
6. **Sidebar auto-hide below 850px also blocks showing it.** The toggle only flips the saved preference, so the sidebar cannot be shown at that width.
7. **An external file change silently discards unsaved edits.**
8. **Date formats differ**: the daily heading uses `YYYY.MM.DD`, "Insert current date" uses `YYYY-MM-DD`.
9. **The comment at `prosemark-theme.css:276` says clicking the hash folds the section; the code only places the caret.**
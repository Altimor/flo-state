# Keys parity: residual differences from the web app

`Tests/FloCoreTests/KeysParityTests.swift` replays `fixtures/keys.jsonl` (2082 cases) and
`fixtures/keys-extra.jsonl` (118 cases: undo grouping, less common bindings, nested code
languages, frontmatter). Each case is real keystrokes recorded in the web app through CDP.

Latest run: **2153/2153 pass (100%)** of the cases the model can decide. Everything else is
listed below with the reason. Nothing is excluded silently: the test prints every excluded case,
tagged `[layout]` or `[dom-edit]`, to `$TMPDIR/keys-parity-failures.txt`.

| Bucket | Count | Why they are not compared |
|---|---|---|
| Skipped: `Up` / `Down` / `Shift-Up` / `Shift-Down` | 12 | Vertical motion needs line-wrapping geometry. The `EditorLayout` hook gets this from TextKit in the app. |
| Excluded `[layout]` | 28 | The result came from CM's visual geometry (`moveToLineBoundary` with wrapping, or `moveVertically`). See 1–3. |
| Excluded `[dom-edit]` | 7 | Chrome's contenteditable changed a replaced selection differently from CM's model. See 4. |

A case counts as `[layout]` or `[dom-edit]` only if it fails **and** its replay actually reached
that code path: the recording layout saw a wrap-prone or decorated line, or text was typed over a
DOM-sensitive selection. Cases that reach those paths and still match are counted as passes.

## 1. Soft-wrapped lines (Home, End, Cmd-Left/Right, Cmd-Backspace after End)
Example: fuzz154, fuzz240, fuzz248, fuzz315, fuzz488, fuzz665, fuzz679, fuzz807, fuzz87, fuzz97,
fuzz160, fuzz203, fuzz209, fuzz251, fuzz366.

CM's `cursorLineBoundaryForward/Backward` and `deleteLineBoundaryBackward` go to the **visual**
line edge. The editor column is 734px wide, so a line of about 90 characters or more wraps, and
Home/End stop at the wrap point. For example, `End` from column 50 of a 180-character line lands
at column 89, not at the end of the line. `MonospaceLayout` doesn't wrap. The app's
`EditorLayout` has to supply TextKit line fragments here; the command code already routes through
it.

## 2. Hit-testing on rendered list, quote and tab prefixes (Cmd-Backspace, Home)
Examples: `list[3|7|12|18] … Mod-Backspace`, fuzz185, fuzz265, fuzz600.

With wrapping on, CM finds a visual line start with `posAtCoords(editor left edge)`. On lines whose
start is rendered by decorations, Chrome's hit test lands inside the prefix instead of at
`line.from`:

| Line | Visual start (web) |
|---|---|
| `- foo` | `line.from` |
| `  - foo` | +2 |
| `- [ ] task` | +2 |
| `> - item` | +2 |
| `- ## h` | +2 |
| `\tx` | +1 |

The prefix is an inline-block with absolutely positioned marker spans and `text-align: right`.
The measurements came from probing `view.moveToLineBoundary` in the oracle. So `  - foo|` +
Cmd-Backspace deletes back to column 2, not to the line start. This is a DOM artefact, not a
designed behaviour. The native `EditorLayout.moveToLineBoundary` decides this from real
geometry, and returning the logical line start (what `MonospaceLayout` does) is the sane choice.

## 3. Proportional-font column for `deleteLine` (Cmd-Shift-K)
Example: `misc Mod-Shift-k mid`.

`deleteLine` moves the cursor down with `moveVertically` before mapping it, so the goal column is a
pixel x in SF Pro, not a character count. The layout hook provides this.

## 4. Typing over selections that Chrome's contenteditable edits its own way
Examples: fuzz223, fuzz373, fuzz404, fuzz441, fuzz500, fuzz632, fuzz653.

CM applies a typed character by reading back what the browser did to the DOM. If the selection
crosses a line break, or starts inside the inline-block list prefix, Chrome doesn't do a plain
replace:
- **Selection from a line end into the next line's list prefix** (fuzz223, fuzz373, fuzz441):
  Chrome keeps the line break, inserts at the selection start and deletes only the prefix
  characters. `…product |\n  |* Grok` + `x` becomes `…product x\n* Grok`, not
  `…product x* Grok`.
- **Selection starting inside a list prefix** (fuzz404, fuzz500, fuzz653): the caret or the kept
  line break lands on a different side of the insertion. With fuzz500, a later Enter then
  produced extra line breaks.
- **Selection ending inside an image widget line** (fuzz632): Chrome left an extra `\n`.

The port uses CM's model (`replaceSelection`), which is what NSTextView does natively. These
are browser editing artefacts, not app behaviour.

## Reproduced on purpose (quirks the port keeps)
These look odd but are what the web app does, and the fixtures depend on them:
- **Transaction filters remap the selection a second time.** A filter that returns
  `[tr, {selection}]` (heading guard, list-prefix guard) goes through CM's `mergeTransaction`, which
  maps the filter's selection (already in new-document coordinates) through the transaction's
  changes again. If a position then falls past the old document length, CM throws a RangeError
  and the whole keystroke is dropped. Examples:
  - `Cmd-Alt-1` on `hello world` does nothing.
  - `Cmd-Alt-1` on `## Heading` gives `# Heading` with the selection `[9,0]`.
  - `Cmd-Shift-8` on a heading line does nothing.

  See `Pipeline.dispatch`.
- **`insertNewlineAndIndent` slices `line.text` with the absolute `from`.** So "caret in leading
  whitespace moves the insert point to the line start" only fires on lines near the start of the
  document.
- **macOS Option-Up/Down fallback.** When `moveLineUp/Down` returns false (first or last line),
  CM doesn't call preventDefault. The browser then moves to the paragraph start or end, and the
  port does the same.
- **`allowMultipleSelections` is off.** Every selection is reduced to its main range, so
  `selectNextOccurrence` (Cmd-D) with a selection has no visible effect.
- **History:** grouping follows CM exactly (`newGroupDelay` 500ms, `input.type`/`delete` join
  only when adjacent and no selection event came in between). The oracle's `setDoc` is itself an
  undoable change, so the test seeds history with the previous document.

## Not modelled (no fixture exercises them)
- **Autocomplete popup (wiki links `[[`, HTML tags `<`).** While the popup is open, CM's
  completion keymap (Prec.highest) takes Enter, Tab, arrows and Escape. The native app will have
  its own completion UI, which should consume those keys before `Keymap.handle`.
- **`indentOnInput` and `getIndentation` inside fenced code with a nested language** (for example
  JS reindenting `}`). Markdown's indent service returns null, so the port always keeps the
  current line's indentation. Nested-language detection
  (`EditorState.markdownActiveAt`) *is* modelled, so lang-markdown's commands switch off inside
  such fences, as in the web app.
- **Heading fold keys (Cmd-Alt-Left/Right, Cmd-Alt-[/]), search keys, Cmd-Shift-L, Ctrl-Space.**
  The AppKit layer owns folding and search.

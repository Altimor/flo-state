import Foundation

// The web app's full keymap stack, in CodeMirror precedence order
// (use-prosemark-editor.ts createEditorExtensions + prosemarkBasicSetup):
//
//  Prec.highest  list prefix arrows, list keys (Backspace, Mod-Backspace,
//                Enter, Tab, Shift-Tab), heading escape-left
//  Prec.high     lang-markdown (Enter, Backspace), app keys (Mod-Shift-d),
//                app formatting keymap
//  default       revealBlockOnArrow, prosemark formatting keymap,
//                defaultKeymap, searchKeymap, historyKeymap, indentWithTab
//
// Within one key, bindings run in order until one returns true (CM's
// fall-through semantics).

public enum Keymap {
    /// Canonical chord: modifiers in the order Alt, Ctrl, Mod, Shift, then the
    /// base key with CM names (ArrowLeft, Enter, ...). Accepts "Left",
    /// "ArrowLeft", "Cmd"/"Meta"/"Mod", "Option"/"Alt".
    public static func normalize(_ key: String) -> String {
        var parts = key.components(separatedBy: "-")
        if key.hasSuffix("--") { parts = Array(key.dropLast(2).components(separatedBy: "-")) + ["-"] }
        var base = parts.removeLast()
        var alt = false, ctrl = false, mod = false, shift = false
        for p in parts {
            switch p.lowercased() {
            case "alt", "option", "opt": alt = true
            case "ctrl", "control": ctrl = true
            case "mod", "cmd", "meta", "command": mod = true
            case "shift": shift = true
            default: break
            }
        }
        let names = ["left": "ArrowLeft", "right": "ArrowRight", "up": "ArrowUp", "down": "ArrowDown",
                     "arrowleft": "ArrowLeft", "arrowright": "ArrowRight", "arrowup": "ArrowUp", "arrowdown": "ArrowDown",
                     "enter": "Enter", "return": "Enter", "backspace": "Backspace", "delete": "Delete", "tab": "Tab",
                     "escape": "Escape", "esc": "Escape", "home": "Home", "end": "End", "space": " ",
                     "pageup": "PageUp", "pagedown": "PageDown"]
        if let n = names[base.lowercased()] { base = n } else if base.count == 1 { base = base.lowercased() }
        return (alt ? "Alt-" : "") + (ctrl ? "Ctrl-" : "") + (mod ? "Mod-" : "") + (shift ? "Shift-" : "") + base
    }

    static let bindings: [String: [Command]] = {
        var table: [String: [Command]] = [:]
        func bind(_ key: String, _ run: Command?, shift: Command? = nil) {
            if let run = run { table[normalize(key), default: []].append(run) }
            if let shift = shift { table[normalize("Shift-" + key), default: []].append(shift) }
        }
        // --- Prec.highest ---
        bind("ArrowLeft", ListCommands.arrow(left: true, extend: false))
        bind("ArrowRight", ListCommands.arrow(left: false, extend: false))
        bind("Shift-ArrowLeft", ListCommands.arrow(left: true, extend: true))
        bind("Shift-ArrowRight", ListCommands.arrow(left: false, extend: true))
        bind("Backspace", ListCommands.listBackspace)
        bind("Mod-Backspace", ListCommands.listDeleteToContentStart)
        bind("Enter", ListCommands.listEnter)
        bind("Tab", ListCommands.listIndent)
        bind("Shift-Tab", ListCommands.listOutdent)
        bind("ArrowLeft", AppCommands.escapeHashLeft)
        bind("Shift-ArrowLeft", AppCommands.escapeHashLeftExtend)
        // --- Prec.high ---
        bind("Enter", markdownOnly(MarkdownLang.insertNewlineContinueMarkup))
        bind("Backspace", markdownOnly(MarkdownLang.deleteMarkupBackward))
        bind("Mod-Shift-d", AppCommands.goToDailyNote)
        bind("Mod-b", Formatting.toggleBold)
        bind("Mod-i", Formatting.toggleItalic)
        bind("Mod-k", Formatting.insertLink)
        bind("Mod-e", Formatting.toggleInlineCode)
        bind("Mod-Shift-x", Formatting.toggleStrikethrough)
        bind("Mod-Shift-8", Formatting.toggleBulletList)
        bind("Mod-Shift-7", Formatting.toggleNumberedList)
        bind("Mod-Shift-.", Formatting.toggleBlockquote)
        bind("Mod-Shift-Enter", Formatting.toggleTaskList)
        for level in 1...6 { bind("Mod-Alt-\(level)", Formatting.setHeading(level)) }
        bind("Mod-Alt-0", Formatting.setParagraph)
        // --- default ---
        bind("ArrowUp", AppCommands.revealBlock(true))
        bind("ArrowDown", AppCommands.revealBlock(false))
        bind("Mod-b", Formatting.pmToggleStrongEmphasis)
        bind("Mod-i", Formatting.pmToggleEmphasis)
        bind("Mod-k", Formatting.pmInsertLink)
        bind("Mod-Shift-x", Formatting.pmToggleStrikethrough)
        // defaultKeymap (macOS bindings)
        bind("Alt-ArrowUp", CM.moveLineUp)
        bind("Shift-Alt-ArrowUp", CM.copyLineUp)
        bind("Alt-ArrowDown", CM.moveLineDown)
        bind("Shift-Alt-ArrowDown", CM.copyLineDown)
        bind("Escape", CM.simplifySelection)
        bind("Mod-Enter", CM.insertBlankLine)
        bind("Mod-[", CM.indentLess)
        bind("Mod-]", CM.indentMore)
        bind("Shift-Mod-k", CM.deleteLine)
        // standardKeymap
        bind("ArrowLeft", CM.cursorCharLeft, shift: CM.selectCharLeft)
        bind("Alt-ArrowLeft", CM.cursorGroupLeft, shift: CM.selectGroupLeft)
        bind("Mod-ArrowLeft", CM.cursorLineBoundaryBackward, shift: CM.selectLineBoundaryBackward)
        bind("ArrowRight", CM.cursorCharRight, shift: CM.selectCharRight)
        bind("Alt-ArrowRight", CM.cursorGroupRight, shift: CM.selectGroupRight)
        bind("Mod-ArrowRight", CM.cursorLineBoundaryForward, shift: CM.selectLineBoundaryForward)
        bind("ArrowUp", CM.cursorLineUp, shift: CM.selectLineUp)
        bind("Mod-ArrowUp", CM.cursorDocStart, shift: CM.selectDocStart)
        bind("ArrowDown", CM.cursorLineDown, shift: CM.selectLineDown)
        bind("Mod-ArrowDown", CM.cursorDocEnd, shift: CM.selectDocEnd)
        bind("Home", CM.cursorLineBoundaryBackward, shift: CM.selectLineBoundaryBackward)
        bind("Mod-Home", CM.cursorDocStart, shift: CM.selectDocStart)
        bind("End", CM.cursorLineBoundaryForward, shift: CM.selectLineBoundaryForward)
        bind("Mod-End", CM.cursorDocEnd, shift: CM.selectDocEnd)
        bind("Enter", CM.insertNewlineAndIndent, shift: CM.insertNewlineAndIndent)
        bind("Mod-a", CM.selectAll)
        bind("Backspace", CM.deleteCharBackward, shift: CM.deleteCharBackward)
        bind("Delete", CM.deleteCharForward)
        bind("Alt-Backspace", CM.deleteGroupBackward)
        bind("Alt-Delete", CM.deleteGroupForward)
        bind("Mod-Backspace", CM.deleteLineBoundaryBackward)
        bind("Mod-Delete", CM.deleteLineBoundaryForward)
        // emacs-style bindings that macOS gets by default
        bind("Ctrl-b", CM.cursorCharLeft, shift: CM.selectCharLeft)
        bind("Ctrl-f", CM.cursorCharRight, shift: CM.selectCharRight)
        bind("Ctrl-p", CM.cursorLineUp, shift: CM.selectLineUp)
        bind("Ctrl-n", CM.cursorLineDown, shift: CM.selectLineDown)
        bind("Ctrl-d", CM.deleteCharForward)
        bind("Ctrl-h", CM.deleteCharBackward)
        bind("Ctrl-Alt-h", CM.deleteGroupBackward)
        // searchKeymap
        bind("Mod-d", CM.selectNextOccurrence)
        // historyKeymap
        bind("Mod-z", CM.undo)
        bind("Mod-Shift-z", CM.redo)
        bind("Mod-u", CM.undoSelection)
        bind("Mod-Shift-u", CM.redoSelection)
        // indentWithTab
        bind("Tab", CM.indentMore, shift: CM.indentLess)
        // Browser-native fallbacks for keys CM leaves unhandled without
        // preventDefault (macOS Option-Up/Down paragraph motion).
        bind("Alt-ArrowUp", CM.nativeParagraphMove(false, extend: false))
        bind("Alt-ArrowDown", CM.nativeParagraphMove(true, extend: false))
        return table
    }()

    static func markdownOnly(_ c: @escaping Command) -> Command {
        return { t in t.state.markdown ? c(t) : false }
    }

    /// Run the key's bindings in precedence order. Returns the new state, or
    /// nil when no binding handled the key (the state is then unchanged).
    public static func handle(_ key: String, state: EditorState, env: CommandEnv) -> EditorState? {
        guard let cmds = bindings[normalize(key)] else { return nil }
        let t = CommandTarget(state: state, env: env)
        for c in cmds {
            let ok = c(t)
            if t.aborted { return t.state }
            if ok { return t.state }
        }
        return nil
    }

    /// Typed characters: keydown handlers, then input handlers, then CM's
    /// default "replace the selection" insert (userEvent input.type).
    public static func insertText(_ text: String, state: EditorState, env: CommandEnv) -> EditorState {
        var s = state
        for ch in text {
            let c = String(ch)
            if c == "\n" || c == "\r" {
                s = handle("Enter", state: s, env: env) ?? s
                continue
            }
            let t = CommandTarget(state: s, env: env)
            // keydown: frontmatter `---` start
            if c == "-" && AppCommands.frontmatterStart(t) { s = t.state; continue }
            let sel = s.selection.main
            var handled = false
            for h in Formatting.inputHandlers where h(t, sel.from, sel.to, c) { handled = true; break }
            if !handled {
                var spec = s.replaceSelection(c)
                spec.userEvent = "input.type"
                t.dispatch(spec)
            }
            s = t.state
        }
        return s
    }
}

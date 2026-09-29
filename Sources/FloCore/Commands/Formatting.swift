import Foundation

// Port of src/components/editor-area/markdown-formatting.ts (app formatting
// commands + input handlers) and src/lib/prosemark-core/markdownFormattingKeymap.ts
// (prosemark's own toggles, shadowed by the app's except where the app's
// command returns false).

public enum Formatting {
    // MARK: helpers

    static func findEnclosingNode(_ state: EditorState, _ pos: Int, _ name: String) -> (from: Int, to: Int)? {
        var node: SyntaxNode? = Lezer.resolveInner(state.tree, pos, -1)
        while let n = node {
            if n.name == name { return (n.from, n.to) }
            node = n.parent
        }
        return nil
    }

    static func inlineWrapCommand(_ marker: String, _ nodeName: String) -> Command {
        let len = marker.utf16.count
        return { t in
            let state = t.state
            let spec = state.changeByRange { range in
                if let existing = findEnclosingNode(state, range.from, nodeName) {
                    let innerFrom = existing.from + len, innerTo = existing.to - len
                    let inner = state.sliceDoc(innerFrom, innerTo)
                    let innerLen = inner.utf16.count
                    let newFrom = max(existing.from, min(range.from - len, existing.from + innerLen))
                    let newTo = max(existing.from, min(range.to - len, existing.from + innerLen))
                    return ([Change(from: existing.from, to: existing.to, insert: inner)],
                            SelectionRange.range(max(existing.from, newFrom), max(existing.from, newTo)))
                }
                if range.from == range.to {
                    if let word = state.wordAt(range.from) {
                        let text = state.sliceDoc(word.from, word.to)
                        return ([Change(from: word.from, to: word.to, insert: marker + text + marker)],
                                SelectionRange.range(word.from + len, word.from + len + text.utf16.count))
                    }
                    return ([Change(from: range.from, insert: marker + marker)], SelectionRange.cursor(range.from + len))
                }
                let selected = state.sliceDoc(range.from, range.to)
                return ([Change(from: range.from, to: range.to, insert: marker + selected + marker)],
                        SelectionRange.range(range.from + len, range.from + len + selected.utf16.count))
            }
            var s = spec
            s.userEvent = "input.format.\(nodeName)"
            t.dispatch(s)
            return true
        }
    }

    static let LIST_MARKER = JSRegex("^[ \\t]*(?:[-*+]|\\d+[.)])[ \\t]+")
    static let STRIKE = "~~"

    static func formatSpanForLine(_ state: EditorState, _ lineNumber: Int, _ selFrom: Int, _ selTo: Int) -> (from: Int, to: Int)? {
        let line = state.doc.line(lineNumber)
        var from = max(line.from, selFrom)
        var to = min(line.to, selTo)
        if to <= from { return nil }
        if let m = LIST_MARKER.exec(line.text) {
            let markerEnd = line.from + m.length
            if from < markerEnd { from = markerEnd }
        }
        while from < to, let c = state.doc.char(at: from), CMText.isSpaceOrTab(c) { from += 1 }
        while to > from, let c = state.doc.char(at: to - 1), CMText.isSpaceOrTab(c) { to -= 1 }
        return to > from ? (from, to) : nil
    }

    static func runAtStart(_ text: [UInt16], _ ch: UInt16) -> Int {
        var n = 0
        while n < text.count && text[n] == ch { n += 1 }
        return n
    }
    static func runAtEnd(_ text: [UInt16], _ ch: UInt16) -> Int {
        var n = 0
        while n < text.count && text[text.count - 1 - n] == ch { n += 1 }
        return n
    }

    static func hasWrapper(_ text: String, _ marker: String) -> Bool {
        let u = Array(text.utf16), m = Array(marker.utf16)
        let star: UInt16 = 0x2A
        if m[0] != star {
            return text.hasPrefix(marker) && text.hasSuffix(marker) && u.count > m.count * 2
        }
        let paired = min(runAtStart(u, star), runAtEnd(u, star))
        if u.count <= paired * 2 { return false }
        return m.count == 1 ? paired % 2 == 1 : paired >= m.count
    }

    static func wrapSelectionPerLine(_ marker: String, _ userEvent: String) -> Command {
        let mlen = marker.utf16.count
        return { t in
            let state = t.state
            var changes: [Change] = []
            for range in state.selection.ranges {
                if range.empty { continue }
                let first = state.doc.lineAt(range.from).number
                let last = state.doc.lineAt(range.to).number
                for n in first...last {
                    guard let span = formatSpanForLine(state, n, range.from, range.to) else { continue }
                    let text = state.sliceDoc(span.from, span.to)
                    if hasWrapper(text, marker) {
                        changes.append(Change(from: span.from, to: span.from + mlen))
                        changes.append(Change(from: span.to - mlen, to: span.to))
                    } else {
                        changes.append(Change(from: span.from, insert: marker))
                        changes.append(Change(from: span.to, insert: marker))
                    }
                }
            }
            if changes.isEmpty { return false }
            t.dispatch(TransactionSpec(changes: changes, userEvent: userEvent))
            return true
        }
    }

    public static let strikeSelection = wrapSelectionPerLine(STRIKE, "input.format.Strikethrough")
    public static let boldSelection = wrapSelectionPerLine("**", "input.format.StrongEmphasis")
    public static let italicSelection = wrapSelectionPerLine("*", "input.format.Emphasis")

    static let wrapBoldAtCaret = inlineWrapCommand("**", "StrongEmphasis")
    static let wrapItalicAtCaret = inlineWrapCommand("*", "Emphasis")

    static func selectionAware(_ onSelection: @escaping Command, _ atCaret: @escaping Command) -> Command {
        return { t in t.state.selection.ranges.allSatisfy { $0.empty } ? atCaret(t) : onSelection(t) }
    }

    public static let toggleBold = selectionAware(boldSelection, wrapBoldAtCaret)
    public static let toggleItalic = selectionAware(italicSelection, wrapItalicAtCaret)
    public static let toggleInlineCode = inlineWrapCommand("`", "InlineCode")
    public static let toggleStrikethrough = selectionAware(strikeSelection, inlineWrapCommand("~~", "Strikethrough"))

    // MARK: input handlers (return true when they handled the insertion)

    typealias InputHandler = (_ t: CommandTarget, _ from: Int, _ to: Int, _ text: String) -> Bool

    static let strikeOnTilde: InputHandler = { t, _, _, text in
        if text != "~" { return false }
        if t.state.selection.ranges.allSatisfy({ $0.empty }) { return false }
        return strikeSelection(t)
    }

    static let CLOSING_MARKERS = ["***", "**", "*", "~~", "`"]

    public static func spaceTargetOutsideEmphasis(_ state: EditorState, _ pos: Int) -> Int? {
        let line = state.doc.lineAt(pos)
        let before = state.sliceDoc(max(line.from, pos - 1), pos)
        if before.isEmpty || before == " " || before == "\t" { return nil }
        let after = state.sliceDoc(pos, min(line.to, pos + 3))
        guard let marker = CLOSING_MARKERS.first(where: { after.hasPrefix($0) }) else { return nil }
        let runLen = runAtStart(Array(after.utf16), marker.utf16.first!)
        if runLen != marker.utf16.count { return nil }
        let head = state.sliceDoc(line.from, pos)
        if !head.contains(marker) { return nil }
        return pos + marker.utf16.count
    }

    static let spaceOutsideEmphasis: InputHandler = { t, from, to, text in
        if text != " " || from != to { return false }
        guard let at = spaceTargetOutsideEmphasis(t.state, from) else { return false }
        t.dispatch(TransactionSpec(changes: [Change(from: at, insert: " ")], selection: .single(at + 1), userEvent: "input.type"))
        return true
    }

    public static func closeMarkerAfterSpaceEdit(_ before: String, _ char: String) -> (from: Int, to: Int, insert: String, caret: Int)? {
        if char != "*" && char != "~" && char != "`" { return nil }
        let b = Array(before.utf16)
        let c = char.utf16.first!
        var runBefore = 0
        while runBefore < b.count && b[b.count - 1 - runBefore] == c { runBefore += 1 }
        let total = runBefore + 1
        let marker = String(repeating: char, count: total)
        if !CLOSING_MARKERS.contains(marker) { return nil }
        let runStart = b.count - runBefore
        if runStart == 0 { return nil }
        let prev = b[runStart - 1]
        if prev != 0x20 && prev != 0x09 { return nil }
        let beforeSpace = String(utf16CodeUnits: Array(b[0..<(runStart - 1)]), count: runStart - 1)
        if CMText.trim(beforeSpace).isEmpty { return nil }
        let e = char == "*" ? "\\*" : char == "`" ? "`" : "~"
        let opener = JSRegex("(?:^|[^\(e)])\(e){\(total)}(?!\(e))\\S")
        if !opener.test(beforeSpace) { return nil }
        let start = runStart - 1
        return (start, b.count, marker + " ", start + marker.utf16.count + 1)
    }

    static let closeMarkerAfterSpace: InputHandler = { t, from, to, text in
        if from != to || text.utf16.count != 1 { return false }
        if t.state.selection.ranges.count != 1 { return false }
        let line = t.state.doc.lineAt(from)
        let before = t.state.sliceDoc(line.from, from)
        guard let edit = closeMarkerAfterSpaceEdit(before, text) else { return false }
        t.dispatch(TransactionSpec(changes: [Change(from: line.from + edit.from, to: line.from + edit.to, insert: edit.insert)],
                                   selection: .single(line.from + edit.caret), userEvent: "input.type"))
        return true
    }

    /// Prec.high input handlers in facet order.
    static let inputHandlers: [InputHandler] = [strikeOnTilde, closeMarkerAfterSpace, spaceOutsideEmphasis]

    // MARK: link

    public static let insertLink: Command = { t in
        let state = t.state
        var anyChange = false
        let spec = state.changeByRange { range in
            if findEnclosingNode(state, range.from, "Link") != nil { return ([], range) }
            anyChange = true
            if range.from == range.to {
                return ([Change(from: range.from, insert: "[](url)")], SelectionRange.range(range.from + 3, range.from + 6))
            }
            let selected = state.sliceDoc(range.from, range.to)
            let urlStart = range.from + 1 + selected.utf16.count + 2
            return ([Change(from: range.from, to: range.to, insert: "[\(selected)](url)")],
                    SelectionRange.range(urlStart, urlStart + 3))
        }
        if !anyChange || spec.changeSet!.isEmpty { return false }
        var s = spec
        s.userEvent = "input.format.link"
        t.dispatch(s)
        return true
    }

    // MARK: block prefixes

    static func lineCommand(_ userEvent: String, _ transform: @escaping (_ line: String, _ idx: Int, _ all: [String]) -> String) -> Command {
        return { t in
            let state = t.state
            var spec = state.changeByRange { range in
                let fromLine = state.doc.lineAt(range.from)
                let toLine = state.doc.lineAt(range.to)
                var lines: [String] = []
                for i in fromLine.number...toLine.number { lines.append(state.doc.line(i).text) }
                let transformed = lines.enumerated().map { transform($0.element, $0.offset, lines) }
                let insert = transformed.joined(separator: "\n")
                let newFrom = fromLine.from
                let newTo = fromLine.from + insert.utf16.count
                return ([Change(from: fromLine.from, to: toLine.to, insert: insert)],
                        SelectionRange.range(min(newFrom, newFrom + insert.utf16.count), newTo))
            }
            spec.userEvent = userEvent
            t.dispatch(spec)
            return true
        }
    }

    static let HEADING_RE = JSRegex("^(#{1,6})\\s")
    static let BULLET_RE = JSRegex("^- ")
    static let NUMBERED_RE = JSRegex("^\\d+\\.\\s")
    static let BLOCKQUOTE_RE = JSRegex("^> ")
    static let TASK_RE = JSRegex("^- \\[[ x]\\] ")

    static func replaceFirst(_ re: JSRegex, _ line: String) -> String {
        guard let m = re.exec(line) else { return line }
        let u = Array(line.utf16)
        let rest = Array(u[(m.index + m.length)...])
        let head = Array(u[0..<m.index])
        return String(utf16CodeUnits: head + rest, count: head.count + rest.count)
    }

    public static func setHeading(_ level: Int) -> Command {
        let prefix = String(repeating: "#", count: level) + " "
        return lineCommand("input.format.heading\(level)") { line, _, _ in
            if let m = HEADING_RE.exec(line) { return prefix + CMText.utf16Slice(line, m.length) }
            return prefix + line
        }
    }

    public static let setParagraph = lineCommand("input.format.paragraph") { line, _, _ in
        if let m = HEADING_RE.exec(line) { return CMText.utf16Slice(line, m.length) }
        return line
    }

    /// Cmd-Shift-8 / Cmd-Shift-7: any list or plain line (checkbox, bullet, numbered) becomes a
    /// bullet / numbered item, keeping its indent; when every line already is one, the prefix goes.
    public static let toggleBulletList = convertList(numbered: false, "input.format.bulletList")
    public static let toggleNumberedList = convertList(numbered: true, "input.format.numberedList")

    public static let toggleBlockquote = lineCommand("input.format.blockquote") { line, _, all in
        if all.allSatisfy({ BLOCKQUOTE_RE.test($0) }) { return replaceFirst(BLOCKQUOTE_RE, line) }
        if BLOCKQUOTE_RE.test(line) { return line }
        return "> " + line
    }

    public static let toggleTaskList = lineCommand("input.format.taskList") { line, _, all in
        if all.allSatisfy({ TASK_RE.test($0) }) { return replaceFirst(TASK_RE, line) }
        if TASK_RE.test(line) { return line }
        return "- [ ] " + line
    }

    // MARK: checkboxes (Cmd-Shift-9 / Cmd-.)

    /// Any list/plain line → `- [ ] ` (bullets and numbered items keep their indent and text);
    /// when every selected line is already a task, they go back to plain bullets.
    static let LIST_PREFIX_RE = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*] \[[ xX]\] |[-+*] |\d{1,9}[.)] )?"#)
    static let TASK_LINE_RE = try! NSRegularExpression(pattern: #"^[ \t]*[-+*] \[([ xX])\] "#)

    static func selectedLines(_ state: EditorState) -> [Line] {
        var seen = Set<Int>(), out: [Line] = []
        for r in state.selection.ranges {
            let a = state.doc.lineAt(r.from).number, b = state.doc.lineAt(r.empty ? r.to : max(r.from, r.to - 1)).number
            for n in a...b where seen.insert(n).inserted { out.append(state.doc.line(n)) }
        }
        return out.sorted { $0.number < $1.number }
    }

    static let BULLET_LINE_RE = try! NSRegularExpression(pattern: #"^[ \t]*[-+*] (?!\[[ xX]\] )"#)
    static let NUMBERED_LINE_RE = try! NSRegularExpression(pattern: #"^[ \t]*\d{1,9}[.)] "#)

    static func matches(_ re: NSRegularExpression, _ l: Line) -> Bool {
        re.firstMatch(in: l.text, range: NSRange(location: 0, length: (l.text as NSString).length)) != nil
    }

    /// Replace each selected line's list prefix (after its indent) with `prefix(i)`.
    static func replaceListPrefixes(_ t: CommandTarget, _ lines: [Line], userEvent: String, _ prefix: (Int) -> String) {
        let state = t.state
        var changes: [Change] = []
        for (i, l) in lines.enumerated() {
            let ns = l.text as NSString
            guard let m = LIST_PREFIX_RE.firstMatch(in: l.text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let from = l.from + m.range(at: 1).length, to = l.from + m.range.length
            let insert = prefix(i)
            if state.doc.slice(from, to) != insert { changes.append(Change(from: from, to: to, insert: insert)) }
        }
        if changes.isEmpty { return }
        let cs = state.changes(changes)
        let sel = EditorSelection(ranges: state.selection.ranges.map { SelectionRange.range(cs.mapPos($0.anchor, assoc: 1), cs.mapPos($0.head, assoc: 1)) },
                                  mainIndex: state.selection.mainIndex)
        t.dispatch(TransactionSpec(changes: changes, selection: sel, userEvent: userEvent))
    }

    /// Keeps the caret where it was (mapped through the prefix change): selecting the whole line, as the
    /// web app did, made the next keystroke replace the line, bullet included.
    static func convertList(numbered: Bool, _ userEvent: String) -> Command {
        return { t in
            let lines = selectedLines(t.state)
            let kind = numbered ? NUMBERED_LINE_RE : BULLET_LINE_RE
            let already = lines.allSatisfy { matches(kind, $0) }
            replaceListPrefixes(t, lines, userEvent: userEvent) { i in already ? "" : numbered ? "\(i + 1). " : "- " }
            return true
        }
    }

    public static let toggleCheckboxList: Command = { t in
        let lines = selectedLines(t.state)
        let allTasks = lines.allSatisfy { matches(TASK_LINE_RE, $0) }
        replaceListPrefixes(t, lines, userEvent: "input.format.taskList") { _ in allTasks ? "- " : "- [ ] " }
        return true
    }

    /// Check (or, when all are checked, uncheck) the task items on the selected lines.
    public static let toggleTaskDone: Command = { t in
        let state = t.state
        var boxes: [(pos: Int, checked: Bool)] = []
        for l in selectedLines(state) {
            let ns = l.text as NSString
            guard let m = TASK_LINE_RE.firstMatch(in: l.text, range: NSRange(location: 0, length: ns.length)) else { continue }
            boxes.append((l.from + m.range(at: 1).location, ns.substring(with: m.range(at: 1)).lowercased() == "x"))
        }
        if boxes.isEmpty { return false }
        let check = !boxes.allSatisfy(\.checked)
        let changes = boxes.filter { $0.checked != check }.map { Change(from: $0.pos, to: $0.pos + 1, insert: check ? "x" : " ") }
        t.dispatch(TransactionSpec(changes: changes, selection: state.selection, userEvent: "input.toggle-checkbox"))
        return true
    }

    // MARK: clear formatting / code block / inserts

    static func regexReplaceAll(_ text: String, _ pattern: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
    }

    public static let clearInlineFormatting: Command = { t in
        let state = t.state
        var spec = state.changeByRange { range in
            if range.from == range.to { return ([], range) }
            var text = state.sliceDoc(range.from, range.to)
            text = regexReplaceAll(text, "\\*\\*(.+?)\\*\\*")
            text = regexReplaceAll(text, "\\*(.+?)\\*")
            text = regexReplaceAll(text, "~~(.+?)~~")
            text = regexReplaceAll(text, "`(.+?)`")
            return ([Change(from: range.from, to: range.to, insert: text)],
                    SelectionRange.range(range.from, range.from + text.utf16.count))
        }
        if spec.changeSet!.isEmpty { return false }
        spec.userEvent = "input.format.clearFormatting"
        t.dispatch(spec)
        return true
    }

    public static let toggleFencedCodeBlock: Command = { t in
        let state = t.state
        let fromLine = state.doc.lineAt(state.selection.main.from)
        let toLine = state.doc.lineAt(state.selection.main.to)
        let text = state.sliceDoc(fromLine.from, toLine.to)
        let lines = text.components(separatedBy: "\n")
        if CMText.trimEnd(lines[0]).hasPrefix("```") && CMText.trimEnd(lines[lines.count - 1]) == "```" {
            let inner = lines.count >= 2 ? lines[1..<(lines.count - 1)].joined(separator: "\n") : ""
            t.dispatch(TransactionSpec(changes: [Change(from: fromLine.from, to: toLine.to, insert: inner)],
                                       userEvent: "input.format.codeBlock"))
            return true
        }
        t.dispatch(TransactionSpec(changes: [Change(from: fromLine.from, to: toLine.to, insert: "```\n" + text + "\n```")],
                                   userEvent: "input.format.codeBlock"))
        return true
    }

    public static let insertTable: Command = { t in
        let pos = t.state.selection.main.head
        let table = "| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n|  |  |  |"
        let caretOffset = (table as NSString).range(of: "|  |  |  |", options: .backwards).location + 2
        t.dispatch(TransactionSpec(changes: [Change(from: pos, insert: table)], selection: .single(pos + caretOffset),
                                   userEvent: "input.format.table"))
        return true
    }

    public static let insertHorizontalRule: Command = { t in
        let pos = t.state.selection.main.head
        let line = t.state.doc.lineAt(pos)
        let prefix = CMText.trim(line.text).isEmpty ? "" : "\n"
        t.dispatch(TransactionSpec(changes: [Change(from: pos, insert: prefix + "---\n")], userEvent: "input.format.horizontalRule"))
        return true
    }

    public static let insertToday: Command = { t in
        let c = t.env.calendar.dateComponents([.year, .month, .day], from: t.env.now)
        let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        t.dispatch(TransactionSpec(changes: [Change(from: t.state.selection.main.head, insert: date)], userEvent: "input.format.today"))
        return true
    }

    public static let insertNow: Command = { t in
        let c = t.env.calendar.dateComponents([.hour, .minute], from: t.env.now)
        let time = String(format: "%02d:%02d", c.hour!, c.minute!)
        t.dispatch(TransactionSpec(changes: [Change(from: t.state.selection.main.head, insert: time)], userEvent: "input.format.now"))
        return true
    }

    // MARK: prosemark's own formatting keymap (markdownFormattingKeymap.ts)

    static func findOutermostCoveringNode(_ state: EditorState, _ from: Int, _ to: Int, _ name: String) -> SyntaxNode? {
        var found: SyntaxNode? = nil
        if from > to { return nil }
        for pos in from...to {
            var node: SyntaxNode? = Lezer.resolveInner(state.tree, pos, 1)
            while let n = node {
                if n.to < from || n.from > to { break }
                if n.name == name {
                    if found == nil || n.from < found!.from || n.to > found!.to { found = n }
                }
                node = n.parent
            }
        }
        return found
    }

    static func toggleInlineMarkup(_ state: EditorState, _ range: SelectionRange, _ nodeName: String,
                                   _ open: String, _ close: String) -> (changes: [Change], range: SelectionRange)? {
        if !isMarkdownContext(state, range.from) { return nil }
        let from = range.from, to = range.to
        if let covering = findOutermostCoveringNode(state, from, to, nodeName), covering.from <= from, covering.to >= to {
            let innerFrom = covering.from + open.utf16.count
            let innerTo = covering.to - close.utf16.count
            if innerFrom > innerTo { return nil }
            return ([Change(from: covering.from, to: covering.to, insert: state.sliceDoc(innerFrom, innerTo))],
                    SelectionRange.range(covering.from, covering.from + innerTo - innerFrom))
        }
        let text = state.sliceDoc(from, to)
        return ([Change(from: from, to: to, insert: open + text + close)],
                SelectionRange.range(from + open.utf16.count, from + open.utf16.count + text.utf16.count))
    }

    static func isMarkdownContext(_ state: EditorState, _ pos: Int) -> Bool {
        state.markdownActiveAt(pos, -1) || state.markdownActiveAt(pos, 1)
    }

    static func makeToggleInlineCommand(_ nodeName: String, _ open: String, _ close: String) -> Command {
        return { t in
            let state = t.state
            var specs: [(changes: [Change], range: SelectionRange)] = []
            for r in state.selection.ranges {
                if !isMarkdownContext(state, r.from) { return false }
                guard let s = toggleInlineMarkup(state, r, nodeName, open, close) else { return false }
                specs.append(s)
            }
            var i = 0
            var spec = state.changeByRange { _ in defer { i += 1 }; return specs[i] }
            spec.userEvent = "input"
            t.dispatch(spec)
            return true
        }
    }

    static let pmToggleStrongEmphasis = makeToggleInlineCommand("StrongEmphasis", "**", "**")
    static let pmToggleEmphasis = makeToggleInlineCommand("Emphasis", "_", "_")
    static let pmToggleStrikethrough = makeToggleInlineCommand("Strikethrough", "~~", "~~")
    static let pmInsertLink: Command = { t in
        let state = t.state
        for r in state.selection.ranges where !isMarkdownContext(state, r.from) { return false }
        var spec = state.changeByRange { range in
            let label = state.sliceDoc(range.from, range.to)
            let insert = range.empty ? "[]()" : "[\(label)]()"
            let head = range.empty ? range.from + 1 : range.from + 1 + label.utf16.count + 2
            return ([Change(from: range.from, to: range.to, insert: insert)], SelectionRange.cursor(head))
        }
        spec.userEvent = "input"
        t.dispatch(spec)
        return true
    }
}

import Foundation

// Port of src/lib/prosemark-core/list/index.ts: list Enter / Backspace /
// Mod-Backspace / Tab / Shift-Tab, prefix arrow keys, atomic ranges, and the
// checkbox toggle.

enum ListCommands {
    static let LIST_INDENT_SPACES = 2
    static let PREV_LIST_LOOKBACK = 256

    static func isBulletMarkChar(_ s: String) -> Bool { s == "-" || s == "+" || s == "*" }
    static func isMarkerTrailingChar(_ s: String) -> Bool { s == " " || s == "\t" }
    static let ORDERED_MARKER_RE = JSRegex("^\\d+[.)]$")

    // MARK: Atomic ranges (buildListDecorations → atomic)

    static func atomicRanges(_ state: EditorState) -> [(from: Int, to: Int)] {
        var atoms: [(Int, Int)] = []
        state.tree.iterate(enter: { node, _ in
            if node.name != "ListMark" { return true }
            if !isMarkerTrailingChar(state.sliceDoc(node.to, node.to + 1)) { return true }
            let markText = state.sliceDoc(node.from, node.to)
            if ORDERED_MARKER_RE.test(markText) { return true }
            if markText.utf16.count != 1 || !isBulletMarkChar(markText) { return true }
            var depth = -1
            var p = node.parent
            while let pp = p { if pp.name == "ListItem" { depth += 1 }; p = pp.parent }
            if depth < 0 { depth = 0 }
            let line = state.doc.lineAt(node.from)
            let leadingFrom = line.from, leadingTo = node.from
            let leadingLen = leadingTo - leadingFrom
            if depth >= 1 && leadingLen >= depth {
                let step = leadingLen / depth
                for i in 0..<depth {
                    let subFrom = leadingFrom + i * step
                    let subTo = i == depth - 1 ? leadingTo : leadingFrom + (i + 1) * step
                    if subTo <= subFrom { break }
                    atoms.append((subFrom, subTo))
                }
            }
            var prefixEnd = -1
            if let sib = node.cmNextSibling, sib.name == "Task",
               let tm = sib.cmFirstChild, tm.name == "TaskMarker",
               isMarkerTrailingChar(state.sliceDoc(tm.to, tm.to + 1)) {
                prefixEnd = tm.to + 1
            }
            if prefixEnd < 0 { prefixEnd = node.to + 1 }
            atoms.append((node.from, prefixEnd))
            return true
        })
        // Decoration.set(ranges, true) sorts by from (then startSide).
        return atoms.enumerated().sorted { a, b in
            a.element.0 < b.element.0 || (a.element.0 == b.element.0 && a.offset < b.offset)
        }.map { (from: $0.element.0, to: $0.element.1) }
    }

    // MARK: helpers

    static let PREV_ITEM_RE = JSRegex("^([ \\t]*)[-+*] ")
    static let LIST_PARENT_RE = JSRegex("^([ \\t]*)([-+*])([ \\t]+)")

    static func findPrevListItemIndent(_ state: EditorState, _ lineNumber: Int, _ predicate: (Int) -> Bool) -> Int {
        let stop = max(1, lineNumber - PREV_LIST_LOOKBACK)
        var i = lineNumber - 1
        while i >= stop {
            let text = state.doc.line(i).text
            if CMText.trim(text).isEmpty { return -1 }
            if let m = PREV_ITEM_RE.exec(text), predicate(m.len(1)) { return m.len(1) }
            i -= 1
        }
        return -1
    }

    static func findPrevListItemContentCol(_ state: EditorState, _ lineNumber: Int, _ predicate: (Int) -> Bool) -> Int {
        let stop = max(1, lineNumber - PREV_LIST_LOOKBACK)
        var i = lineNumber - 1
        while i >= stop {
            let text = state.doc.line(i).text
            if CMText.trim(text).isEmpty { return -1 }
            if let m = LIST_PARENT_RE.exec(text), predicate(m.len(1)) {
                return m.len(1) + m.len(2) + m.len(3)
            }
            i -= 1
        }
        return -1
    }

    static func currentLineIndentLen(_ text: String) -> Int { CMText.leadingSpaceTab(text) }

    static func isOnListLine(_ state: EditorState, _ pos: Int) -> Bool {
        let line = state.doc.lineAt(pos)
        var found = false
        state.tree.iterate(from: line.from, to: line.to, enter: { node, _ in
            if found { return false }
            if node.name == "ListMark" || node.name == "TaskMarker" { found = true; return false }
            return true
        })
        return found
    }

    static func selectedLineNumbers(_ state: EditorState) -> [Int] {
        var numbers = Set<Int>()
        for r in state.selection.ranges {
            let fromLine = state.doc.lineAt(r.from)
            let endPos = r.empty ? r.to : max(r.from, r.to - 1)
            let toLine = state.doc.lineAt(endPos)
            for l in fromLine.number...toLine.number { numbers.insert(l) }
        }
        return numbers.sorted()
    }

    // MARK: commands

    static func listIndentSelection(_ t: CommandTarget) -> Bool {
        let state = t.state
        var changes: [Change] = []
        var sawListLine = false
        for n in selectedLineNumbers(state) {
            let line = state.doc.line(n)
            guard let parsed = ListLines.parseBulletTaskLine(line) else { continue }
            sawListLine = true
            let target = findPrevListItemContentCol(state, line.number) { $0 <= parsed.indentLen }
            if target < 0 { continue }
            if parsed.indentLen >= target { continue }
            changes.append(Change(from: line.from, insert: String(repeating: " ", count: target - parsed.indentLen)))
        }
        if !sawListLine { return false }
        if !changes.isEmpty { t.dispatch(TransactionSpec(changes: changes, userEvent: "input.indent")) }
        return true
    }

    static func listOutdentSelection(_ t: CommandTarget) -> Bool {
        let state = t.state
        var changes: [Change] = []
        var sawListLine = false
        for n in selectedLineNumbers(state) {
            let line = state.doc.line(n)
            guard let parsed = ListLines.parseBulletTaskLine(line) else { continue }
            sawListLine = true
            if parsed.indentLen == 0 { continue }
            let removeLen = min(LIST_INDENT_SPACES, parsed.indentLen)
            changes.append(Change(from: line.from, to: line.from + removeLen))
        }
        if !sawListLine { return false }
        if !changes.isEmpty { t.dispatch(TransactionSpec(changes: changes, userEvent: "delete.outdent")) }
        return true
    }

    static func listPrefixBoundaryMove(_ state: EditorState, left: Bool) -> Int? {
        let sel = state.selection.main
        if !sel.empty { return nil }
        guard let p = ListLines.parseBulletTaskLineAt(state, sel.head) else { return nil }
        if left {
            if sel.head == p.bodyFrom { return p.markerFrom }
            if p.markerFrom > p.lineFrom && sel.head == p.markerFrom { return p.lineFrom }
        } else {
            if sel.head == p.lineFrom { return p.markerFrom > p.lineFrom ? p.markerFrom : p.bodyFrom }
            if p.markerFrom > p.lineFrom && sel.head == p.markerFrom { return p.bodyFrom }
        }
        return nil
    }

    static func arrow(left: Bool, extend: Bool) -> Command {
        return { t in
            guard let pos = listPrefixBoundaryMove(t.state, left: left) else { return false }
            if extend {
                let sel = t.state.selection.main
                t.dispatch(TransactionSpec(selection: EditorSelection(ranges: [SelectionRange.range(sel.anchor, pos)]),
                                           userEvent: "select.extend"))
            } else {
                t.dispatch(TransactionSpec(selection: .single(pos), userEvent: "select"))
            }
            return true
        }
    }

    static func listIndent(_ t: CommandTarget) -> Bool {
        let state = t.state
        if state.selection.ranges.count != 1 || !state.selection.main.empty { return listIndentSelection(t) }
        let sel = state.selection.main
        if !isOnListLine(state, sel.head) { return false }
        let line = state.doc.lineAt(sel.head)
        let currentIndent = currentLineIndentLen(line.text)
        let target = findPrevListItemContentCol(state, line.number) { $0 <= currentIndent }
        if target < 0 { return true }
        if currentIndent >= target { return true }
        let insertLen = target - currentIndent
        t.dispatch(TransactionSpec(changes: [Change(from: line.from, insert: String(repeating: " ", count: insertLen))],
                                   selection: .single(sel.head + insertLen), userEvent: "input.indent"))
        return true
    }

    static func listOutdent(_ t: CommandTarget) -> Bool {
        let state = t.state
        if state.selection.ranges.count != 1 || !state.selection.main.empty { return listOutdentSelection(t) }
        let sel = state.selection.main
        if !isOnListLine(state, sel.head) { return false }
        let line = state.doc.lineAt(sel.head)
        let currentIndent = currentLineIndentLen(line.text)
        if currentIndent == 0 { return true }
        let prevIndent = findPrevListItemIndent(state, line.number) { $0 < currentIndent }
        let targetIndent = max(0, prevIndent)
        let removeLen = currentIndent - targetIndent
        if removeLen <= 0 { return true }
        let offset = sel.head - line.from
        let newHead = line.from + max(targetIndent, offset - removeLen)
        t.dispatch(TransactionSpec(changes: [Change(from: line.from, to: line.from + removeLen)],
                                   selection: .single(newHead), userEvent: "delete.outdent"))
        return true
    }

    static let EMPTY_LIST_LINE_RE = JSRegex("^[ \\t]*[-+*] (\\[.\\] )?$")
    static let LIST_LINE_PREFIX_RE = JSRegex("^([ \\t]*)([-+*]) (\\[.\\] )?")
    static let LIST_CONTENT_START_RE = JSRegex("^([ \\t]*)(?:[-+*]|\\d+[.)])[ \\t]+(?:\\[[ xX]\\][ \\t]+)?")

    static func listDeleteToContentStart(_ t: CommandTarget) -> Bool {
        let state = t.state
        if state.selection.ranges.count != 1 { return false }
        let range = state.selection.main
        if !range.empty { return false }
        let line = state.doc.lineAt(range.head)
        guard let prefix = LIST_CONTENT_START_RE.exec(line.text) else { return false }
        let contentStart = line.from + prefix.length
        if range.head <= contentStart { return false }
        t.dispatch(TransactionSpec(changes: [Change(from: contentStart, to: range.head)],
                                   selection: .single(contentStart), userEvent: "delete.backward"))
        return true
    }

    static func listEnter(_ t: CommandTarget) -> Bool {
        let state = t.state
        if state.selection.ranges.count != 1 || !state.selection.main.empty { return false }
        let sel = state.selection.main
        if !isOnListLine(state, sel.head) { return false }
        let line = state.doc.lineAt(sel.head)
        if EMPTY_LIST_LINE_RE.test(line.text) {
            t.dispatch(TransactionSpec(changes: [Change(from: line.from, to: line.to)], selection: .single(line.from),
                                       userEvent: "delete.empty-list-marker"))
            return true
        }
        guard let m = LIST_LINE_PREFIX_RE.exec(line.text) else { return false }
        let indent = m[1] ?? ""
        let marker = m[2] ?? "-"
        let isTask = m[3] != nil
        let offset = sel.head - line.from
        if offset < m.length { return false }
        let continuation = isTask ? "\(indent)\(marker) [ ] " : "\(indent)\(marker) "
        t.dispatch(TransactionSpec(changes: [Change(from: sel.head, insert: "\n" + continuation)],
                                   selection: .single(sel.head + 1 + continuation.utf16.count),
                                   userEvent: "input.list-continue"))
        return true
    }

    static func listBackspace(_ t: CommandTarget) -> Bool {
        let state = t.state
        if state.selection.ranges.count != 1 { return false }
        let range = state.selection.main
        if !range.empty { return false }
        let head = range.head
        guard let p = ListLines.parseBulletTaskLineAt(state, head) else { return false }
        var eff = head
        if head > p.lineFrom && head < p.markerFrom { eff = p.markerFrom }
        else if head > p.markerFrom && head < p.bodyFrom { eff = p.bodyFrom }
        if eff == p.lineFrom { return false }
        if eff == p.markerFrom {
            if p.indentLen == 0 { return false }
            let from = p.markerFrom - min(LIST_INDENT_SPACES, p.indentLen)
            t.dispatch(TransactionSpec(changes: [Change(from: from, to: p.markerFrom)], selection: .single(from),
                                       userEvent: "delete.list"))
            return true
        }
        if eff == p.bodyFrom {
            let from = p.indentLen > 0 ? p.markerFrom - min(LIST_INDENT_SPACES, p.indentLen) : p.markerFrom
            t.dispatch(TransactionSpec(changes: [Change(from: from, to: p.bodyFrom)], selection: .single(from),
                                       userEvent: "delete.list"))
            return true
        }
        return false
    }

    // MARK: checkbox

    static let CHECKBOX_RE = JSRegex("^[-+*] \\[([ xX])\\][ \\t]")
    static let CHECKBOX_LINE_RE = JSRegex("^([ \\t]*)[-+*] \\[[ xX]\\][ \\t]")

    /// `computeCheckboxToggle(state, widgetStartPos)`.
    public static func computeCheckboxToggle(_ state: EditorState, _ widgetStartPos: Int) -> TransactionSpec? {
        let slice = state.sliceDoc(widgetStartPos, widgetStartPos + 8)
        guard let m = CHECKBOX_RE.exec(slice) else { return nil }
        let inner = widgetStartPos + 3
        let checked = (m[1] ?? "").lowercased() == "x"
        return TransactionSpec(changes: [Change(from: inner, to: inner + 1, insert: checked ? " " : "x")],
                               userEvent: "input.toggle-checkbox")
    }

    /// Click on a task prefix at `pos` (any position on the line).
    public static func checkboxToggle(_ state: EditorState, at pos: Int) -> TransactionSpec? {
        let line = state.doc.lineAt(pos)
        if let m = CHECKBOX_LINE_RE.exec(line.text) {
            return computeCheckboxToggle(state, line.from + m.len(1))
        }
        return computeCheckboxToggle(state, pos)
    }
}

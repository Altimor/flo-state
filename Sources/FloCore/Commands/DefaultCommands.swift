import Foundation

// Ports of the @codemirror/commands 6.10 commands the web app's keymap
// reaches (defaultKeymap, historyKeymap, indentWithTab), @codemirror/view's
// moveByChar/moveByGroup/skipAtoms, and @codemirror/search selectNextOccurrence.

enum CM {
    // MARK: view-level motion

    /// `skipAtomicRanges(atoms, pos, bias)`.
    static func skipAtomicRanges(_ atoms: [(from: Int, to: Int)], _ pos0: Int, _ bias: Int) -> Int {
        var pos = pos0
        while true {
            var moved = 0
            for a in atoms where a.to >= pos - 1 && a.from <= pos + 1 {
                if pos > a.from && pos < a.to {
                    let side = moved != 0 ? moved : bias != 0 ? bias : (pos - a.from < a.to - pos ? -1 : 1)
                    pos = side < 0 ? a.from : a.to
                    moved = side
                }
            }
            if moved == 0 { return pos }
        }
    }

    static func skipAtoms(_ state: EditorState, _ oldPos: SelectionRange, _ pos: SelectionRange) -> SelectionRange {
        let newPos = skipAtomicRanges(ListCommands.atomicRanges(state), pos.from, oldPos.head > pos.from ? -1 : 1)
        return newPos == pos.from ? pos : SelectionRange.cursor(newPos, assoc: newPos < pos.from ? 1 : -1)
    }

    /// `moveByChar(view, start, forward, by)` for LTR text (no bidi).
    static func moveByCharRaw(_ state: EditorState, _ start: SelectionRange, _ forward: Bool,
                              _ by: ((String) -> (String) -> Bool)? = nil) -> SelectionRange {
        var line = state.doc.lineAt(start.head)
        var check: ((String) -> Bool)? = nil
        var cur = start
        while true {
            var next: SelectionRange
            var char: String
            let units = Array(line.text.utf16)
            let idx = cur.head - line.from
            if forward ? idx >= units.count : idx <= 0 {
                if line.number == (forward ? state.doc.lines : 1) { return cur }
                char = "\n"
                line = state.doc.line(line.number + (forward ? 1 : -1))
                next = SelectionRange.cursor(forward ? line.from : line.to, assoc: forward ? 1 : -1)
            } else {
                let ni = CMText.findClusterBreak(units, idx, forward: forward)
                char = String(utf16CodeUnits: Array(units[min(idx, ni)..<max(idx, ni)]), count: abs(ni - idx))
                next = SelectionRange.cursor(ni + line.from, assoc: forward ? -1 : 1)
            }
            if check == nil {
                guard let by = by else { return next }
                check = by(char)
            } else if !check!(char) {
                return cur
            }
            cur = next
        }
    }

    static func moveByChar(_ state: EditorState, _ start: SelectionRange, _ forward: Bool) -> SelectionRange {
        skipAtoms(state, start, moveByCharRaw(state, start, forward))
    }

    static func byGroup(_ state: EditorState) -> (String) -> (String) -> Bool {
        return { start in
            var cat = CMText.categorize(start)
            return { next in
                let nextCat = CMText.categorize(next)
                if cat == .space { cat = nextCat }
                return cat == nextCat
            }
        }
    }

    static func moveByGroup(_ state: EditorState, _ start: SelectionRange, _ forward: Bool) -> SelectionRange {
        skipAtoms(state, start, moveByCharRaw(state, start, forward, byGroup(state)))
    }

    // MARK: selection helpers

    static func updateSel(_ sel: EditorSelection, _ by: (SelectionRange) -> SelectionRange) -> EditorSelection {
        EditorSelection.create(sel.ranges.map(by), mainIndex: sel.mainIndex)
    }

    static func setSel(_ t: CommandTarget, _ selection: EditorSelection) {
        t.dispatch(TransactionSpec(selection: selection, userEvent: "select"))
    }

    static func moveSel(_ t: CommandTarget, _ how: (SelectionRange) -> SelectionRange) -> Bool {
        let selection = updateSel(t.state.selection, how)
        if selection.eq(t.state.selection, includeAssoc: true) { return false }
        setSel(t, selection)
        return true
    }

    static func rangeEnd(_ r: SelectionRange, _ forward: Bool) -> SelectionRange {
        SelectionRange.cursor(forward ? r.to : r.from)
    }

    static func extendSel(_ t: CommandTarget, _ how: (SelectionRange) -> SelectionRange) -> Bool {
        let selection = updateSel(t.state.selection) { range in
            let head = how(range)
            return SelectionRange.range(range.anchor, head.head, goalColumn: head.goalColumn, assoc: head.assoc)
        }
        if selection.eq(t.state.selection) { return false }
        setSel(t, selection)
        return true
    }

    // MARK: cursor commands

    static let cursorCharLeft: Command = { t in moveSel(t) { $0.empty ? moveByChar(t.state, $0, false) : rangeEnd($0, false) } }
    static let cursorCharRight: Command = { t in moveSel(t) { $0.empty ? moveByChar(t.state, $0, true) : rangeEnd($0, true) } }
    static let selectCharLeft: Command = { t in extendSel(t) { moveByChar(t.state, $0, false) } }
    static let selectCharRight: Command = { t in extendSel(t) { moveByChar(t.state, $0, true) } }
    static let cursorGroupLeft: Command = { t in moveSel(t) { $0.empty ? moveByGroup(t.state, $0, false) : rangeEnd($0, false) } }
    static let cursorGroupRight: Command = { t in moveSel(t) { $0.empty ? moveByGroup(t.state, $0, true) : rangeEnd($0, true) } }
    static let selectGroupLeft: Command = { t in extendSel(t) { moveByGroup(t.state, $0, false) } }
    static let selectGroupRight: Command = { t in extendSel(t) { moveByGroup(t.state, $0, true) } }

    static func moveByLineBoundary(_ t: CommandTarget, _ start: SelectionRange, _ forward: Bool) -> SelectionRange {
        let state = t.state, layout = t.env.layout
        let block = layout.lineBlockAt(state, start.head)
        var moved = layout.moveToLineBoundary(state, start, forward: forward, includeWrap: true)
        if moved.head == start.head && moved.head != (forward ? block.to : block.from) {
            moved = layout.moveToLineBoundary(state, start, forward: forward, includeWrap: false)
        }
        if !forward && moved.head == block.from && block.to > block.from {
            let text = state.sliceDoc(block.from, min(block.from + 100, block.to))
            let space = CMText.leadingWhitespace(text)
            if space > 0 && start.head != block.from + space {
                moved = SelectionRange.cursor(block.from + space)
            }
        }
        return moved
    }

    static let cursorLineBoundaryForward: Command = { t in moveSel(t) { moveByLineBoundary(t, $0, true) } }
    static let cursorLineBoundaryBackward: Command = { t in moveSel(t) { moveByLineBoundary(t, $0, false) } }
    static let selectLineBoundaryForward: Command = { t in extendSel(t) { moveByLineBoundary(t, $0, true) } }
    static let selectLineBoundaryBackward: Command = { t in extendSel(t) { moveByLineBoundary(t, $0, false) } }

    static func cursorByLine(_ t: CommandTarget, _ forward: Bool) -> Bool {
        moveSel(t) { r in
            if !r.empty { return rangeEnd(r, forward) }
            return t.env.layout.moveVertically(t.state, r, forward: forward)
        }
    }
    static let cursorLineUp: Command = { t in cursorByLine(t, false) }
    static let cursorLineDown: Command = { t in cursorByLine(t, true) }
    static let selectLineUp: Command = { t in extendSel(t) { t.env.layout.moveVertically(t.state, $0, forward: false) } }
    static let selectLineDown: Command = { t in extendSel(t) { t.env.layout.moveVertically(t.state, $0, forward: true) } }

    static let cursorDocStart: Command = { t in setSel(t, .single(0)); return true }
    static let cursorDocEnd: Command = { t in setSel(t, .single(t.state.doc.length)); return true }
    static let selectDocStart: Command = { t in setSel(t, .single(t.state.selection.main.anchor, 0)); return true }
    static let selectDocEnd: Command = { t in setSel(t, .single(t.state.selection.main.anchor, t.state.doc.length)); return true }
    static let selectAll: Command = { t in
        t.dispatch(TransactionSpec(selection: .single(0, t.state.doc.length), userEvent: "select"))
        return true
    }

    static let simplifySelection: Command = { t in
        let cur = t.state.selection
        var selection: EditorSelection? = nil
        if cur.ranges.count > 1 { selection = EditorSelection(ranges: [cur.main]) }
        else if !cur.main.empty { selection = EditorSelection(ranges: [SelectionRange.cursor(cur.main.head)]) }
        guard let s = selection else { return false }
        setSel(t, s)
        return true
    }

    // MARK: deletion

    static func skipAtomic(_ state: EditorState, _ pos0: Int, _ forward: Bool) -> Int {
        var pos = pos0
        for a in ListCommands.atomicRanges(state) where a.to >= pos && a.from <= pos {
            if a.from < pos && a.to > pos { pos = forward ? a.to : a.from }
        }
        return pos
    }

    static func deleteBy(_ t: CommandTarget, _ by: (SelectionRange) -> Int) -> Bool {
        let state = t.state
        var event = "delete.selection"
        var spec = state.changeByRange { range in
            var from = range.from, to = range.to
            if from == to {
                var towards = by(range)
                if towards < from {
                    event = "delete.backward"
                    towards = skipAtomic(state, towards, false)
                } else if towards > from {
                    event = "delete.forward"
                    towards = skipAtomic(state, towards, true)
                }
                from = min(from, towards)
                to = max(to, towards)
            } else {
                from = skipAtomic(state, from, false)
                to = skipAtomic(state, to, true)
            }
            if from == to { return ([], range) }
            return ([Change(from: from, to: to)], SelectionRange.cursor(from, assoc: from < range.head ? -1 : 1))
        }
        if spec.changeSet!.isEmpty { return false }
        spec.userEvent = event
        t.dispatch(spec)
        return true
    }

    static func deleteByChar(_ t: CommandTarget, _ forward: Bool, _ byIndentUnit: Bool) -> Bool {
        let state = t.state
        return deleteBy(t) { range in
            var pos = range.from
            let line = state.doc.lineAt(pos)
            let before = CMText.utf16Slice(line.text, 0, pos - line.from)
            var targetPos: Int
            if byIndentUnit && !forward && pos > line.from && pos < line.from + 200 &&
                !before.utf16.contains(where: { $0 != 0x20 && $0 != 0x09 }) {
                let bu = Array(before.utf16)
                if bu.last == 0x09 { return pos - 1 }
                let col = CMText.countColumn(before, tabSize: state.tabSize)
                let drop = col % state.indentUnitWidth == 0 ? state.indentUnitWidth : col % state.indentUnitWidth
                var i = 0
                while i < drop && bu.count - 1 - i >= 0 && bu[bu.count - 1 - i] == 0x20 { pos -= 1; i += 1 }
                targetPos = pos
            } else {
                let units = Array(line.text.utf16)
                targetPos = CMText.findClusterBreak(units, pos - line.from, forward: forward) + line.from
                if targetPos == pos && line.number != (forward ? state.doc.lines : 1) {
                    targetPos += forward ? 1 : -1
                } else if !forward {
                    let seg = units[(targetPos - line.from)..<(pos - line.from)]
                    if seg.contains(where: { $0 >= 0xFE00 && $0 <= 0xFE0F }) {
                        targetPos = CMText.findClusterBreak(units, targetPos - line.from, forward: false) + line.from
                    }
                }
            }
            return targetPos
        }
    }

    static let deleteCharBackward: Command = { t in deleteByChar(t, false, true) }
    static let deleteCharForward: Command = { t in deleteByChar(t, true, false) }

    static func deleteByGroup(_ t: CommandTarget, _ forward: Bool) -> Bool {
        let state = t.state
        return deleteBy(t) { range in
            var pos = range.head
            let line = state.doc.lineAt(pos)
            let units = Array(line.text.utf16)
            var cat: CharCategory? = nil
            while true {
                if pos == (forward ? line.to : line.from) {
                    if pos == range.head && line.number != (forward ? state.doc.lines : 1) { pos += forward ? 1 : -1 }
                    break
                }
                let next = CMText.findClusterBreak(units, pos - line.from, forward: forward) + line.from
                let a = min(pos, next) - line.from, b = max(pos, next) - line.from
                let nextChar = String(utf16CodeUnits: Array(units[a..<b]), count: b - a)
                let nextCat = CMText.categorize(nextChar)
                if let c = cat, nextCat != c { break }
                if nextChar != " " || pos != range.head { cat = nextCat }
                pos = next
            }
            return pos
        }
    }

    static let deleteGroupBackward: Command = { t in deleteByGroup(t, false) }
    static let deleteGroupForward: Command = { t in deleteByGroup(t, true) }

    static let deleteLineBoundaryBackward: Command = { t in
        deleteBy(t) { range in
            let lineStart = t.env.layout.moveToLineBoundary(t.state, range, forward: false, includeWrap: true).head
            return range.head > lineStart ? lineStart : max(0, range.head - 1)
        }
    }
    static let deleteLineBoundaryForward: Command = { t in
        deleteBy(t) { range in
            let lineEnd = t.env.layout.moveToLineBoundary(t.state, range, forward: true, includeWrap: true).head
            return range.head < lineEnd ? lineEnd : min(t.state.doc.length, range.head + 1)
        }
    }

    // MARK: line operations

    struct LineBlock { var from: Int; var to: Int; var ranges: [SelectionRange] }

    static func selectedLineBlocks(_ state: EditorState) -> [LineBlock] {
        var blocks: [LineBlock] = []
        var upto = -1
        for range in state.selection.ranges {
            let startLine = state.doc.lineAt(range.from)
            var endLine = state.doc.lineAt(range.to)
            if !range.empty && range.to == endLine.from { endLine = state.doc.lineAt(range.to - 1) }
            if upto >= startLine.number {
                blocks[blocks.count - 1].to = endLine.to
                blocks[blocks.count - 1].ranges.append(range)
            } else {
                blocks.append(LineBlock(from: startLine.from, to: endLine.to, ranges: [range]))
            }
            upto = endLine.number + 1
        }
        return blocks
    }

    static func moveLine(_ t: CommandTarget, _ forward: Bool) -> Bool {
        let state = t.state
        var changes: [Change] = []
        var ranges: [SelectionRange] = []
        for block in selectedLineBlocks(state) {
            if forward ? block.to == state.doc.length : block.from == 0 { continue }
            let nextLine = state.doc.lineAt(forward ? block.to + 1 : block.from - 1)
            let size = nextLine.length + 1
            if forward {
                changes.append(Change(from: block.to, to: nextLine.to))
                changes.append(Change(from: block.from, insert: nextLine.text + "\n"))
                for r in block.ranges {
                    ranges.append(SelectionRange.range(min(state.doc.length, r.anchor + size), min(state.doc.length, r.head + size)))
                }
            } else {
                changes.append(Change(from: nextLine.from, to: block.from))
                changes.append(Change(from: block.to, insert: "\n" + nextLine.text))
                for r in block.ranges { ranges.append(SelectionRange.range(r.anchor - size, r.head - size)) }
            }
        }
        if changes.isEmpty { return false }
        t.dispatch(TransactionSpec(changes: changes, selection: EditorSelection.create(ranges, mainIndex: state.selection.mainIndex),
                                   userEvent: "move.line"))
        return true
    }

    /// macOS native Option-Up/Down, reached when CM's moveLine binding
    /// returns false (first/last line) and doesn't preventDefault: the
    /// browser moves to the paragraph start/end and CM reads it back as a
    /// "select" transaction.
    static func nativeParagraphMove(_ forward: Bool, extend: Bool) -> Command {
        return { t in
            let state = t.state
            let sel = updateSel(state.selection) { r in
                let line = state.doc.lineAt(r.head)
                var target = forward ? line.to : line.from
                if target == r.head {
                    if forward, line.number < state.doc.lines { target = state.doc.line(line.number + 1).to }
                    if !forward, line.number > 1 { target = state.doc.line(line.number - 1).from }
                }
                return extend ? SelectionRange.range(r.anchor, target) : SelectionRange.cursor(target)
            }
            if sel.eq(state.selection) { return false }
            setSel(t, sel)
            return true
        }
    }

    static let moveLineUp: Command = { t in moveLine(t, false) }
    static let moveLineDown: Command = { t in moveLine(t, true) }

    static func copyLine(_ t: CommandTarget, _ forward: Bool) -> Bool {
        let state = t.state
        var changes: [Change] = []
        for block in selectedLineBlocks(state) {
            if forward {
                changes.append(Change(from: block.from, insert: state.sliceDoc(block.from, block.to) + "\n"))
            } else {
                changes.append(Change(from: block.to, insert: "\n" + state.sliceDoc(block.from, block.to)))
            }
        }
        let cs = state.changes(changes)
        t.dispatch(TransactionSpec(changeSet: cs, selection: state.selection.map(cs, assoc: forward ? 1 : -1),
                                   userEvent: "input.copyline"))
        return true
    }

    static let copyLineUp: Command = { t in copyLine(t, false) }
    static let copyLineDown: Command = { t in copyLine(t, true) }

    static let deleteLine: Command = { t in
        let state = t.state
        let cs = state.changes(selectedLineBlocks(state).map { b in
            var from = b.from, to = b.to
            if from > 0 { from -= 1 } else if to < state.doc.length { to += 1 }
            return Change(from: from, to: to)
        })
        let selection = updateSel(state.selection) { t.env.layout.moveVertically(state, $0, forward: true) }.map(cs)
        t.dispatch(TransactionSpec(changeSet: cs, selection: selection, userEvent: "delete.line"))
        return true
    }

    static func newlineAndIndent(_ atEof: Bool) -> Command {
        return { t in
            let state = t.state
            var spec = state.changeByRange { range in
                var from = range.from, to = range.to
                let line = state.doc.lineAt(from)
                if atEof {
                    let l = to <= line.to ? line : state.doc.lineAt(to)
                    from = l.to; to = l.to
                }
                // getIndentation: markdown's indent service yields null, so CM
                // falls back to the current line's leading whitespace.
                let fromText = state.doc.lineAt(from).text
                let indent = CMText.countColumn(CMText.utf16Slice(fromText, 0, CMText.leadingWhitespace(fromText)),
                                                tabSize: state.tabSize)
                let lt = Array(line.text.utf16)
                while to < line.to && CMText.isJSSpace(lt[to - line.from]) { to += 1 }
                // CM slices `line.text` with the ABSOLUTE `from` here (a CM
                // quirk kept for parity): only lines near the doc start hit it.
                if from > line.from && from < line.from + 100 && !CMText.hasNonSpace(CMText.utf16Slice(line.text, 0, from)) {
                    from = line.from
                }
                let ind = String(repeating: " ", count: indent)
                return ([Change(from: from, to: to, insert: "\n" + ind)], SelectionRange.cursor(from + 1 + ind.utf16.count))
            }
            spec.userEvent = "input"
            t.dispatch(spec)
            return true
        }
    }

    static let insertNewlineAndIndent = newlineAndIndent(false)
    static let insertBlankLine = newlineAndIndent(true)

    static func changeBySelectedLine(_ state: EditorState, _ f: (Line, inout [Change], SelectionRange) -> Void) -> TransactionSpec {
        var atLine = -1
        return state.changeByRange { range in
            var changes: [Change] = []
            var pos = range.from
            while pos <= range.to {
                let line = state.doc.lineAt(pos)
                if line.number > atLine && (range.empty || range.to > line.from) {
                    f(line, &changes, range)
                    atLine = line.number
                }
                pos = line.to + 1
            }
            let cs = state.changes(changes)
            return (changes, SelectionRange.range(cs.mapPos(range.anchor, assoc: 1), cs.mapPos(range.head, assoc: 1)))
        }
    }

    static let indentMore: Command = { t in
        let state = t.state
        var spec = changeBySelectedLine(state) { line, changes, _ in changes.append(Change(from: line.from, insert: state.indentUnit)) }
        spec.userEvent = "input.indent"
        t.dispatch(spec)
        return true
    }

    static let indentLess: Command = { t in
        let state = t.state
        var spec = changeBySelectedLine(state) { line, changes, _ in
            let n = CMText.leadingWhitespace(line.text)
            if n == 0 { return }
            let space = CMText.utf16Slice(line.text, 0, n)
            let col = CMText.countColumn(space, tabSize: state.tabSize)
            let insert = String(repeating: " ", count: max(0, col - state.indentUnitWidth))
            let su = Array(space.utf16), iu = Array(insert.utf16)
            var keep = 0
            while keep < su.count && keep < iu.count && su[keep] == iu[keep] { keep += 1 }
            changes.append(Change(from: line.from + keep, to: line.from + su.count,
                                  insert: String(utf16CodeUnits: Array(iu[keep...]), count: iu.count - keep)))
        }
        spec.userEvent = "delete.dedent"
        t.dispatch(spec)
        return true
    }

    // MARK: search: selectNextOccurrence (Mod-d)

    static let selectNextOccurrence: Command = { t in
        let state = t.state
        let ranges = state.selection.ranges
        if ranges.contains(where: { $0.from == $0.to }) {
            // selectWord
            let newSel = EditorSelection.create(ranges.map { state.wordAt($0.head) ?? SelectionRange.cursor($0.head) },
                                                mainIndex: state.selection.mainIndex)
            if newSel.eq(state.selection) { return false }
            t.dispatch(TransactionSpec(selection: newSel))
            return true
        }
        let searched = state.sliceDoc(ranges[0].from, ranges[0].to)
        if ranges.contains(where: { state.sliceDoc($0.from, $0.to) != searched }) { return false }
        guard let found = findNextOccurrence(state, searched) else { return false }
        t.dispatch(TransactionSpec(selection: state.selection.addRange(SelectionRange.range(found.from, found.to), main: false)))
        return true
    }

    static func findNextOccurrence(_ state: EditorState, _ query: String) -> (from: Int, to: Int)? {
        let main = state.selection.main, ranges = state.selection.ranges
        let word = state.wordAt(main.head)
        let fullWord = word != nil && word!.from == main.from && word!.to == main.to
        let doc = state.doc.units, q = Array(query.utf16)
        func search(_ from: Int, _ to: Int) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            if q.isEmpty { return out }
            var i = from
            while i + q.count <= to {
                if Array(doc[i..<(i + q.count)]) == q { out.append((i, i + q.count)); i += q.count } else { i += 1 }
            }
            return out
        }
        for (cycled, matches) in [(false, search(ranges[ranges.count - 1].to, doc.count)),
                                  (true, search(0, max(0, ranges[ranges.count - 1].from - 1)))] {
            for m in matches {
                if cycled && ranges.contains(where: { $0.from == m.0 }) { continue }
                if fullWord {
                    let w = state.wordAt(m.0)
                    if w == nil || w!.from != m.0 || w!.to != m.1 { continue }
                }
                return (m.0, m.1)
            }
        }
        return nil
    }

    // MARK: history

    static func historyCmd(_ side: Int, _ onlySelection: Bool) -> Command {
        return { t in
            guard let (spec, fh) = t.env.history.pop(side: side, state: t.state, onlySelection: onlySelection) else { return false }
            t.dispatchFromHistory(spec, fh)
            return true
        }
    }
    static let undo = historyCmd(0, false)
    static let redo = historyCmd(1, false)
    static let undoSelection = historyCmd(0, true)
    static let redoSelection = historyCmd(1, true)
}

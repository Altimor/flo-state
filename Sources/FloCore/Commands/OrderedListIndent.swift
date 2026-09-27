import Foundation

/// Tab / Shift-Tab on numbered list items. The item moves under the previous item's
/// content column (a real nested list) and the list is renumbered, so
///     1. a            1. a
///     2. b   Tab →      1. b
///     3. c            2. c
/// Numbers are rewritten per sibling group; a group keeps its first number, except a
/// group that an indent just started, which starts at 1.
enum OrderedListIndent {
    static let itemRE = try! NSRegularExpression(pattern: #"^([ \t]*)(\d{1,9})([.)])([ \t]+)"#)
    static let bulletRE = try! NSRegularExpression(pattern: #"^([ \t]*)[-+*][ \t]+"#)

    struct Item { var indent: Int; var number: Int?; var numberRange: NSRange?; var contentCol: Int; var ordered: Bool }

    static func parse(_ text: String) -> Item? {
        let ns = text as NSString, r = NSRange(location: 0, length: ns.length)
        if let m = itemRE.firstMatch(in: text, range: r) {
            return Item(indent: m.range(at: 1).length, number: Int(ns.substring(with: m.range(at: 2))),
                        numberRange: m.range(at: 2), contentCol: m.range.length, ordered: true)
        }
        if let m = bulletRE.firstMatch(in: text, range: r) {
            return Item(indent: m.range(at: 1).length, number: nil, numberRange: nil, contentCol: m.range.length, ordered: false)
        }
        return nil
    }

    static func selectedOrderedLines(_ state: EditorState) -> [Int]? {
        let lines = ListCommands.selectedLineNumbers(state)
        let items = lines.map { parse(state.doc.line($0).text) }
        guard items.contains(where: { $0?.ordered == true }), items.allSatisfy({ $0 != nil }) else { return nil }
        return lines
    }

    static func indent(_ t: CommandTarget) -> Bool { move(t, deeper: true) }
    static func outdent(_ t: CommandTarget) -> Bool { move(t, deeper: false) }

    private static func move(_ t: CommandTarget, deeper: Bool) -> Bool {
        let state = t.state, doc = state.doc
        guard let lines = selectedOrderedLines(state) else { return false }
        // new indent per moved line
        var newIndent: [Int: Int] = [:]
        for n in lines {
            let it = parse(doc.line(n).text)!
            if deeper {
                // under the nearest item above at the same or lower indent: its content column
                var target = -1
                var k = n - 1
                while k >= 1, let p = parse(doc.line(k).text) {
                    if p.indent <= it.indent { target = p.contentCol; break }
                    k -= 1
                }
                if target > it.indent { newIndent[n] = target }
            } else if it.indent > 0 {
                // back to the indent of the parent item
                var target = 0
                var k = n - 1
                while k >= 1, let p = parse(doc.line(k).text) {
                    if p.indent < it.indent { target = p.indent; break }
                    k -= 1
                }
                newIndent[n] = target
            }
        }
        if newIndent.isEmpty { return false }   // nothing to nest under: plain indent/outdent handles it
        // moved items that continued a numbered list at their old level restart at 1 when indented
        var restart = Set<Int>()
        if deeper {
            for n in newIndent.keys {
                let it = parse(doc.line(n).text)!
                var k = n - 1
                while k >= 1, let p = parse(doc.line(k).text) {
                    if p.indent < it.indent { break }
                    if p.indent == it.indent { if p.ordered { restart.insert(n) }; break }
                    k -= 1
                }
            }
        }
        // simulate the block after the move, then renumber it
        let (first, last) = block(doc, around: lines)
        var texts: [Int: String] = [:]
        for n in first...last { texts[n] = doc.line(n).text }
        for (n, ind) in newIndent {
            let s = texts[n]!, it = parse(s)!
            texts[n] = String(repeating: " ", count: ind) + (s as NSString).substring(from: it.indent)
        }
        var stack: [(indent: Int, last: Int?)] = []      // last = nil: a bullet group
        var changes: [Change] = []
        for n in first...last {
            let s = texts[n]!
            guard let it = parse(s) else { continue }
            while let top = stack.last, top.indent > it.indent { stack.removeLast() }
            var number = it.number
            if let top = stack.last, top.indent == it.indent {
                if it.ordered, let prev = top.last { number = prev + 1 }
                stack[stack.count - 1].last = it.ordered ? number : nil
            } else {
                if it.ordered, restart.contains(n) { number = 1 }   // an indent split it off a numbered list
                stack.append((it.indent, it.ordered ? number : nil))
            }
            // emit minimal edits (indent at the line start, then the number) so the caret maps cleanly
            let line = doc.line(n)
            let orig = parse(line.text)!
            if let ind = newIndent[n], ind != orig.indent {
                if ind > orig.indent { changes.append(Change(from: line.from, insert: String(repeating: " ", count: ind - orig.indent))) }
                else { changes.append(Change(from: line.from, to: line.from + (orig.indent - ind))) }
            }
            if it.ordered, let num = number, num != orig.number, let r = orig.numberRange {
                changes.append(Change(from: line.from + r.location, to: line.from + NSMaxRange(r), insert: String(num)))
            }
        }
        if changes.isEmpty { return true }
        // keep the caret on the same text
        let cs = state.changes(changes)
        let sel = state.selection.main
        let head = cs.mapPos(sel.head, assoc: 1), anchor = cs.mapPos(sel.anchor, assoc: 1)
        t.dispatch(TransactionSpec(changes: changes, selection: .single(anchor, head), userEvent: deeper ? "input.indent" : "delete.outdent"))
        return true
    }

    /// The list block containing the lines: contiguous list-item lines (and indented
    /// continuation lines), stopping at blank lines or unindented non-list text.
    static func block(_ doc: Text, around lines: [Int]) -> (Int, Int) {
        func inList(_ n: Int) -> Bool {
            let s = doc.line(n).text
            if parse(s) != nil { return true }
            return !s.trimmingCharacters(in: .whitespaces).isEmpty && (s.hasPrefix(" ") || s.hasPrefix("\t"))
        }
        var a = lines.min()!, b = lines.max()!
        while a > 1 && inList(a - 1) { a -= 1 }
        while b < doc.lines && inList(b + 1) { b += 1 }
        return (a, b)
    }
}

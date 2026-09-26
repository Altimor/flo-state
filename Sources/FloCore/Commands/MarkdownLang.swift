import Foundation

// Port of @codemirror/lang-markdown 6.5.0 commands:
// insertNewlineContinueMarkup and deleteMarkupBackward.

enum MarkdownLang {
    final class Context {
        let node: SyntaxNode
        let from: Int
        let to: Int
        let spaceBefore: String
        let spaceAfter: String
        let type: String
        let item: SyntaxNode?
        init(_ node: SyntaxNode, _ from: Int, _ to: Int, _ spaceBefore: String, _ spaceAfter: String, _ type: String, _ item: SyntaxNode?) {
            self.node = node; self.from = from; self.to = to
            self.spaceBefore = spaceBefore; self.spaceAfter = spaceAfter; self.type = type; self.item = item
        }

        func blank(_ maxWidth: Int?, trailing: Bool = true) -> String {
            var result = spaceBefore + (node.name == "Blockquote" ? ">" : "")
            if let maxWidth = maxWidth {
                while result.utf16.count < maxWidth { result += " " }
                return result
            }
            var i = to - from - result.utf16.count - spaceAfter.utf16.count
            while i > 0 { result += " "; i -= 1 }
            return result + (trailing ? spaceAfter : "")
        }

        func marker(_ doc: Text, _ add: Int) -> String {
            var number = ""
            if node.name == "OrderedList", let item = item, let m = itemNumber(item, doc) {
                number = String((Int(m[2] ?? "0") ?? 0) + add)
            }
            return spaceBefore + number + type + spaceAfter
        }
    }

    static let BQ_RE = JSRegex("^ *>( ?)")
    static let OL_RE = JSRegex("^( *)\\d+([.)])( *)")
    static let BL_RE = JSRegex("^( *)([-+*])( {1,4}\\[[ xX]\\])?( +)")

    static func getContext(_ start: SyntaxNode, _ doc: Text) -> [Context] {
        var nodes: [SyntaxNode] = []
        var context: [Context] = []
        var cur: SyntaxNode? = start
        while let c = cur {
            if c.name == "FencedCode" { return context }
            if c.name == "ListItem" || c.name == "Blockquote" { nodes.append(c) }
            cur = c.parent
        }
        for node in nodes.reversed() {
            let line = doc.lineAt(node.from)
            let startPos = node.from - line.from
            let rest = CMText.utf16Slice(line.text, startPos)
            if node.name == "Blockquote", let m = BQ_RE.exec(rest) {
                context.append(Context(node, startPos, startPos + m.length, "", m[1] ?? "", ">", nil))
            } else if node.name == "ListItem", node.parent?.name == "OrderedList", let m = OL_RE.exec(rest) {
                var after = m[3] ?? ""
                var len = m.length
                if after.utf16.count >= 4 {
                    after = CMText.utf16Slice(after, 0, after.utf16.count - 4)
                    len -= 4
                }
                context.append(Context(node.parent!, startPos, startPos + len, m[1] ?? "", after, m[2] ?? ".", node))
            } else if node.name == "ListItem", node.parent?.name == "BulletList", let m = BL_RE.exec(rest) {
                var after = m[4] ?? ""
                var len = m.length
                if after.utf16.count > 4 {
                    after = CMText.utf16Slice(after, 0, after.utf16.count - 4)
                    len -= 4
                }
                var type = m[2] ?? "-"
                if let task = m[3] {
                    type += task.replacingOccurrences(of: "[xX]", with: " ", options: .regularExpression, range: task.range(of: "[xX]", options: .regularExpression))
                }
                context.append(Context(node.parent!, startPos, startPos + len, m[1] ?? "", after, type, node))
            }
        }
        return context
    }

    static let ITEM_NUMBER_RE = JSRegex("^(\\s*)(\\d+)(?=[.)])")
    static func itemNumber(_ item: SyntaxNode, _ doc: Text) -> JSRegex.Match? {
        ITEM_NUMBER_RE.exec(doc.slice(item.from, item.from + 10))
    }

    static func renumberList(_ after: SyntaxNode, _ doc: Text, _ changes: inout [Change], _ offset: Int = 0) {
        var prev = -1
        var node = after
        while true {
            if node.name == "ListItem" {
                guard let m = itemNumber(node, doc) else { return }
                let number = Int(m[2] ?? "") ?? 0
                if prev >= 0 {
                    if number != prev + 1 { return }
                    changes.append(Change(from: node.from + m.len(1), to: node.from + m.length, insert: String(prev + 2 + offset)))
                }
                prev = number
            }
            guard let next = node.cmNextSibling else { break }
            node = next
        }
    }

    /// normalizeIndent: only rewrites when indentUnit is a tab (never in this app).
    static func normalizeIndent(_ content: String, _ state: EditorState) -> String { content }

    static func nonTightList(_ node: SyntaxNode, _ doc: Text) -> Bool {
        if node.name != "OrderedList" && node.name != "BulletList" { return false }
        guard let first = node.cmFirstChild, let second = node.cmGetChild("ListItem", after: "ListItem") else { return false }
        let line1 = doc.lineAt(first.to), line2 = doc.lineAt(second.from)
        let empty = JSRegex("^[\\s>]*$").test(line1.text)
        return line1.number + (empty ? 0 : 1) < line2.number
    }

    static func blankLine(_ context: [Context], _ state: EditorState, _ line: Line) -> String {
        var insert = ""
        let e = context.count - 2
        if e >= 0 {
            for i in 0...e {
                insert += context[i].blank(i < e ? CMText.countColumn(line.text, tabSize: 4, to: context[i + 1].from) - insert.utf16.count : nil,
                                           trailing: i < e)
            }
        }
        return normalizeIndent(insert, state)
    }

    static let insertNewlineContinueMarkup: Command = { t in
        let state = t.state
        let tree = state.tree, doc = state.doc
        var dont = false
        let spec = state.changeByRange { range -> ([Change], SelectionRange) in
            if !range.empty || (!state.markdownActiveAt(range.from, -1) && !state.markdownActiveAt(range.from, 1)) {
                dont = true; return ([], range)
            }
            let pos = range.from, line = doc.lineAt(pos)
            var context = getContext(Lezer.resolveInner(tree, pos, -1), doc)
            while let last = context.last, last.from > pos - line.from { context.removeLast() }
            if context.isEmpty { dont = true; return ([], range) }
            let inner = context[context.count - 1]
            if inner.to - inner.spaceAfter.utf16.count > pos - line.from { dont = true; return ([], range) }
            let emptyLine = pos >= (inner.to - inner.spaceAfter.utf16.count) && !CMText.hasNonSpace(CMText.utf16Slice(line.text, inner.to))
            if let item = inner.item, emptyLine {
                let first = inner.node.cmFirstChild!, second = inner.node.cmGetChild("ListItem", after: "ListItem")
                if first.to >= pos || (second != nil && second!.to < pos) ||
                    (line.from > 0 && !JSRegex("[^\\s>]").test(doc.lineAt(line.from - 1).text)) {
                    let next = context.count > 1 ? context[context.count - 2] : nil
                    var delTo: Int, insert = ""
                    if let next = next, next.item != nil {
                        delTo = line.from + next.from
                        insert = next.marker(doc, 1)
                    } else {
                        delTo = line.from + (next?.to ?? 0)
                    }
                    var changes = [Change(from: delTo, to: pos, insert: insert)]
                    if inner.node.name == "OrderedList" { renumberList(item, doc, &changes, -2) }
                    if let next = next, next.node.name == "OrderedList", let ni = next.item { renumberList(ni, doc, &changes) }
                    return (changes, SelectionRange.cursor(delTo + insert.utf16.count))
                } else {
                    let insert = blankLine(context, state, line)
                    return ([Change(from: line.from, insert: insert + "\n")], SelectionRange.cursor(pos + insert.utf16.count + 1))
                }
            }
            if inner.node.name == "Blockquote" && emptyLine && line.from > 0 {
                let prevLine = doc.lineAt(line.from - 1)
                if let quoted = JSRegex(">\\s*$").exec(prevLine.text), quoted.index == inner.from {
                    let cs = state.changes([Change(from: prevLine.from + quoted.index, to: prevLine.to),
                                            Change(from: line.from + inner.from, to: line.to)])
                    return (cs.changes, range.map(cs))
                }
            }
            var changes: [Change] = []
            if inner.node.name == "OrderedList", let item = inner.item { renumberList(item, doc, &changes) }
            let continued = inner.item != nil && inner.item!.from < line.from
            var insert = ""
            if !continued || (JSRegex("^[\\s\\d.)\\-+*>]*").exec(line.text)?.length ?? 0) >= inner.to {
                let e = context.count - 1
                for i in 0...e {
                    insert += i == e && !continued ? context[i].marker(doc, 1)
                        : context[i].blank(i < e ? CMText.countColumn(line.text, tabSize: 4, to: context[i + 1].from) - insert.utf16.count : nil)
                }
            }
            var from = pos
            let lt = Array(line.text.utf16)
            while from > line.from && CMText.isJSSpace(lt[from - line.from - 1]) { from -= 1 }
            insert = normalizeIndent(insert, state)
            if nonTightList(inner.node, state.doc) {
                insert = blankLine(context, state, line) + "\n" + insert
            }
            changes.append(Change(from: from, to: pos, insert: "\n" + insert))
            return (changes, SelectionRange.cursor(from + insert.utf16.count + 1))
        }
        if dont { return false }
        var s = spec
        s.userEvent = "input"
        t.dispatch(s)
        return true
    }

    static func isMark(_ n: SyntaxNode) -> Bool { n.name == "QuoteMark" || n.name == "ListMark" }

    static func contextNodeForDelete(_ tree: SyntaxTree, _ pos: Int) -> SyntaxNode {
        var node = Lezer.resolveInner(tree, pos, -1)
        var scan = pos
        if isMark(node) {
            scan = node.from
            node = node.parent!
        }
        while let prev = node.cmChildBefore(scan) {
            if isMark(prev) {
                scan = prev.from
            } else if prev.name == "OrderedList" || prev.name == "BulletList" {
                guard let lc = prev.cmLastChild else { break }
                node = lc
                scan = node.to
            } else {
                break
            }
        }
        return node
    }

    static let deleteMarkupBackward: Command = { t in
        let state = t.state
        let tree = state.tree
        var dont = false
        let spec = state.changeByRange { range -> ([Change], SelectionRange) in
            let pos = range.from, doc = state.doc
            if range.empty && state.markdownActiveAt(range.from) {
                let line = doc.lineAt(pos)
                let context = getContext(contextNodeForDelete(tree, pos), doc)
                if let inner = context.last {
                    let spaceEnd = inner.to - inner.spaceAfter.utf16.count + (inner.spaceAfter.isEmpty ? 0 : 1)
                    if pos - line.from > spaceEnd && !CMText.hasNonSpace(CMText.utf16Slice(line.text, spaceEnd, pos - line.from)) {
                        return ([Change(from: line.from + spaceEnd, to: pos)], SelectionRange.cursor(line.from + spaceEnd))
                    }
                    if pos - line.from == spaceEnd &&
                        (inner.item == nil || line.from <= inner.item!.from || !CMText.hasNonSpace(CMText.utf16Slice(line.text, 0, inner.to))) {
                        let start = line.from + inner.from
                        if let item = inner.item, inner.node.from < item.from,
                           CMText.hasNonSpace(CMText.utf16Slice(line.text, inner.from, inner.to)) {
                            let insert = inner.blank(CMText.countColumn(line.text, tabSize: 4, to: inner.to) - CMText.countColumn(line.text, tabSize: 4, to: inner.from))
                            return ([Change(from: start, to: line.from + inner.to, insert: insert)], SelectionRange.cursor(start + insert.utf16.count))
                        }
                        if start < pos {
                            return ([Change(from: start, to: pos)], SelectionRange.cursor(start))
                        }
                    }
                }
            }
            dont = true
            return ([], range)
        }
        if dont { return false }
        var s = spec
        s.userEvent = "delete"
        t.dispatch(s)
        return true
    }
}

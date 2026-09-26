import Foundation

// Block-level parsing: port of lezer's Line / BlockContext / CompositeBlock and the
// default block parsers, plus the Table/TaskList, Frontmatter and HTML-block
// extensions, in the exact precedence order the web app configures them.

final class MDCompositeBlock {
    let type: Int
    let value: Int
    let from: Int
    var end: Int
    var children: [MDElt] = []

    init(type: Int, value: Int, from: Int, end: Int) {
        self.type = type
        self.value = value
        self.from = from
        self.end = end
    }

    func toElt(end endIn: Int? = nil) -> MDElt {
        var end = endIn ?? self.end
        if let last = children.last { end = max(end, last.to) }
        return MDElt(type, from, end, children)
    }
}

final class MDLine {
    var text: MDText = []
    var baseIndent = 0
    var basePos = 0
    var depth = 0
    var markers: [MDElt] = []
    var pos = 0
    var indent = 0
    var next = -1

    @inline(__always) func forward() { if basePos > pos { forwardInner() } }

    func forwardInner() {
        let newPos = skipSpace(basePos)
        indent = countIndent(newPos, pos, indent)
        pos = newPos
        next = newPos == text.count ? -1 : Int(text[newPos])
    }

    @inline(__always) func skipSpace(_ from: Int) -> Int { mdSkipSpace(text, from) }

    func reset(_ t: MDText) {
        text = t
        baseIndent = 0; basePos = 0; pos = 0; indent = 0
        forwardInner()
        depth = 1
        markers.removeAll(keepingCapacity: true)
    }

    func moveBase(_ to: Int) {
        basePos = to
        baseIndent = countIndent(to, pos, indent)
    }

    func moveBaseColumn(_ indent: Int) {
        baseIndent = indent
        basePos = findColumn(indent)
    }

    func addMarker(_ elt: MDElt) { markers.append(elt) }

    func countIndent(_ to: Int, _ from: Int = 0, _ indentIn: Int = 0) -> Int {
        var indent = indentIn
        var i = from
        while i < to {
            indent += mdCh(text, i) == 9 ? 4 - indent % 4 : 1
            i += 1
        }
        return indent
    }

    func findColumn(_ goal: Int) -> Int {
        var i = 0, indent = 0
        while i < text.count && indent < goal {
            indent += text[i] == 9 ? 4 - indent % 4 : 1
            i += 1
        }
        return i
    }

    func scrub() -> MDText {
        if baseIndent == 0 { return text }
        var result = MDText(repeating: 32, count: basePos)
        if basePos < text.count { result.append(contentsOf: text[basePos...]) }
        return result
    }

    @inline(__always) func ch(_ i: Int) -> Int { mdCh(text, i) }
}

final class MDLeafBlock {
    var marks: [MDElt] = []
    var parsers: [MDLeafBlockParser] = []
    let start: Int
    var content: MDText
    init(start: Int, content: MDText) {
        self.start = start
        self.content = content
    }
}

protocol MDLeafBlockParser: AnyObject {
    func nextLine(_ cx: MDBlockContext, _ line: MDLine, _ leaf: MDLeafBlock) -> Bool
    func finish(_ cx: MDBlockContext, _ leaf: MDLeafBlock) -> Bool
}

enum MDBlockResult { case no, leaf, context }

// MARK: - Line classification

func mdIsFencedCode(_ line: MDLine) -> Int {
    if line.next != 96 && line.next != 126 { return -1 }
    var pos = line.pos + 1
    while pos < line.text.count && Int(line.text[pos]) == line.next { pos += 1 }
    if pos < line.pos + 3 { return -1 }
    if line.next == 96 {
        var i = pos
        while i < line.text.count { if line.text[i] == 96 { return -1 }; i += 1 }
    }
    return pos
}

func mdIsBlockquote(_ line: MDLine) -> Int {
    line.next != 62 ? -1 : line.ch(line.pos + 1) == 32 ? 2 : 1
}

func mdIsHorizontalRule(_ line: MDLine, _ cx: MDBlockContext, _ breaking: Bool) -> Int {
    if line.next != 42 && line.next != 45 && line.next != 95 { return -1 }
    var count = 1
    var pos = line.pos + 1
    while pos < line.text.count {
        let c = Int(line.text[pos])
        if c == line.next { count += 1 } else if !mdSpace(c) { return -1 }
        pos += 1
    }
    // Setext headers take precedence
    if breaking && line.next == 45 && mdIsSetextUnderline(line) > -1 && line.depth == cx.stack.count { return -1 }
    return count < 3 ? -1 : 1
}

func mdInList(_ cx: MDBlockContext, _ type: Int) -> Bool {
    var i = cx.stack.count - 1
    while i >= 0 { if cx.stack[i].type == type { return true }; i -= 1 }
    return false
}

func mdIsBulletList(_ line: MDLine, _ cx: MDBlockContext, _ breaking: Bool) -> Int {
    return (line.next == 45 || line.next == 43 || line.next == 42) &&
        (line.pos == line.text.count - 1 || mdSpace(line.ch(line.pos + 1))) &&
        (!breaking || mdInList(cx, MDType.BulletList) || line.skipSpace(line.pos + 2) < line.text.count) ? 1 : -1
}

func mdIsOrderedList(_ line: MDLine, _ cx: MDBlockContext, _ breaking: Bool) -> Int {
    var pos = line.pos, next = line.next
    while true {
        if next >= 48 && next <= 57 { pos += 1 } else { break }
        if pos == line.text.count { return -1 }
        next = Int(line.text[pos])
    }
    if pos == line.pos || pos > line.pos + 9 ||
        (next != 46 && next != 41) ||
        (pos < line.text.count - 1 && !mdSpace(line.ch(pos + 1))) ||
        (breaking && !mdInList(cx, MDType.OrderedList) &&
            (line.skipSpace(pos + 1) == line.text.count || pos > line.pos + 1 || line.next != 49)) {
        return -1
    }
    return pos + 1 - line.pos
}

func mdIsAtxHeading(_ line: MDLine) -> Int {
    if line.next != 35 { return -1 }
    var pos = line.pos + 1
    while pos < line.text.count && line.text[pos] == 35 { pos += 1 }
    if pos < line.text.count && line.text[pos] != 32 { return -1 }
    let size = pos - line.pos
    return size > 6 ? -1 : size
}

func mdIsSetextUnderline(_ line: MDLine) -> Int {
    if (line.next != 45 && line.next != 61) || line.indent >= line.baseIndent + 4 { return -1 }
    var pos = line.pos + 1
    while pos < line.text.count && Int(line.text[pos]) == line.next { pos += 1 }
    let end = pos
    while pos < line.text.count && mdSpace(Int(line.text[pos])) { pos += 1 }
    return pos == line.text.count ? end : -1
}

// MARK: HTML block styles

enum MDHTMLEnd { case scriptClose, commentEnd, processingEnd, gt, cdataEnd, emptyLine }

let mdHTMLBlockNames: Set<String> = [
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
    "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
    "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
    "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
    "optgroup", "option", "p", "param", "section", "source", "summary", "table", "tbody", "td", "tfoot",
    "th", "thead", "title", "tr", "track", "ul",
]

func mdLowerAscii(_ t: MDText, _ from: Int, _ to: Int) -> String {
    var s = ""
    s.unicodeScalars.reserveCapacity(to - from)
    for i in from..<to { s.unicodeScalars.append(Unicode.Scalar(UInt8(asciiLower(Int(t[i]))))) }
    return s
}

/// Test HTMLBlockStyle[i][0] against `rest` (which starts with '<').
func mdHTMLStart(_ i: Int, _ r: MDText) -> Bool {
    switch i {
    case 0: // /^<(?:script|pre|style)(?:\s|>|$)/i
        var p = 1
        while p < r.count && isAsciiAlnum(Int(r[p])) { p += 1 }
        let name = mdLowerAscii(r, 1, p)
        guard name == "script" || name == "pre" || name == "style" else { return false }
        return p == r.count || jsSpace(Int(r[p])) || r[p] == 62
    case 1: return mdStarts(r, 0, "<!--")
    case 2: return mdStarts(r, 0, "<?")
    case 3: return mdStarts(r, 0, "<!") && mdCh(r, 2) >= 65 && mdCh(r, 2) <= 90
    case 4: return mdStarts(r, 0, "<![CDATA[")
    case 5: // block tag names
        var p = 1
        if mdCh(r, p) == 47 { p += 1 }
        let s = p
        while p < r.count && isAsciiAlnum(Int(r[p])) { p += 1 }
        if p == s || !mdHTMLBlockNames.contains(mdLowerAscii(r, s, p)) { return false }
        if p == r.count || jsSpace(Int(r[p])) || r[p] == 62 { return true }
        return r[p] == 47 && mdCh(r, p + 1) == 62
    case 6:
        // /^\s*(?:<\/[a-z][\w-]*\s*>|<[a-z][\w-]*(attrs)*\s*>)\s*$/i
        var p = jsSkipSpace(r, 0)
        guard mdCh(r, p) == 60 else { return false }
        p += 1
        if mdCh(r, p) == 47 {
            p += 1
            guard isAsciiAlpha(mdCh(r, p)) else { return false }
            p += 1
            while p < r.count && (jsWord(Int(r[p])) || r[p] == 45) { p += 1 }
            p = jsSkipSpace(r, p)
            guard mdCh(r, p) == 62 else { return false }
            p += 1
        } else {
            guard let e = mdMatchOpenTag(r, p, attrColon: false, allowSlash: false) else { return false }
            p = e
        }
        return jsSkipSpace(r, p) == r.count
    default: return false
    }
}

/// Matches `[a-zA-Z][\w-]*(\s+[a-zA-Z:_][\w-.(:)]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*(\/\s*)?>`
/// starting at `i` (the tag name). Returns the position after '>'.
func mdMatchOpenTag(_ t: MDText, _ i: Int, attrColon: Bool, allowSlash: Bool) -> Int? {
    var p = i
    guard isAsciiAlpha(mdCh(t, p)) else { return nil }
    p += 1
    while p < t.count && (jsWord(Int(t[p])) || t[p] == 45) { p += 1 }
    while true {
        let ws = jsSkipSpace(t, p)
        if ws > p {
            let c = mdCh(t, ws)
            if isAsciiAlpha(c) || c == 58 || c == 95 {
                var r = ws + 1
                while r < t.count {
                    let d = Int(t[r])
                    if jsWord(d) || d == 45 || d == 46 || (attrColon && d == 58) { r += 1 } else { break }
                }
                let v = jsSkipSpace(t, r)
                if mdCh(t, v) == 61 {
                    let w = jsSkipSpace(t, v + 1)
                    let q = mdCh(t, w)
                    if q == 34 || q == 39 {
                        var k = w + 1
                        while k < t.count && Int(t[k]) != q { k += 1 }
                        if k < t.count { r = k + 1 }
                    } else {
                        var k = w
                        while k < t.count {
                            let d = Int(t[k])
                            if jsSpace(d) || d == 34 || d == 39 || d == 61 || d == 60 || d == 62 || d == 96 { break }
                            k += 1
                        }
                        if k > w { r = k }
                    }
                }
                p = r
                continue
            }
        }
        break
    }
    p = jsSkipSpace(t, p)
    if allowSlash && mdCh(t, p) == 47 { p = jsSkipSpace(t, p + 1) }
    return mdCh(t, p) == 62 ? p + 1 : nil
}

func mdHTMLEndMatches(_ end: MDHTMLEnd, _ t: MDText) -> Bool {
    switch end {
    case .scriptClose:
        // /<\/(?:script|pre|style)>/i
        var i = 0
        while i + 1 < t.count {
            if t[i] == 60 && t[i + 1] == 47 {
                for n: StaticString in ["script", "pre", "style"] {
                    if mdStarts(t, i + 2, n, caseInsensitive: true) && mdCh(t, i + 2 + n.utf8CodeUnitCount) == 62 { return true }
                }
            }
            i += 1
        }
        return false
    case .commentEnd: return mdContains(t, "-->")
    case .processingEnd: return mdContains(t, "?>")
    case .gt: return t.contains(62)
    case .cdataEnd: return mdContains(t, "]]>")
    case .emptyLine:
        for c in t where c != 32 && c != 9 { return false }
        return true
    }
}

let mdHTMLEnds: [MDHTMLEnd] = [.scriptClose, .commentEnd, .processingEnd, .gt, .cdataEnd, .emptyLine, .emptyLine]

func mdIsHTMLBlock(_ line: MDLine, _ breaking: Bool) -> Int {
    if line.next != 60 { return -1 }
    let rest = mdSlice(line.text, line.pos, line.text.count)
    let e = 7 - (breaking ? 1 : 0)
    for i in 0..<e where mdHTMLStart(i, rest) { return i }
    return -1
}

func mdGetListIndent(_ line: MDLine, _ pos: Int) -> Int {
    let indentAfter = line.countIndent(pos, line.pos, line.indent)
    let indented = line.countIndent(line.skipSpace(pos), pos, indentAfter)
    return indented >= indentAfter + 5 ? indentAfter + 1 : indented
}

func mdAddCodeText(_ marks: inout [MDElt], _ from: Int, _ to: Int) {
    if let last = marks.last, last.to == from, last.type == MDType.CodeText {
        last.to = to
    } else {
        marks.append(MDElt(MDType.CodeText, from, to))
    }
}

// MARK: - Block context

final class MDBlockContext {
    var block: MDCompositeBlock
    var stack: [MDCompositeBlock]
    let line = MDLine()
    var atEnd = false
    let input: MDText
    let to: Int
    var lineStart = 0
    var absoluteLineStart = 0
    var absoluteLineEnd = 0

    init(_ input: MDText) {
        self.input = input
        self.to = input.count
        block = MDCompositeBlock(type: MDType.Document, value: 0, from: 0, end: 0)
        stack = [block]
        readLine()
    }

    func parse() -> MDElt {
        while true {
            if let doc = advance() { return doc }
        }
    }

    // MARK: advance

    func advance() -> MDElt? {
        let line = self.line
        while true {
            var markI = 0
            while true {
                let next: MDCompositeBlock? = line.depth < stack.count ? stack[stack.count - 1] : nil
                while markI < line.markers.count && (next == nil || line.markers[markI].from < next!.end) {
                    let mark = line.markers[markI]
                    markI += 1
                    addNode(mark.type, mark.from, mark.to)
                }
                if next == nil { break }
                finishContext()
            }
            if line.pos < line.text.count { break }
            // Empty line
            if !nextLine() { return finish() }
        }

        start: while true {
            for type in MDBlockContext.blockParsers {
                let result = type(self, line)
                if result != .no {
                    if result == .leaf { return nil }
                    line.forward()
                    continue start
                }
            }
            break
        }

        let leaf = MDLeafBlock(start: lineStart + line.pos, content: mdSlice(line.text, line.pos, line.text.count))
        for parse in MDBlockContext.leafBlockParsers {
            if let p = parse(self, leaf) { leaf.parsers.append(p) }
        }
        lines: while nextLine() {
            if line.pos == line.text.count { break }
            if line.indent < line.baseIndent + 4 {
                for stop in MDBlockContext.endLeafBlock where stop(self, line, leaf) { break lines }
            }
            for parser in leaf.parsers where parser.nextLine(self, line, leaf) { return nil }
            leaf.content.append(10)
            leaf.content.append(contentsOf: line.scrub())
            leaf.marks.append(contentsOf: line.markers)
        }
        finishLeaf(leaf)
        return nil
    }

    var depth: Int { stack.count }

    func parentType() -> Int { stack[stack.count - 1].type }

    @discardableResult
    func nextLine() -> Bool {
        lineStart += line.text.count
        if absoluteLineEnd >= to {
            absoluteLineStart = absoluteLineEnd
            atEnd = true
            readLine()
            return false
        } else {
            lineStart += 1
            absoluteLineStart = absoluteLineEnd + 1
            readLine()
            return true
        }
    }

    func scanLine(_ start: Int) -> (MDText, Int) {
        if start >= to { return ([], start) }
        var e = start
        while e < to && input[e] != 10 { e += 1 }
        return (Array(input[start..<e]), e)
    }

    func peekLine() -> MDText { scanLine(absoluteLineEnd + 1).0 }

    func readLine() {
        let (text, end) = scanLine(absoluteLineStart)
        absoluteLineEnd = end
        line.reset(text)
        while line.depth < stack.count {
            let cx = stack[line.depth]
            let marks = line.markers.count
            if !skipMarkup(cx) {
                if line.markers.count > marks { cx.end = line.markers[line.markers.count - 1].to }
                line.forward()
                break
            }
            line.forward()
            line.depth += 1
        }
    }

    private func skipMarkup(_ bl: MDCompositeBlock) -> Bool {
        switch bl.type {
        case MDType.Blockquote:
            if line.next != 62 { return false }
            line.markers.append(MDElt(MDType.QuoteMark, lineStart + line.pos, lineStart + line.pos + 1))
            line.moveBase(line.pos + (mdSpace(line.ch(line.pos + 1)) ? 2 : 1))
            bl.end = lineStart + line.text.count
            return true
        case MDType.ListItem:
            if line.indent < line.baseIndent + bl.value && line.next > -1 { return false }
            line.moveBaseColumn(line.baseIndent + bl.value)
            return true
        case MDType.OrderedList, MDType.BulletList:
            return skipForList(bl)
        default:
            return true
        }
    }

    private func skipForList(_ bl: MDCompositeBlock) -> Bool {
        if line.pos == line.text.count ||
            (bl !== block && line.indent >= stack[line.depth + 1].value + line.baseIndent) { return true }
        if line.indent >= line.baseIndent + 4 { return false }
        let size = bl.type == MDType.OrderedList ? mdIsOrderedList(line, self, false) : mdIsBulletList(line, self, false)
        return size > 0 &&
            (bl.type != MDType.BulletList || mdIsHorizontalRule(line, self, false) < 0) &&
            line.ch(line.pos + size - 1) == bl.value
    }

    func prevLineEnd() -> Int { atEnd ? lineStart : lineStart - 1 }

    func startContext(_ type: Int, _ start: Int, _ value: Int = 0) {
        block = MDCompositeBlock(type: type, value: value, from: lineStart + start, end: lineStart + line.text.count)
        stack.append(block)
    }

    func addNode(_ type: Int, _ from: Int, _ to: Int? = nil) {
        block.children.append(MDElt(type, from, to ?? prevLineEnd()))
    }

    func addNode(_ elt: MDElt) { block.children.append(elt) }

    func addElement(_ elt: MDElt) { block.children.append(elt) }

    func addLeafElement(_ leaf: MDLeafBlock, _ elt: MDElt) {
        addNode(MDElt(elt.type, elt.from, elt.to, mdInjectMarks(elt.children, leaf.marks)))
    }

    func finishContext() {
        let cx = stack.removeLast()
        let top = stack[stack.count - 1]
        top.children.append(cx.toElt())
        block = top
    }

    private func finish() -> MDElt {
        while stack.count > 1 { finishContext() }
        return block.toElt(end: lineStart)
    }

    func finishLeaf(_ leaf: MDLeafBlock) {
        for parser in leaf.parsers where parser.finish(self, leaf) { return }
        let inline = mdInjectMarks(mdParseInline(leaf.content, leaf.start), leaf.marks)
        addNode(MDElt(MDType.Paragraph, leaf.start, leaf.start + leaf.content.count, inline))
    }

    // MARK: Parser tables (configured order)

    typealias BlockParserFn = (MDBlockContext, MDLine) -> MDBlockResult
    typealias LeafParserFn = (MDBlockContext, MDLeafBlock) -> MDLeafBlockParser?
    typealias EndLeafFn = (MDBlockContext, MDLine, MDLeafBlock) -> Bool

    // Names: LinkReference, IndentedCode, FencedCode, Blockquote, Frontmatter, HorizontalRule,
    // BulletList, OrderedList, ATXHeading, DetailsHTMLBlock, SelfClosingHTMLBlock, HTMLBlock,
    // Table, SetextHeading, TaskList
    static let blockParsers: [BlockParserFn] = [
        parseIndentedCode, parseFencedCode, parseBlockquote, parseFrontmatter, parseHorizontalRule,
        parseBulletList, parseOrderedList, parseATXHeading, parseDetailsHTMLBlock, parseSelfClosingHTMLBlock,
        parseHTMLBlock,
    ]

    static let leafBlockParsers: [LeafParserFn] = [
        { _, leaf in leaf.content.first == 91 ? MDLinkReferenceParser(leaf) : nil },
        { _, leaf in mdHasPipe(leaf.content, 0) ? MDTableParser() : nil },
        { _, _ in MDSetextHeadingParser() },
        { cx, leaf in
            let c = leaf.content
            let ok = c.count >= 4 && c[0] == 91 && (c[1] == 32 || c[1] == 120 || c[1] == 88) && c[2] == 93 && (c[3] == 32 || c[3] == 9)
            return ok && cx.parentType() == MDType.ListItem ? MDTaskParser() : nil
        },
    ]

    static let endLeafBlock: [EndLeafFn] = [
        { _, line, _ in mdIsAtxHeading(line) >= 0 },
        { _, line, _ in mdIsFencedCode(line) >= 0 },
        { _, line, _ in mdIsBlockquote(line) >= 0 },
        { p, line, _ in mdIsBulletList(line, p, true) >= 0 },
        { p, line, _ in mdIsOrderedList(line, p, true) >= 0 },
        { p, line, _ in mdIsHorizontalRule(line, p, true) >= 0 },
        { _, line, _ in mdIsHTMLBlock(line, true) >= 0 },
        // Table
        { cx, line, leaf in
            if leaf.parsers.contains(where: { $0 is MDTableParser }) || !mdHasPipe(line.text, line.basePos) { return false }
            let next = cx.peekLine()
            return mdDelimiterLine(next) && mdParseRow(line.text, line.basePos) == mdParseRow(next, line.basePos)
        },
    ]
}

// MARK: - Default block parsers

private func parseIndentedCode(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    let base = line.baseIndent + 4
    if line.indent < base { return .no }
    let start = line.findColumn(base)
    let from = cx.lineStart + start
    var to = cx.lineStart + line.text.count
    var marks: [MDElt] = [], pendingMarks: [MDElt] = []
    mdAddCodeText(&marks, from, to)
    while cx.nextLine() && line.depth >= cx.stack.count {
        if line.pos == line.text.count { // Empty
            mdAddCodeText(&pendingMarks, cx.lineStart - 1, cx.lineStart)
            for m in line.markers { pendingMarks.append(m) }
        } else if line.indent < base {
            break
        } else {
            if !pendingMarks.isEmpty {
                for m in pendingMarks {
                    if m.type == MDType.CodeText { mdAddCodeText(&marks, m.from, m.to) } else { marks.append(m) }
                }
                pendingMarks = []
            }
            mdAddCodeText(&marks, cx.lineStart - 1, cx.lineStart)
            for m in line.markers { marks.append(m) }
            to = cx.lineStart + line.text.count
            let codeStart = cx.lineStart + line.findColumn(line.baseIndent + 4)
            if codeStart < to { mdAddCodeText(&marks, codeStart, to) }
        }
    }
    if !pendingMarks.isEmpty {
        pendingMarks = pendingMarks.filter { $0.type != MDType.CodeText }
        if !pendingMarks.isEmpty { line.markers = pendingMarks + line.markers }
    }
    cx.addNode(MDElt(MDType.CodeBlock, from, to, marks))
    return .leaf
}

private func parseFencedCode(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    let fenceEnd = mdIsFencedCode(line)
    if fenceEnd < 0 { return .no }
    let from = cx.lineStart + line.pos, ch = line.next, len = fenceEnd - line.pos
    let infoFrom = line.skipSpace(fenceEnd), infoTo = mdSkipSpaceBack(line.text, line.text.count, infoFrom)
    var marks: [MDElt] = [MDElt(MDType.CodeMark, from, from + len)]
    if infoFrom < infoTo {
        marks.append(MDElt(MDType.CodeInfo, cx.lineStart + infoFrom, cx.lineStart + infoTo))
    }
    var first = true, empty = true, hasLine = false
    while cx.nextLine() && line.depth >= cx.stack.count {
        var i = line.pos
        if line.indent - line.baseIndent < 4 {
            while i < line.text.count && Int(line.text[i]) == ch { i += 1 }
        }
        if i - line.pos >= len && line.skipSpace(i) == line.text.count {
            for m in line.markers { marks.append(m) }
            if empty && hasLine { mdAddCodeText(&marks, cx.lineStart - 1, cx.lineStart) }
            marks.append(MDElt(MDType.CodeMark, cx.lineStart + line.pos, cx.lineStart + i))
            cx.nextLine()
            break
        } else {
            hasLine = true
            if !first { mdAddCodeText(&marks, cx.lineStart - 1, cx.lineStart); empty = false }
            for m in line.markers { marks.append(m) }
            let textStart = cx.lineStart + line.basePos, textEnd = cx.lineStart + line.text.count
            if textStart < textEnd { mdAddCodeText(&marks, textStart, textEnd); empty = false }
        }
        first = false
    }
    cx.addNode(MDElt(MDType.FencedCode, from, cx.prevLineEnd(), marks))
    return .leaf
}

private func parseBlockquote(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    let size = mdIsBlockquote(line)
    if size < 0 { return .no }
    cx.startContext(MDType.Blockquote, line.pos)
    cx.addNode(MDType.QuoteMark, cx.lineStart + line.pos, cx.lineStart + line.pos + 1)
    line.moveBase(line.pos + size)
    return .context
}

private func parseHorizontalRule(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    if mdIsHorizontalRule(line, cx, false) < 0 { return .no }
    let from = cx.lineStart + line.pos
    cx.nextLine()
    cx.addNode(MDType.HorizontalRule, from)
    return .leaf
}

private func parseBulletList(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    let size = mdIsBulletList(line, cx, false)
    if size < 0 { return .no }
    if cx.block.type != MDType.BulletList {
        cx.startContext(MDType.BulletList, line.basePos, line.next)
    }
    let newBase = mdGetListIndent(line, line.pos + 1)
    cx.startContext(MDType.ListItem, line.basePos, newBase - line.baseIndent)
    cx.addNode(MDType.ListMark, cx.lineStart + line.pos, cx.lineStart + line.pos + size)
    line.moveBaseColumn(newBase)
    return .context
}

private func parseOrderedList(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    let size = mdIsOrderedList(line, cx, false)
    if size < 0 { return .no }
    if cx.block.type != MDType.OrderedList {
        cx.startContext(MDType.OrderedList, line.basePos, line.ch(line.pos + size - 1))
    }
    let newBase = mdGetListIndent(line, line.pos + size)
    cx.startContext(MDType.ListItem, line.basePos, newBase - line.baseIndent)
    cx.addNode(MDType.ListMark, cx.lineStart + line.pos, cx.lineStart + line.pos + size)
    line.moveBaseColumn(newBase)
    return .context
}

private func parseATXHeading(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    let size = mdIsAtxHeading(line)
    if size < 0 { return .no }
    let text = line.text
    let off = line.pos, from = cx.lineStart + off
    let endOfSpace = mdSkipSpaceBack(text, text.count, off)
    var after = endOfSpace
    while after > off && Int(text[after - 1]) == line.next { after -= 1 }
    if after == endOfSpace || after == off || !mdSpace(Int(text[after - 1])) { after = text.count }
    var children: [MDElt] = [MDElt(MDType.HeaderMark, from, from + size)]
    children.append(contentsOf: mdParseInline(mdSlice(text, off + size + 1, after), from + size + 1))
    if after < text.count {
        children.append(MDElt(MDType.HeaderMark, from + after - off, from + endOfSpace - off))
    }
    let node = MDElt(MDType.ATXHeading1 - 1 + size, from, from + text.count - off, children)
    cx.nextLine()
    cx.addNode(node)
    return .leaf
}

private func parseHTMLBlock(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    let type = mdIsHTMLBlock(line, false)
    if type < 0 { return .no }
    let from = cx.lineStart + line.pos, end = mdHTMLEnds[type]
    var marks: [MDElt] = []
    var trailing = end != .emptyLine
    while !mdHTMLEndMatches(end, line.text) && cx.nextLine() {
        if line.depth < cx.stack.count { trailing = false; break }
        for m in line.markers { marks.append(m) }
    }
    if trailing { cx.nextLine() }
    let nodeType = end == .commentEnd ? MDType.CommentBlock : end == .processingEnd ? MDType.ProcessingInstructionBlock : MDType.HTMLBlock
    let to = cx.prevLineEnd()
    cx.addNode(MDElt(nodeType, from, to, marks))
    return .leaf
}

// MARK: Frontmatter extension

private func isFrontmatterDelimiterLine(_ line: MDLine) -> Bool {
    if line.pos != 0 { return false }
    if !mdStarts(line.text, line.pos, "---") { return false }
    return line.skipSpace(line.pos + 3) == line.text.count
}

private func hasClosingDelimiterAhead(_ cx: MDBlockContext, _ afterPos: Int) -> Bool {
    // /(?:^|\n)---[ \t]*(?:\n|$)/ on input.slice(afterPos)
    let t = cx.input
    if afterPos > t.count { return false }
    var ls = afterPos
    while ls <= t.count {
        if mdStarts(t, ls, "---") {
            var p = ls + 3
            while p < t.count && (t[p] == 32 || t[p] == 9) { p += 1 }
            if p == t.count || t[p] == 10 { return true }
        }
        var n = ls
        while n < t.count && t[n] != 10 { n += 1 }
        if n >= t.count { break }
        ls = n + 1
    }
    return false
}

private func parseFrontmatter(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    if cx.lineStart != 0 || !isFrontmatterDelimiterLine(line) { return .no }
    if !hasClosingDelimiterAhead(cx, cx.lineStart + line.text.count + 1) { return .no }
    let from = cx.lineStart
    let openingDelimiterFrom = cx.lineStart + line.pos
    let openingLineEnd = cx.lineStart + line.text.count
    var elements = [MDElt(MDType.FrontmatterMark, openingDelimiterFrom, openingDelimiterFrom + 3)]
    while cx.nextLine() {
        if !isFrontmatterDelimiterLine(line) { continue }
        let closingDelimiterFrom = cx.lineStart + line.pos
        let contentFrom = openingLineEnd + 1
        let contentTo = closingDelimiterFrom - 1
        if contentFrom < contentTo {
            elements.append(MDElt(MDType.FrontmatterContent, contentFrom, contentTo))
        }
        elements.append(MDElt(MDType.FrontmatterMark, closingDelimiterFrom, closingDelimiterFrom + 3))
        cx.nextLine()
        cx.addElement(MDElt(MDType.Frontmatter, from, cx.prevLineEnd(), elements))
        return .leaf
    }
    return .no
}

// MARK: HTML block extensions (html-block-decorations.ts)

private func parseSelfClosingHTMLBlock(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    if line.ch(line.pos) != 60 { return .no }
    // /^\s*<[a-z][\w-]*(?:\s+[^>]*)?\s*\/\s*>\s*$/i on line.text
    let t = line.text
    var p = jsSkipSpace(t, 0)
    guard mdCh(t, p) == 60 else { return .no }
    p += 1
    guard isAsciiAlpha(mdCh(t, p)) else { return .no }
    p += 1
    while p < t.count && (jsWord(Int(t[p])) || t[p] == 45) { p += 1 }
    var gt = p
    while gt < t.count && t[gt] != 62 { gt += 1 }
    guard gt < t.count, jsSkipSpace(t, gt + 1) == t.count else { return .no }
    // Between tag name and '>': P + '/' + \s*, where P is empty or starts with \s.
    var s = gt
    while s > p && jsSpace(Int(t[s - 1])) { s -= 1 }
    guard s > p, t[s - 1] == 47 else { return .no }
    let slash = s - 1
    guard slash == p || jsSpace(Int(t[p])) else { return .no }
    let from = cx.lineStart + line.pos
    cx.nextLine()
    cx.addElement(MDElt(MDType.HTMLBlock, from, cx.prevLineEnd()))
    return .leaf
}

private func detailsEnd(_ t: MDText) -> Bool {
    // /<\/details\s*>/i
    var i = 0
    while i + 1 < t.count {
        if t[i] == 60 && t[i + 1] == 47 && mdStarts(t, i + 2, "details", caseInsensitive: true) {
            let p = jsSkipSpace(t, i + 9)
            if mdCh(t, p) == 62 { return true }
        }
        i += 1
    }
    return false
}

private func parseDetailsHTMLBlock(_ cx: MDBlockContext, _ line: MDLine) -> MDBlockResult {
    // /^\s*<details(?:\s|>|$)/i on line.text
    let t = line.text
    let p = jsSkipSpace(t, 0)
    guard mdStarts(t, p, "<details", caseInsensitive: true) else { return .no }
    let q = p + 8
    guard q == t.count || jsSpace(Int(t[q])) || t[q] == 62 else { return .no }
    let from = cx.lineStart + line.pos
    while !detailsEnd(line.text) && cx.nextLine() {}
    cx.nextLine()
    cx.addElement(MDElt(MDType.HTMLBlock, from, cx.prevLineEnd()))
    return .leaf
}

// MARK: - Leaf block parsers

enum MDParsed {
    case null
    case fail
    case elt(MDElt)
    var elt: MDElt? { if case .elt(let e) = self { return e }; return nil }
}

final class MDLinkReferenceParser: MDLeafBlockParser {
    // stage: -1 failed, 0 start, 1 label, 2 link, 3 title
    var stage = 0
    var elts: [MDElt] = []
    var pos = 0
    let start: Int

    init(_ leaf: MDLeafBlock) {
        start = leaf.start
        _ = advance(leaf.content)
    }

    func nextLine(_ cx: MDBlockContext, _ line: MDLine, _ leaf: MDLeafBlock) -> Bool {
        if stage == -1 { return false }
        let content = leaf.content + [10] + line.scrub()
        let finish = advance(content)
        if finish > -1 && finish < content.count { return complete(cx, leaf, finish) }
        return false
    }

    func finish(_ cx: MDBlockContext, _ leaf: MDLeafBlock) -> Bool {
        if (stage == 2 || stage == 3) && mdSkipSpace(leaf.content, pos) == leaf.content.count {
            return complete(cx, leaf, leaf.content.count)
        }
        return false
    }

    func complete(_ cx: MDBlockContext, _ leaf: MDLeafBlock, _ len: Int) -> Bool {
        cx.addLeafElement(leaf, MDElt(MDType.LinkReference, start, start + len, elts))
        return true
    }

    func nextStage(_ r: MDParsed) -> Bool {
        switch r {
        case .elt(let e):
            pos = e.to - start
            elts.append(e)
            stage += 1
            return true
        case .fail:
            stage = -1
            return false
        case .null:
            return false
        }
    }

    func advance(_ content: MDText) -> Int {
        while true {
            if stage == -1 {
                return -1
            } else if stage == 0 {
                if !nextStage(mdParseLinkLabel(content, pos, start, true)) { return -1 }
                if mdCh(content, pos) != 58 { stage = -1; return -1 }
                elts.append(MDElt(MDType.LinkMark, pos + start, pos + start + 1))
                pos += 1
            } else if stage == 1 {
                if !nextStage(mdParseURL(content, mdSkipSpace(content, pos), start)) { return -1 }
            } else if stage == 2 {
                let skip = mdSkipSpace(content, pos)
                var end = 0
                if skip > pos {
                    if let title = mdParseLinkTitle(content, skip, start).elt {
                        let titleEnd = mdLineEnd(content, title.to - start)
                        if titleEnd > 0 { _ = nextStage(.elt(title)); end = titleEnd }
                    }
                }
                if end == 0 { end = mdLineEnd(content, pos) }
                return end > 0 && end < content.count ? end : -1
            } else {
                return mdLineEnd(content, pos)
            }
        }
    }
}

func mdLineEnd(_ text: MDText, _ posIn: Int) -> Int {
    var pos = posIn
    while pos < text.count {
        let next = Int(text[pos])
        if next == 10 { break }
        if !mdSpace(next) { return -1 }
        pos += 1
    }
    return pos
}

final class MDSetextHeadingParser: MDLeafBlockParser {
    func nextLine(_ cx: MDBlockContext, _ line: MDLine, _ leaf: MDLeafBlock) -> Bool {
        let underline = line.depth < cx.stack.count ? -1 : mdIsSetextUnderline(line)
        let next = line.next
        if underline < 0 { return false }
        let underlineMark = MDElt(MDType.HeaderMark, cx.lineStart + line.pos, cx.lineStart + underline)
        cx.nextLine()
        var children = mdParseInline(leaf.content, leaf.start)
        children.append(underlineMark)
        cx.addLeafElement(leaf, MDElt(next == 61 ? MDType.SetextHeading1 : MDType.SetextHeading2, leaf.start, cx.prevLineEnd(), children))
        return true
    }

    func finish(_ cx: MDBlockContext, _ leaf: MDLeafBlock) -> Bool { false }
}

// MARK: GFM tables

/// Parse a line as a table row and return the cell count. When `elts` is
/// given, push syntax elements for the content onto it.
@discardableResult
func mdParseRow(_ line: MDText, _ startI: Int = 0, _ elts: UnsafeMutablePointer<[MDElt]>? = nil, _ offset: Int = 0) -> Int {
    var count = 0, first = true, cellStart = -1, cellEnd = -1, esc = false
    func parseCell() {
        elts!.pointee.append(MDElt(MDType.TableCell, offset + cellStart, offset + cellEnd,
                                   mdParseInline(mdSlice(line, cellStart, cellEnd), offset + cellStart)))
    }
    var i = startI
    while i < line.count {
        let next = Int(line[i])
        if next == 124 && !esc {
            if !first || cellStart > -1 { count += 1 }
            first = false
            if elts != nil {
                if cellStart > -1 { parseCell() }
                elts!.pointee.append(MDElt(MDType.TableDelimiter, i + offset, i + offset + 1))
            }
            cellStart = -1; cellEnd = -1
        } else if esc || (next != 32 && next != 9) {
            if cellStart < 0 { cellStart = i }
            cellEnd = i + 1
        }
        esc = !esc && next == 92
        i += 1
    }
    if cellStart > -1 {
        count += 1
        if elts != nil { parseCell() }
    }
    return count
}

func mdParseRowInto(_ line: MDText, _ startI: Int, _ elts: inout [MDElt], _ offset: Int) -> Int {
    withUnsafeMutablePointer(to: &elts) { mdParseRow(line, startI, $0, offset) }
}

func mdHasPipe(_ str: MDText, _ start: Int) -> Bool {
    var i = start
    while i < str.count {
        let next = str[i]
        if next == 124 { return true }
        if next == 92 { i += 1 }
        i += 1
    }
    return false
}

/// /^\|?(\s*:?-+:?\s*\|)+(\s*:?-+:?\s*)?$/
func mdDelimiterLine(_ t: MDText) -> Bool {
    var p = 0
    if mdCh(t, 0) == 124 { p = 1 }
    func cell(_ from: Int, _ to: Int) -> Bool {
        var a = from, b = to
        while a < b && jsSpace(Int(t[a])) { a += 1 }
        while b > a && jsSpace(Int(t[b - 1])) { b -= 1 }
        if a < b && t[a] == 58 { a += 1 }
        if b > a && t[b - 1] == 58 { b -= 1 }
        if a >= b { return false }
        for k in a..<b where t[k] != 45 { return false }
        return true
    }
    var groups = 0
    var segStart = p
    var i = p
    while i < t.count {
        if t[i] == 124 {
            if !cell(segStart, i) { return false }
            groups += 1
            segStart = i + 1
        }
        i += 1
    }
    if groups == 0 { return false }
    return segStart == t.count || cell(segStart, t.count)
}

final class MDTableParser: MDLeafBlockParser {
    // nil: haven't seen the second line; notTable: not a table; rows otherwise
    var state = 0 // 0 = null, 1 = false, 2 = rows
    var rows: [MDElt] = []

    func nextLine(_ cx: MDBlockContext, _ line: MDLine, _ leaf: MDLeafBlock) -> Bool {
        if state == 0 {
            state = 1
            if line.next == 45 || line.next == 58 || line.next == 124 {
                let lineText = mdSlice(line.text, line.pos, line.text.count)
                if mdDelimiterLine(lineText) {
                    var firstRow: [MDElt] = []
                    let firstCount = mdParseRowInto(leaf.content, 0, &firstRow, leaf.start)
                    if firstCount == mdParseRow(lineText, line.pos) {
                        rows = [MDElt(MDType.TableHeader, leaf.start, leaf.start + leaf.content.count, firstRow),
                                MDElt(MDType.TableDelimiter, cx.lineStart + line.pos, cx.lineStart + line.text.count)]
                        state = 2
                    }
                }
            }
        } else if state == 2 {
            var content: [MDElt] = []
            _ = mdParseRowInto(line.text, line.pos, &content, cx.lineStart)
            rows.append(MDElt(MDType.TableRow, cx.lineStart + line.pos, cx.lineStart + line.text.count, content))
        }
        return false
    }

    func finish(_ cx: MDBlockContext, _ leaf: MDLeafBlock) -> Bool {
        if state != 2 { return false }
        cx.addLeafElement(leaf, MDElt(MDType.Table, leaf.start, leaf.start + leaf.content.count, rows))
        return true
    }
}

final class MDTaskParser: MDLeafBlockParser {
    func nextLine(_ cx: MDBlockContext, _ line: MDLine, _ leaf: MDLeafBlock) -> Bool { false }

    func finish(_ cx: MDBlockContext, _ leaf: MDLeafBlock) -> Bool {
        var children = [MDElt(MDType.TaskMarker, leaf.start, leaf.start + 3)]
        children.append(contentsOf: mdParseInline(mdSlice(leaf.content, 3, leaf.content.count), leaf.start + 3))
        cx.addLeafElement(leaf, MDElt(MDType.Task, leaf.start, leaf.start + leaf.content.count, children))
        return true
    }
}

// MARK: - injectMarks

func mdInjectMarks(_ elements: [MDElt], _ marks: [MDElt]) -> [MDElt] {
    if marks.isEmpty { return elements }
    if elements.isEmpty { return marks }
    var elts = elements
    var eI = 0
    for mark in marks {
        while eI < elts.count && elts[eI].to < mark.to { eI += 1 }
        if eI < elts.count && elts[eI].from < mark.from {
            let e = elts[eI]
            elts[eI] = MDElt(e.type, e.from, e.to, mdInjectMarks(e.children, [mark]))
        } else {
            elts.insert(mark, at: eI)
            eI += 1
        }
    }
    return elts
}

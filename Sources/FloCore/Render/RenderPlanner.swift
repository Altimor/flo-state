import Foundation

/// Builds the live-preview RenderPlan for a state. Ports, in order:
/// syntax highlighting (lezer markdownHighlighting + prosemark styles),
/// heading-decorations.ts, list/index.ts decorations, hide/*.ts rules,
/// blockQuote.ts, codeFenceExtension.ts and the fold widgets.
public enum RenderPlanner {
    public struct Settings {
        public var headingSpaceBefore: Double = 0
        public var headingSpaceAfter: Double = 8
        public init() {}
    }

    /// Width of one list indent step in `ch` (LIST_UNIT_CH in list/index.ts).
    public static let listUnitCh: Double = 3

    public static func plan(_ state: EditorState) -> RenderPlan {
        var p = Planner(state: state, from: 0, to: state.doc.length)
        p.run()
        return p.finish()
    }

    /// Plan only [from, to) — both at line starts (or doc end) on top-level
    /// block boundaries, where planning is independent of the rest. Runs and
    /// widgets use document positions; `lines` holds the region's lines only.
    public static func plan(_ state: EditorState, from: Int, to: Int) -> RenderPlan {
        var p = Planner(state: state, from: from, to: to)
        p.run()
        return p.finish()
    }
}

/// An array window [base, base + count) addressed with absolute indices;
/// writes outside the window are dropped, reads return `fallback`.
struct Window<T> {
    let base: Int
    var items: [T]
    let fallback: T
    subscript(i: Int) -> T {
        get { i >= base && i < base + items.count ? items[i - base] : fallback }
        set { if i >= base && i < base + items.count { items[i - base] = newValue } }
    }
    var count: Int { items.count }
}

struct Planner {
    let state: EditorState
    let doc: Text
    let tree: SyntaxTree
    var styles: Window<CharStyle>
    var lines: Window<LineStyle>
    /// planned region [base, end) and its lines [firstLine, lastLine] (1-based)
    let base: Int, end: Int
    let firstLine: Int, lastLine: Int
    var widgets: [Widget] = []
    var revealedHashLines = Set<Int>()
    /// Line numbers touched by any selection range.
    let selectionLines: [(Int, Int)]

    init(state: EditorState, from: Int, to: Int) {
        self.state = state
        doc = state.doc
        tree = state.tree
        base = from; end = to
        firstLine = doc.lineAt(from).number
        lastLine = to >= doc.length ? doc.lines : max(firstLine, doc.lineAt(to).number - (doc.lineAt(to).from == to ? 1 : 0))
        styles = Window(base: from, items: Array(repeating: CharStyle(), count: max(0, to - from)), fallback: CharStyle())
        lines = Window(base: firstLine - 1, items: Array(repeating: LineStyle(), count: lastLine - firstLine + 1), fallback: LineStyle())
        selectionLines = state.selection.ranges.map { (state.doc.lineAt($0.from).number, state.doc.lineAt($0.to).number) }
    }

    // MARK: helpers

    func selectionSharesLine(_ from: Int, _ to: Int) -> Bool {
        let first = doc.lineAt(max(0, min(from, doc.length))).number
        let last = doc.lineAt(max(0, min(to, doc.length))).number
        return selectionLines.contains { $0.0 <= last && first <= $0.1 }
    }

    func selectionTouches(_ from: Int, _ to: Int) -> Bool {
        state.selection.ranges.contains { $0.from <= to && $0.to >= from }
    }

    mutating func apply(_ from: Int, _ to: Int, _ f: (inout CharStyle) -> Void) {
        let a = max(base, from), b = min(to, end)
        guard a < b else { return }
        styles.items.withUnsafeMutableBufferPointer { buf in
            for i in a..<b { f(&buf[i - base]) }
        }
    }

    func children(_ n: SyntaxNode, named: Set<String>) -> [SyntaxNode] {
        var out: [SyntaxNode] = []
        func walk(_ x: SyntaxNode) {
            for c in x.children {
                if named.contains(c.name) { out.append(c) }
                walk(c)
            }
        }
        walk(n)
        return out
    }

    // MARK: run

    mutating func run() {
        highlight()
        nestedHighlight()
        headingsAndLines()
        listDecorations()
        hideRules()
        foldWidgets()
        wikiLinks()
        tabs()
        blankLines()
    }

    // MARK: syntax highlighting (lezer markdownHighlighting + prosemark HighlightStyles)

    mutating func highlight() {
        // lezer highlightTree: each node's tags = inherited ("/...") tags from
        // ancestors + its own rule; each highlighter contributes its style for the
        // most specific tag. Inner nodes are applied after outer ones.
        func visit(_ n: SyntaxNode, inherited: [HTag]) {
            var tags = inherited
            var nextInherited = inherited
            if let (tag, inherit) = NodeTags.rules[n.name] {
                tags.append(tag)
                if inherit { nextInherited.append(tag) }
            }
            if tags.count > inherited.count || n === tree.root {
                let own = tags.last.map { [$0] } ?? []
                let fs: [(inout CharStyle) -> Void] = Highlighters.all.compactMap { h in own.first.flatMap { h.style(for: $0) } }
                if !fs.isEmpty {
                    // Only the node's own ranges not covered by children get "own"
                    // styling in lezer, but CSS inheritance makes the whole node
                    // range inherit; children re-apply their own on top.
                    apply(n.from, n.to) { st in
                        let parentColor = st.color
                        for f in fs { f(&st) }
                        if st.color == .inherit { st.color = parentColor == .inherit ? .text : parentColor }
                    }
                }
            }
            for c in n.children where c.to >= base && c.from <= end { visit(c, inherited: nextInherited) }
        }
        visit(tree.root, inherited: [])
    }

    /// parseFencedCode + the mermaid check: info starting with "mermaid", non-blank body.
    func mermaidBody(_ n: SyntaxNode) -> String? {
        var info = "", source = ""
        for c in n.children {
            if c.name == "CodeInfo" { info = doc.slice(c.from, c.to) }
            else if c.name == "CodeText" { source += doc.slice(c.from, c.to) }
        }
        guard !info.isEmpty, ParsedTable.jsTrim(info).lowercased().hasPrefix("mermaid") else { return nil }
        let body = ParsedTable.jsTrim(source)
        return body.isEmpty ? nil : body
    }

    // MARK: nested languages (lang-markdown parseCode: fenced code via
    // @codemirror/language-data, HTML blocks / tags / comments via lang-html)

    mutating func nestedHighlight() {
        tree.iterate(from: base, to: end, enter: { n, _ in
            switch n.name {
            case "FencedCode":
                guard mermaidBody(n) == nil, let info = n.children.first(where: { $0.name == "CodeInfo" }) else { return false }
                let texts = n.children.filter { $0.name == "CodeText" }
                guard let a = texts.first?.from, let b = texts.last?.to, b > a else { return false }
                highlightNested(kind: "code", info: doc.slice(info.from, info.to), from: a, to: b,
                                ranges: texts.map { ($0.from - a, $0.to - a) })
                return false
            case "Frontmatter":
                // frontmatter.ts: @lezer/yaml over FrontmatterContent
                for c in n.children where c.name == "FrontmatterContent" && c.to > c.from {
                    highlightNested(kind: "yaml", info: "", from: c.from, to: c.to, ranges: [(0, c.to - c.from)])
                }
                return false
            case "HTMLBlock", "HTMLTag", "CommentBlock":
                // leftOverSpace: the node minus its children
                var ranges: [(Int, Int)] = []
                var pos = n.from
                for c in n.children {
                    if c.from > pos { ranges.append((pos - n.from, c.from - n.from)) }
                    pos = c.to
                }
                if n.to > pos { ranges.append((pos - n.from, n.to - n.from)) }
                highlightNested(kind: "html", info: "", from: n.from, to: n.to, ranges: ranges)
                return false
            default:
                return true
            }
        })
    }

    mutating func highlightNested(kind: String, info: String, from: Int, to: Int, ranges: [(Int, Int)]) {
        let hl = CodeHighlighter.shared
        for span in hl.highlight(kind: kind, info: info, text: doc.slice(from, to), ranges: ranges) {
            apply(from + span.from, from + span.to) { hl.apply(span, to: &$0) }
        }
    }

    // MARK: headings (heading-decorations.ts) + fenced code / blockquote lines

    mutating func headingsAndLines() {
        tree.iterate(from: base, to: end, enter: { n, _ in
            if n.name.hasPrefix("ATXHeading") || n.name.hasPrefix("SetextHeading") {
                let level = Int(String(n.name.last!))!
                let line = doc.lineAt(n.from)
                lines[line.number - 1].kind = .heading(level: level)
                let color: ColorRole = level == 1 ? .heading1 : (level <= 3 ? .subheading : .text)
                apply(n.from, n.to) { st in
                    if st.color == .text { st.color = color }
                }
                if n.name.hasPrefix("ATXHeading"),
                   let mark = n.children.first, mark.name == "HeaderMark" {
                    let hashEnd = min(mark.to + 1, n.to)
                    let onLine = selectionSharesLine(n.from, n.to)
                    if onLine { revealedHashLines.insert(line.number) }
                    apply(n.from, hashEnd) { $0.hidden = .margin(visible: onLine); $0.color = .muted }
                }
                if n.name.hasPrefix("SetextHeading") {
                    // underline line
                    if let mark = n.children.last, mark.name == "HeaderMark" {
                        lines[doc.lineAt(mark.from).number - 1].kind = .setextUnderline
                    }
                }
                return false
            }
            if n.name == "FencedCode", mermaidBody(n) != nil { return false }
            if n.name == "FencedCode" || n.name == "Frontmatter" {
                let first = doc.lineAt(n.from).number, last = doc.lineAt(n.to).number
                for l in first...last {
                    lines[l - 1].kind = .fencedCode(first: l == first, last: l == last)
                }
                apply(doc.line(first).from, doc.line(last).to) { $0.mono = true }
            }
            if n.name == "InlineCode" {
                apply(n.from, n.to) { $0.mono = true; $0.codeBackground = true }
            }
            if n.name == "Blockquote" {
                let first = doc.lineAt(n.from).number, last = doc.lineAt(n.to).number
                for l in first...last { lines[l - 1].blockquoteDepth += 1 }
            }
            return true
        })
    }

    // MARK: lists (list/index.ts buildListDecorations)

    mutating func listDecorations() {
        tree.iterate(from: base, to: end, enter: { n, _ in
            guard n.name == "ListMark" else { return true }
            // trailing space/tab required
            guard let next = doc.char(at: n.to), next == 32 || next == 9 else { return false }
            let markText = doc.slice(n.from, n.to)
            let line = doc.lineAt(n.from)
            if markText.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil {
                lines[line.number - 1].kind = .orderedItem
                lines[line.number - 1].paddingLeftCh = RenderPlanner.listUnitCh
                lines[line.number - 1].textIndentCh = -3.4
                return false
            }
            guard markText.count == 1, "-+*".contains(markText) else { return false }
            var depth = -1
            var p = n.parent
            while let x = p { if x.name == "ListItem" { depth += 1 }; p = x.parent }
            depth = max(0, depth)
            // task?
            var prefixEnd = n.to + 1
            var task: TaskState? = nil
            if let item = n.parent, let idx = item.children.firstIndex(where: { $0 === n }),
               idx + 1 < item.children.count, item.children[idx + 1].name == "Task",
               let tm = item.children[idx + 1].children.first, tm.name == "TaskMarker",
               let after = doc.char(at: tm.to), after == 32 || after == 9 {
                let inner = doc.slice(tm.from + 1, tm.to - 1).lowercased()
                task = inner == "x" ? .checked : .unchecked
                prefixEnd = tm.to + 1
            }
            let prefixCh = Double(depth + 1) * RenderPlanner.listUnitCh
            lines[line.number - 1].kind = .listItem(depth: depth, task: task)
            lines[line.number - 1].paddingLeftCh = prefixCh
            lines[line.number - 1].textIndentCh = -prefixCh
            apply(line.from, prefixEnd) { $0.hidden = .transparent }
            if let t = task {
                widgets.append(Widget(from: line.from, to: prefixEnd, kind: .checkbox(depth: depth, checked: t == .checked),
                                      replaces: false, block: false))
            } else {
                widgets.append(Widget(from: line.from, to: prefixEnd, kind: .bullet(depth: depth), replaces: false, block: false))
            }
            return false
        })
    }

    // MARK: hide rules (hide/index.ts)

    mutating func hideRules() {
        tree.iterate(from: base, to: end, enter: { n, _ in
            switch n.name {
            case "StrongEmphasis", "Emphasis":
                if !selectionSharesLine(n.from, n.to) {
                    for m in children(n, named: ["EmphasisMark"]) { apply(m.from, m.to) { $0.hidden = .removed } }
                }
            case "InlineCode":
                if !selectionSharesLine(n.from, n.to) {
                    for m in children(n, named: ["CodeMark"]) { apply(m.from, m.to) { $0.hidden = .zeroSize } }
                }
            case "Link":
                if !selectionSharesLine(n.from, n.to) {
                    apply(n.from, n.to) { st in
                        if st.color == .text { st.color = .link }
                        st.underline = true; st.clickableLink = true
                    }
                    for m in children(n, named: ["LinkMark", "URL"]) { apply(m.from, m.to) { $0.hidden = .zeroSize } }
                }
            case "Strikethrough":
                if !selectionSharesLine(n.from, n.to) {
                    for m in children(n, named: ["StrikethroughMark"]) { apply(m.from, m.to) { $0.hidden = .removed } }
                }
            case "Escape":
                let zone = wordAt(n.from).flatMap { $0.1 > n.from + 1 ? $0 : nil }
                    ?? (doc.lineAt(n.from).from, doc.lineAt(n.from).to)
                if selectionSharesLine(zone.0, zone.1) { break }
                if selectionSharesLine(n.from, n.to) { break }
                for m in children(n, named: ["EscapeMark"]) { apply(m.from, m.to) { $0.hidden = .zeroSize } }
            case "FencedCode":
                if !selectionSharesLine(n.from, n.to) {
                    for m in children(n, named: ["CodeMark", "CodeInfo"]) { apply(m.from, m.to) { $0.hidden = .transparent } }
                }
            case "Blockquote":
                if !selectionSharesLine(n.from, n.to) {
                    for m in children(n, named: ["QuoteMark"]) { apply(m.from, m.to) { $0.hidden = .transparent } }
                }
            case let s where s.hasPrefix("SetextHeading"):
                if !selectionSharesLine(n.from, n.to) {
                    for m in children(n, named: ["HeaderMark"]) { apply(m.from, m.to) { $0.hidden = .removed } }
                }
            default: break
            }
            return true
        })
    }

    /// stateWORDAt: maximal run of non-whitespace around pos.
    func wordAt(_ pos: Int) -> (Int, Int)? {
        let line = doc.lineAt(pos)
        func ws(_ i: Int) -> Bool { let c = doc.units[i]; return c == 32 || c == 9 || c == 10 }
        var a = pos, b = pos
        while a > line.from && !ws(a - 1) { a -= 1 }
        while b < line.to && !ws(b) { b += 1 }
        return a < b ? (a, b) : nil
    }

    // MARK: fold widgets (fold/*.ts, table-decorations.ts) — reveal on selection touch

    mutating func replace(_ from: Int, _ to: Int, _ kind: WidgetKind, block: Bool = false) {
        apply(from, to) { $0.hidden = .removed }
        widgets.append(Widget(from: from, to: to, kind: kind, replaces: true, block: block))
    }

    static let altWidthRE = try! NSRegularExpression(pattern: #"\|\s*(\d{1,5})\s*$"#)

    mutating func foldWidgets() {
        tree.iterate(from: base, to: end, enter: { n, _ in
            let touched = selectionTouches(n.from, n.to)
            switch n.name {
            case "Emoji":
                if !touched, let e = EmojiTable.get(doc.slice(n.from + 1, n.to - 1)) { replace(n.from, n.to, .emoji(e)) }
            case "Dash":
                let count = n.to - n.from
                if !touched, count == 2 || count == 3 { replace(n.from, n.to, .dash(count == 2 ? "\u{2013}" : "\u{2014}")) }
            case "Image":
                // fold/image.ts: needs a URL child; block when alone on its line
                guard let url = n.children.first(where: { $0.name == "URL" }) else { break }
                let src = LinkPaths.normalizeMarkdownDestination(doc.slice(url.from, url.to))
                let line = doc.lineAt(n.from)
                let block = n.from == line.from && n.to == line.to
                let source = doc.slice(n.from, n.to) as NSString
                var alt = ""
                if source.hasPrefix("!["), let close = Optional(source.range(of: "]")), close.location != NSNotFound {
                    alt = source.substring(with: NSRange(location: 2, length: close.location - 2))
                }
                var width: Int? = nil
                if let m = Self.altWidthRE.firstMatch(in: alt, range: NSRange(location: 0, length: (alt as NSString).length)),
                   let w = Int((alt as NSString).substring(with: m.range(at: 1))), w > 0 {
                    width = w
                    alt = (alt as NSString).substring(to: m.range.location)
                }
                let kind = WidgetKind.image(src: src, alt: alt, width: width, block: block)
                if touched {
                    widgets.append(Widget(from: n.to, to: n.to, kind: kind, replaces: false, block: block))
                } else {
                    replace(n.from, n.to, kind, block: block)
                }
            case "FencedCode":
                // mermaid-decorations.ts: always replaced by the canvas (never revealed)
                if let body = mermaidBody(n) {
                    replace(n.from, n.to, .mermaid(source: body), block: true)
                    return false
                }
            case "Math":
                // math-decorations.ts: needs a non-blank MathFormula; `$$` = display
                guard !touched, let f = n.children.first(where: { $0.name == "MathFormula" }) else { break }
                let formula = doc.slice(f.from, f.to)
                if formula.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                let display = doc.slice(n.from, min(n.to, n.from + 2)) == "$$"
                replace(n.from, n.to, .math(source: formula, display: display))
                return false
            case "HTMLBlock":
                // html-block-decorations.ts: source while touched; <script>/<style> blocks and
                // blocks that sanitise to nothing keep their source
                guard !touched else { break }
                let text = doc.slice(n.from, n.to)
                let trimmed = text.drop { $0 == " " || $0 == "\t" || $0 == "\n" }.lowercased()
                if trimmed.range(of: #"^<(?:script|style)[\s>]"#, options: .regularExpression) != nil { break }
                if !HtmlSanitizeHint.renders(text) { break }
                replace(n.from, n.to, .htmlBlock(source: text), block: true)
                return false
            case "HorizontalRule":
                if !touched { replace(n.from, n.to, .horizontalRule, block: true) }
            case "Table":
                let first = doc.lineAt(n.from).number, last = doc.lineAt(n.to).number
                // parseMarkdownTable failing (bad delimiter row) → no decoration at all
                let source = doc.slice(n.from, n.to)
                guard ParsedTable.parse(source) != nil else { return true }
                if touched {
                    for l in first...last { lines[l - 1].kind = .tableSource(first: l == first, last: l == last) }
                    apply(doc.line(first).from, doc.line(last).to) { $0.mono = true }
                } else {
                    replace(n.from, n.to, .table(source: source), block: true)
                }
                return false
            default: break
            }
            return true
        })
    }

    // MARK: wiki links (wiki-link-extension.ts)

    static let wikiRE = try! NSRegularExpression(pattern: #"(!?)\[\[([^\]]+)\]\]"#)
    static let codeNodes: Set<String> = ["FencedCode", "InlineCode", "CodeBlock", "CodeText", "CodeInfo"]

    func insideCode(_ pos: Int) -> Bool {
        var inside = false
        tree.iterate(from: pos, to: pos, enter: { n, _ in
            if inside { return false }
            if Self.codeNodes.contains(n.name) { inside = true; return false }
            return true
        })
        return inside
    }

    mutating func wikiLinks() {
        let ns = doc.string as NSString
        for m in Self.wikiRE.matches(in: doc.string, range: NSRange(location: base, length: end - base)) {
            let bang = m.range(at: 1).length > 0
            let inner = ns.substring(with: m.range(at: 2))
            let embed = bang ? WikiLinks.imageEmbedTarget(inner) : nil
            let start = m.range.location + (bang && embed == nil ? 1 : 0)
            let end = m.range.location + m.range.length
            if insideCode(start) { continue }
            // inside a block widget (rendered table): the widget owns the text
            if widgets.contains(where: { $0.block && $0.replaces && $0.from <= start && end <= $0.to }) { continue }
            let cursorInside = state.selection.ranges.contains { $0.from >= start && $0.to <= end }
            if cursorInside {
                apply(start, end) { st in if st.color == .text { st.color = .link } }
            } else if let target = embed {
                replace(start, end, .wikiLink(display: target, resolvedImage: true))
            } else {
                replace(start, end, .wikiLink(display: WikiLinks.displayText(inner), resolvedImage: false))
            }
        }
    }

    mutating func tabs() {
        for i in base..<end where doc.units[i] == 9 {
            if styles[i].hidden == .removed { continue }
            replace(i, i + 1, .tab)
        }
    }

    mutating func blankLines() {
        for i in (firstLine - 1)..<lastLine {
            let l = doc.line(i + 1)
            if l.from == l.to, lines[i].kind == .paragraph { lines[i].kind = .blank }
        }
    }

    func finish() -> RenderPlan {
        var runs: [StyleRun] = []
        for (k, s) in styles.items.enumerated() {
            let i = base + k
            if let last = runs.last, last.style == s, last.to == i {
                runs[runs.count - 1].to = i + 1
            } else {
                runs.append(StyleRun(from: i, to: i + 1, style: s))
            }
        }
        let ws = widgets.filter { $0.from >= base && ($0.from < end || ($0.from == end && end == doc.length)) }
        return RenderPlan(runs: runs, lines: lines.items, widgets: ws,
                          lineNumbersWithRevealedHash: revealedHashLines.filter { $0 >= firstLine && $0 <= lastLine })
    }
}

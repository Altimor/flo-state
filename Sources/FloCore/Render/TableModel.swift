import Foundation

/// GFM table parsing and in-cell inline markdown, ported from
/// components/editor-area/table-decorations.ts.
public struct ParsedTable: Hashable {
    public enum Alignment: Hashable { case left, center, right }
    public var headers: [String]
    public var alignments: [Alignment?]
    public var rows: [[String]]

    /// parseMarkdownTable: nil when the delimiter row is invalid (no widget).
    public static func parse(_ text: String) -> ParsedTable? {
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let headers = parseCells(lines[0])
        let delim = parseCells(lines[1])
        guard delim.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) else { return nil }
        let aligns: [Alignment?] = delim.map { c in
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            if l && r { return .center }
            if r { return .right }
            if l { return .left }
            return nil
        }
        return ParsedTable(headers: headers, alignments: aligns, rows: lines.dropFirst(2).map(parseCells))
    }

    static func isEscaped(_ u: [UInt16], _ index: Int) -> Bool {
        var n = 0, i = index - 1
        while i >= 0 && u[i] == 92 { n += 1; i -= 1 }
        return n % 2 == 1
    }

    /// JS String.trim() whitespace (ASCII + Unicode spaces + line terminators).
    static func jsTrim(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    static func parseCells(_ line: String) -> [String] {
        let t = Array(jsTrim(line).utf16)
        let start = t.first == 124 ? 1 : 0
        let end = (t.last == 124 && !isEscaped(t, t.count - 1)) ? t.count - 1 : t.count
        var cells: [String] = []
        var cur: [UInt16] = []
        var escaped = false
        var i = start
        while i < end {
            let c = t[i]
            if c == 124 && !escaped {
                cells.append(jsTrim(String(utf16CodeUnits: cur, count: cur.count))); cur = []
            } else {
                cur.append(c)
            }
            escaped = !escaped && c == 92
            i += 1
        }
        cells.append(jsTrim(String(utf16CodeUnits: cur, count: cur.count)))
        return cells
    }
}

/// TableCellInlineNode.
public indirect enum CellInline: Hashable {
    public enum Tag: String, Hashable { case strong, em, code, s, span }
    case text(String)
    case lineBreak
    case element(tag: Tag, className: String?, href: String?, wikiTarget: String?, children: [CellInline])
}

public enum CellMarkdown {
    static let defaultHidden: Set<String> = ["CodeMark", "EmphasisMark", "EscapeMark", "LinkMark", "StrikethroughMark"]
    static let linkHidden: Set<String> = defaultHidden.union(["LinkLabel", "LinkTitle", "URL"])

    /// parseTableCellInlineMarkdown. The web parser adds a WikiLink inline
    /// syntax (before Link); here wiki spans are found first and masked with
    /// inert placeholder characters so the markdown parser treats them as
    /// atomic text, then turned back into wiki elements.
    public static func parse(_ markdown: String) -> [CellInline] {
        let units = Array(markdown.utf16)
        let wikis = wikiSpans(units)
        var masked = units
        for (a, b) in wikis { for i in a..<b { masked[i] = 0xE000 } }
        let tree = FloMarkdown.parse(units: masked)
        var r = Renderer(u: units, wikis: wikis)
        return r.node(tree.root)
    }

    /// `[[...]]` spans the WikiLink inline parser would claim: not inside code
    /// spans or autolinks, `\` skips the next char, closes at the first `]]`.
    static func wikiSpans(_ u: [UInt16]) -> [(Int, Int)] {
        guard u.count >= 4 else { return [] }
        let tree = FloMarkdown.parse(units: u)
        var blocked: [(Int, Int)] = []
        tree.iterate(enter: { n, _ in
            if n.name == "InlineCode" || n.name == "Autolink" || n.name == "URL" && n.parent?.name != "Link" && n.parent?.name != "Image" {
                blocked.append((n.from, n.to)); return false
            }
            return true
        })
        var out: [(Int, Int)] = []
        var pos = 0
        while pos < u.count - 1 {
            if let b = blocked.first(where: { $0.0 <= pos && pos < $0.1 }) { pos = b.1; continue }
            if u[pos] == 92 { pos += 2; continue }
            if u[pos] == 91 && u[pos + 1] == 91 {
                var end = pos + 2, found = -1
                while end < u.count - 1 {
                    if u[end] == 92 { end += 2; continue }
                    if u[end] == 93 && u[end + 1] == 93 { found = end; break }
                    end += 1
                }
                if found >= 0 { out.append((pos, found + 2)); pos = found + 2; continue }
            }
            pos += 1
        }
        return out
    }

    struct Renderer {
        let u: [UInt16]
        let wikis: [(Int, Int)]

        func slice(_ a: Int, _ b: Int) -> String { String(utf16CodeUnits: Array(u[max(0, a)..<min(u.count, b)]), count: min(u.count, b) - max(0, a)) }

        /// Text with wiki spans turned into elements.
        func text(_ a: Int, _ b: Int) -> [CellInline] {
            guard a < b else { return [] }
            var out: [CellInline] = []
            var p = a
            for (wa, wb) in wikis where wa >= a && wb <= b {
                if wa > p { push(&out, .text(slice(p, wa))) }
                let raw = slice(wa + 2, wb - 2)
                out.append(.element(tag: .span, className: "cm-wiki-link", href: nil, wikiTarget: raw,
                                    children: [.text(WikiLinks.displayText(raw))]))
                p = wb
            }
            if p < b { push(&out, .text(slice(p, b))) }
            return out
        }

        func push(_ nodes: inout [CellInline], _ n: CellInline) {
            if case .text(let t) = n {
                if t.isEmpty { return }
                if case .text(let prev)? = nodes.last { nodes[nodes.count - 1] = .text(prev + t); return }
            }
            nodes.append(n)
        }

        func children(_ n: SyntaxNode, hidden: Set<String> = CellMarkdown.defaultHidden) -> [CellInline] {
            var out: [CellInline] = []
            var pos = n.from
            for c in n.children {
                if c.from > pos { for x in text(pos, c.from) { push(&out, x) } }
                if !hidden.contains(c.name) { for x in node(c) { push(&out, x) } }
                pos = c.to
            }
            if n.to > pos { for x in text(pos, n.to) { push(&out, x) } }
            return out
        }

        func el(_ tag: CellInline.Tag, _ kids: [CellInline], cls: String? = nil, href: String? = nil) -> [CellInline] {
            [.element(tag: tag, className: cls, href: href, wikiTarget: nil, children: kids)]
        }

        func link(_ n: SyntaxNode) -> [CellInline] {
            var kids = children(n, hidden: CellMarkdown.linkHidden)
            let href = n.children.first { $0.name == "URL" }.map { ParsedTable.jsTrim(slice($0.from, $0.to)) }
            if kids.isEmpty, let h = href { push(&kids, .text(h)) }
            return el(.span, kids, cls: "cm-rendered-link", href: href)
        }

        func node(_ n: SyntaxNode) -> [CellInline] {
            switch n.name {
            case "Document", "Paragraph": return children(n)
            case "StrongEmphasis": return el(.strong, children(n))
            case "Emphasis": return el(.em, children(n))
            case "Strikethrough": return el(.s, children(n))
            case "InlineCode": return el(.code, children(n), cls: "cm-inline-code")
            case "Link", "Autolink": return link(n)
            case "URL":
                return el(.span, [.text(slice(n.from, n.to))], cls: "cm-rendered-link", href: slice(n.from, n.to))
            case "Image":
                let alt = children(n, hidden: CellMarkdown.linkHidden)
                return alt.isEmpty ? [.text(slice(n.from, n.to))] : alt
            case "Escape": return [.text(slice(n.from + 1, n.to))]
            case "Entity": return [.text(CellMarkdown.decodeEntity(slice(n.from, n.to)))]
            case "HardBreak": return [.lineBreak]
            case "Dash":
                let c = n.to - n.from
                return [.text(c == 2 ? "\u{2013}" : c == 3 ? "\u{2014}" : slice(n.from, n.to))]
            case "Emoji":
                return [.text(EmojiTable.get(slice(n.from + 1, n.to - 1)) ?? slice(n.from, n.to))]
            default:
                if !n.children.isEmpty { return children(n) }
                return text(n.from, n.to)
            }
        }
    }

    static func decodeEntity(_ e: String) -> String {
        func cp(_ v: Int?) -> String {
            guard let v = v, v >= 0, v <= 0x10FFFF, let s = Unicode.Scalar(v) else { return e }
            return String(Character(s))
        }
        if e.hasPrefix("&#x") || e.hasPrefix("&#X") { return cp(Int(e.dropFirst(3).dropLast(), radix: 16)) }
        if e.hasPrefix("&#") { return cp(Int(e.dropFirst(2).dropLast())) }
        switch e {
        case "&amp;": return "&"
        case "&apos;": return "'"
        case "&gt;": return ">"
        case "&lt;": return "<"
        case "&nbsp;": return "\u{00A0}"
        case "&quot;": return "\""
        default: return e
        }
    }
}

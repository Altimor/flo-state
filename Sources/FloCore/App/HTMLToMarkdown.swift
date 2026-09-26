import Foundation

/// Minimal HTML DOM for clipboard fragments (what `DOMParser` would build for
/// the tags clipboards carry: implied `</p>`, `</li>`, `</td>` etc., void and
/// raw-text elements, entities).
final class HTMLNode {
    enum Kind { case element, text }
    let kind: Kind
    let tagName: String          // uppercase for elements
    var attributes: [String: String] = [:]
    var text: String = ""
    var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    init(element tag: String) { kind = .element; tagName = tag.uppercased() }
    init(text: String) { kind = .text; tagName = "#text"; self.text = text }

    func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    var isElement: Bool { kind == .element }
    var elementChildren: [HTMLNode] { children.filter { $0.isElement } }
    var parentElement: HTMLNode? { parent?.tagName == "#document" ? nil : parent }

    var textContent: String {
        if kind == .text { return text }
        return children.map { $0.textContent }.joined()
    }

    func attr(_ name: String) -> String? { attributes[name.lowercased()] }

    /// Descendants in document order matching `pred`.
    func descendants(where pred: (HTMLNode) -> Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        for c in children where c.isElement {
            if pred(c) { out.append(c) }
            out.append(contentsOf: c.descendants(where: pred))
        }
        return out
    }

    func firstDescendant(where pred: (HTMLNode) -> Bool) -> HTMLNode? {
        for c in children where c.isElement {
            if pred(c) { return c }
            if let d = c.firstDescendant(where: pred) { return d }
        }
        return nil
    }

    func remove() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        parent = nil
    }
}

enum HTMLParser {
    static let voidElements: Set<String> = ["AREA", "BASE", "BR", "COL", "EMBED", "HR", "IMG", "INPUT", "LINK", "META", "PARAM", "SOURCE", "TRACK", "WBR"]
    static let rawTextElements: Set<String> = ["SCRIPT", "STYLE", "TEXTAREA", "TITLE", "NOSCRIPT"]
    /// Start tags that close an open `<p>`.
    static let closesP: Set<String> = ["ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "CENTER", "DETAILS", "DIALOG", "DIR", "DIV", "DL", "FIELDSET",
        "FIGCAPTION", "FIGURE", "FOOTER", "FORM", "H1", "H2", "H3", "H4", "H5", "H6", "HEADER", "HGROUP", "HR", "LI", "DD", "DT", "MAIN",
        "MENU", "NAV", "OL", "P", "PRE", "SECTION", "SUMMARY", "TABLE", "UL", "LISTING", "PLAINTEXT", "XMP"]
    static let headings: Set<String> = ["H1", "H2", "H3", "H4", "H5", "H6"]
    static let formatting: Set<String> = ["A", "B", "BIG", "CODE", "EM", "FONT", "I", "NOBR", "S", "SMALL", "STRIKE", "STRONG", "TT", "U"]

    static func parse(_ html: String) -> HTMLNode {
        let document = HTMLNode(element: "#document")
        let body = HTMLNode(element: "BODY")
        document.append(body)
        var stack: [HTMLNode] = [body]
        var current: HTMLNode { stack.last! }
        let chars = Array(html.unicodeScalars)
        var i = 0
        var textBuf = ""
        var skipNextNewline = false

        func flushText() {
            guard !textBuf.isEmpty else { return }
            var t = decodeEntities(textBuf)
            textBuf = ""
            if skipNextNewline {
                skipNextNewline = false
                if t.hasPrefix("\n") { t.removeFirst() }
                if t.isEmpty { return }
            }
            if let last = current.children.last, last.kind == .text { last.text += t } else { current.append(HTMLNode(text: t)) }
        }

        func inScope(_ tag: String, boundary: Set<String> = ["TABLE", "TD", "TH", "HTML", "BODY"]) -> Int? {
            for idx in stride(from: stack.count - 1, through: 1, by: -1) {
                if stack[idx].tagName == tag { return idx }
                if boundary.contains(stack[idx].tagName) { return nil }
            }
            return nil
        }

        func closeP() {
            if let idx = inScope("P", boundary: ["TABLE", "TD", "TH", "HTML", "BODY", "BUTTON"]) { stack.removeSubrange(idx...) }
        }

        func popTo(_ idx: Int) { stack.removeSubrange(idx...) }

        func handleStart(_ tag: String, _ attrs: [String: String], _ selfClosing: Bool) {
            if tag == "HTML" || tag == "BODY" || tag == "HEAD" { return }
            if closesP.contains(tag) { closeP() }
            if headings.contains(tag), headings.contains(current.tagName) { stack.removeLast() }
            if tag == "LI" {
                for idx in stride(from: stack.count - 1, through: 1, by: -1) {
                    let t = stack[idx].tagName
                    if t == "LI" { popTo(idx); break }
                    if t == "UL" || t == "OL" || !(t == "P" || t == "DIV" || t == "ADDRESS") && !formatting.contains(t) && t != "SPAN" { break }
                }
            }
            if tag == "DD" || tag == "DT" {
                for idx in stride(from: stack.count - 1, through: 1, by: -1) {
                    let t = stack[idx].tagName
                    if t == "DD" || t == "DT" { popTo(idx); break }
                    if t == "DL" { break }
                }
            }
            if tag == "TR" {
                if let idx = inScope("TR", boundary: ["TABLE", "HTML", "BODY"]) { popTo(idx) }
            }
            if tag == "TD" || tag == "TH" {
                if let idx = inScope("TD", boundary: ["TR", "TABLE", "HTML", "BODY"]) { popTo(idx) }
                else if let idx = inScope("TH", boundary: ["TR", "TABLE", "HTML", "BODY"]) { popTo(idx) }
            }
            if tag == "THEAD" || tag == "TBODY" || tag == "TFOOT" {
                for t in ["TR", "THEAD", "TBODY", "TFOOT"] {
                    if let idx = inScope(t, boundary: ["TABLE", "HTML", "BODY"]) { popTo(idx) }
                }
            }
            if tag == "OPTION", current.tagName == "OPTION" { stack.removeLast() }
            let el = HTMLNode(element: tag)
            el.attributes = attrs
            current.append(el)
            if voidElements.contains(tag) { return }
            _ = selfClosing // foreign self-closing syntax is ignored for HTML elements
            stack.append(el)
            if tag == "PRE" || tag == "LISTING" || tag == "TEXTAREA" { skipNextNewline = true }
        }

        func handleEnd(_ tag: String) {
            if tag == "BODY" || tag == "HTML" || tag == "HEAD" { return }
            if tag == "P" {
                if let idx = inScope("P", boundary: ["TABLE", "TD", "TH", "HTML", "BODY", "BUTTON"]) { popTo(idx) }
                else { current.append(HTMLNode(element: "P")) }
                return
            }
            if tag == "BR" { current.append(HTMLNode(element: "BR")); return }
            if headings.contains(tag) {
                for idx in stride(from: stack.count - 1, through: 1, by: -1) where headings.contains(stack[idx].tagName) {
                    popTo(idx); return
                }
                return
            }
            for idx in stride(from: stack.count - 1, through: 1, by: -1) where stack[idx].tagName == tag {
                popTo(idx); return
            }
        }

        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                // Comment / doctype / processing
                if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                    flushText()
                    var j = i + 4
                    while j + 2 < chars.count && !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                    i = min(chars.count, j + 3)
                    continue
                }
                if i + 1 < chars.count, chars[i + 1] == "!" || chars[i + 1] == "?" {
                    flushText()
                    var j = i + 2
                    while j < chars.count && chars[j] != ">" { j += 1 }
                    i = j + 1
                    continue
                }
                let isEnd = i + 1 < chars.count && chars[i + 1] == "/"
                var j = i + (isEnd ? 2 : 1)
                guard j < chars.count, chars[j].properties.isAlphabetic else {
                    textBuf.unicodeScalars.append(c)
                    i += 1
                    continue
                }
                var name = ""
                while j < chars.count, !(chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" || chars[j] == "\r" || chars[j] == "\u{0C}" || chars[j] == "/" || chars[j] == ">") {
                    name.unicodeScalars.append(chars[j]); j += 1
                }
                // Attributes
                var attrs: [String: String] = [:]
                var selfClosing = false
                while j < chars.count && chars[j] != ">" {
                    let ch = chars[j]
                    if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{0C}" { j += 1; continue }
                    if ch == "/" { selfClosing = true; j += 1; continue }
                    var an = ""
                    while j < chars.count, !(" \t\n\r\u{0C}/>=".unicodeScalars.contains(chars[j])) { an.unicodeScalars.append(chars[j]); j += 1 }
                    while j < chars.count, " \t\n\r".unicodeScalars.contains(chars[j]) { j += 1 }
                    var av = ""
                    if j < chars.count, chars[j] == "=" {
                        j += 1
                        while j < chars.count, " \t\n\r".unicodeScalars.contains(chars[j]) { j += 1 }
                        if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
                            let q = chars[j]; j += 1
                            while j < chars.count, chars[j] != q { av.unicodeScalars.append(chars[j]); j += 1 }
                            j += 1
                        } else {
                            while j < chars.count, !(" \t\n\r\u{0C}>".unicodeScalars.contains(chars[j])) { av.unicodeScalars.append(chars[j]); j += 1 }
                        }
                    }
                    let key = an.lowercased()
                    if !key.isEmpty && attrs[key] == nil { attrs[key] = decodeEntities(av) }
                }
                i = j + 1
                flushText()
                let tag = name.uppercased()
                if isEnd {
                    handleEnd(tag)
                } else {
                    handleStart(tag, attrs, selfClosing)
                    if rawTextElements.contains(tag) {
                        // Raw text until the matching end tag.
                        let endTag = Array("</\(tag.lowercased())".unicodeScalars)
                        var k = i
                        var found = chars.count
                        while k < chars.count {
                            if chars[k] == "<", k + endTag.count <= chars.count,
                               String(String.UnicodeScalarView(chars[k..<k + endTag.count])).lowercased() == String(String.UnicodeScalarView(endTag)) {
                                found = k; break
                            }
                            k += 1
                        }
                        let raw = String(String.UnicodeScalarView(chars[i..<found]))
                        if !raw.isEmpty { current.append(HTMLNode(text: tag == "TEXTAREA" || tag == "TITLE" ? decodeEntities(raw) : raw)) }
                        var close = found
                        while close < chars.count && chars[close] != ">" { close += 1 }
                        i = min(chars.count, close + 1)
                        handleEnd(tag)
                    }
                }
                continue
            }
            textBuf.unicodeScalars.append(c)
            i += 1
        }
        flushText()
        return body
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "hellip": "…", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "harr": "↔", "rArr": "⇒", "lArr": "⇐", "hArr": "⇔", "frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³",
        "iexcl": "¡", "iquest": "¿", "shy": "\u{AD}", "micro": "µ", "prime": "′", "Prime": "″", "infin": "∞", "ne": "≠",
        "le": "≤", "ge": "≥", "minus": "−", "check": "✓", "star": "☆", "hearts": "♥", "dagger": "†", "Dagger": "‡",
        "eacute": "é", "Eacute": "É", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â",
        "auml": "ä", "atilde": "ã", "aring": "å", "aelig": "æ", "ccedil": "ç", "iacute": "í", "igrave": "ì", "icirc": "î",
        "iuml": "ï", "ntilde": "ñ", "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "otilde": "õ", "oslash": "ø",
        "uacute": "ú", "ugrave": "ù", "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ", "szlig": "ß",
        "Agrave": "À", "Aacute": "Á", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "Ccedil": "Ç", "Ntilde": "Ñ",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "&" {
                var j = i + 1
                var name = ""
                while j < chars.count, j - i <= 32, chars[j] != ";", chars[j].isLetter || chars[j].isNumber || chars[j] == "#" { name.append(chars[j]); j += 1 }
                let hasSemi = j < chars.count && chars[j] == ";"
                if name.hasPrefix("#") {
                    let body = name.dropFirst()
                    let v: UInt32? = (body.first == "x" || body.first == "X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                    if let v = v {
                        let scalar = (v == 0 || v > 0x10FFFF || (0xD800...0xDFFF).contains(v)) ? "\u{FFFD}" : Unicode.Scalar(v).map(String.init) ?? "\u{FFFD}"
                        out += scalar
                        i = hasSemi ? j + 1 : j
                        continue
                    }
                } else if let rep = namedEntities[name], hasSemi || ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"].contains(name) {
                    out += rep
                    i = hasSemi ? j + 1 : j
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}

/// Port of `html-to-markdown.ts`: converts the `text/html` clipboard flavour
/// into the editor's markdown conventions.
public enum HTMLToMarkdown {
    static let droppedTags: Set<String> = ["SCRIPT", "STYLE", "NOSCRIPT", "HEAD", "META", "LINK", "TITLE"]
    static let indent = "  "

    struct ListContext { let ordered: Bool; let index: Double; let depth: Int }

    /// Escapes characters that would read back as markdown syntax.
    static func escapeText(_ text: String) -> String {
        var s = AppRegex.replace(text, #"([\\`*_])"#, #"\\$1"#)
        s = AppRegex.replace(s, #"\[([^\]]*)\](?=[(\[])"#, #"\\[$1\\]"#)
        s = AppRegex.replace(s, "^(\(AppRegex.ws)*)([#>])", #"$1\\$2"#, multiline: true)
        s = AppRegex.replace(s, "^(\(AppRegex.ws)*)([0-9]+)\\.(\(AppRegex.ws))", #"$1$2\\.$3"#, multiline: true)
        return s
    }

    static func collapseWhitespace(_ text: String) -> String {
        AppRegex.replace(text, "[\\t\\n\\r ]+", " ")
    }

    static func renderInline(_ node: HTMLNode) -> String {
        AppRegex.trim(AppRegex.replace(renderChildren(node, nil), "\(AppRegex.ws)*\n+\(AppRegex.ws)*", " "))
    }

    static func renderChildren(_ node: HTMLNode, _ list: ListContext?) -> String {
        node.children.map { renderNode($0, list) }.joined()
    }

    static func renderList(_ el: HTMLNode, _ parent: ListContext?) -> String {
        let ordered = el.tagName == "OL"
        let depth = parent.map { $0.depth + 1 } ?? 0
        let start = JSNumber.parse(el.attr("start") ?? "1")
        let items = el.elementChildren.filter { $0.tagName == "LI" }
        let lines: [String] = items.enumerated().map { i, li in
            let ctx = ListContext(ordered: ordered, index: start + Double(i), depth: depth)
            let marker = ordered ? "\(JSNumber.toString(ctx.index)). " : "- "
            let ind = String(repeating: indent, count: depth)
            var nested: [String] = []
            var own = ""
            for child in li.children {
                if child.isElement && (child.tagName == "UL" || child.tagName == "OL") {
                    nested.append(renderList(child, ctx))
                } else {
                    own += renderNode(child, ctx)
                }
            }
            let checkbox = li.elementChildren.first { $0.tagName == "INPUT" && $0.attr("type")?.lowercased() == "checkbox" }
            let task = checkbox.map { $0.attr("checked") != nil ? "[x] " : "[ ] " } ?? ""
            let label = AppRegex.trim(AppRegex.replace(own, "\(AppRegex.ws)*\n+\(AppRegex.ws)*", " "))
            let head = "\(ind)\(marker)\(task)\(label)"
            return nested.isEmpty ? head : ([head] + nested).joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }

    static func renderTable(_ el: HTMLNode) -> String {
        let rows = el.descendants { $0.tagName == "TR" }
        if rows.isEmpty { return "" }
        let grid: [[String]] = rows.map { row in
            row.descendants { $0.tagName == "TH" || $0.tagName == "TD" }.map { renderInline($0).replacingOccurrences(of: "|", with: "\\|") }
        }
        let width = grid.map { $0.count }.max() ?? 0
        if width == 0 { return "" }
        func pad(_ row: [String]) -> String {
            var filled = row
            while filled.count < width { filled.append("") }
            return "| \(filled.joined(separator: " | ")) |"
        }
        let hasHeader = rows[0].firstDescendant { $0.tagName == "TH" } != nil
        let header = hasHeader ? grid[0] : Array(repeating: "", count: width)
        let body = hasHeader ? Array(grid.dropFirst()) : grid
        return ([pad(header), "| \(Array(repeating: "---", count: width).joined(separator: " | ")) |"] + body.map(pad)).joined(separator: "\n")
    }

    static func renderNode(_ node: HTMLNode, _ list: ListContext?) -> String {
        if node.kind == .text { return escapeText(collapseWhitespace(node.text)) }
        if droppedTags.contains(node.tagName) { return "" }
        let el = node
        switch el.tagName {
        case "BR":
            return "  \n"
        case "HR":
            return "\n\n---\n\n"
        case "H1", "H2", "H3", "H4", "H5", "H6":
            let level = Int(String(el.tagName.last!))!
            let text = renderInline(el)
            return text.isEmpty ? "" : "\n\n\(String(repeating: "#", count: level)) \(text)\n\n"
        case "STRONG", "B":
            let text = AppRegex.trim(renderChildren(el, list))
            return text.isEmpty ? "" : "**\(text)**"
        case "EM", "I":
            let text = AppRegex.trim(renderChildren(el, list))
            return text.isEmpty ? "" : "*\(text)*"
        case "DEL", "S", "STRIKE":
            let text = AppRegex.trim(renderChildren(el, list))
            return text.isEmpty ? "" : "~~\(text)~~"
        case "CODE":
            if el.parentElement?.tagName == "PRE" { return el.textContent }
            let text = AppRegex.trim(el.textContent)
            if text.isEmpty { return "" }
            let longest = AppRegex.matches(text, "`+").map { $0.range.length }.max() ?? 0
            let fence = String(repeating: "`", count: longest + 1)
            let padded = (text.hasPrefix("`") || text.hasSuffix("`")) ? " \(text) " : text
            return "\(fence)\(padded)\(fence)"
        case "PRE":
            var text = el.textContent
            if text.hasSuffix("\n") { text.removeLast() }
            if AppRegex.trim(text).isEmpty { return "" }
            let classes = "\(el.attr("class") ?? "") \(el.firstDescendant { $0.tagName == "CODE" }?.attr("class") ?? "")"
            let lang = AppRegex.firstMatch(classes, #"language-([A-Za-z0-9_]+)"#)?[1] ?? ""
            return "\n\n```\(lang)\n\(text)\n```\n\n"
        case "A":
            let text = AppRegex.trim(renderChildren(el, list))
            let href = el.attr("href") ?? ""
            if text.isEmpty { return "" }
            if href.isEmpty || href.hasPrefix("javascript:") { return text }
            return "[\(text)](\(href))"
        case "IMG":
            let src = el.attr("src") ?? ""
            if src.isEmpty { return "" }
            return "![\(el.attr("alt") ?? "")](\(src))"
        case "BLOCKQUOTE":
            let inner = AppRegex.trim(renderChildren(el, list))
            if inner.isEmpty { return "" }
            let quoted = inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
            return "\n\n\(quoted)\n\n"
        case "UL", "OL":
            return "\n\n\(renderList(el, list))\n\n"
        case "LI":
            let text = renderInline(el)
            return text.isEmpty ? "" : "\n- \(text)"
        case "TABLE":
            let table = renderTable(el)
            return table.isEmpty ? "" : "\n\n\(table)\n\n"
        case "P", "DIV", "SECTION", "ARTICLE":
            let inner = renderChildren(el, list)
            let t = AppRegex.trim(inner)
            return t.isEmpty ? "" : "\n\n\(t)\n\n"
        default:
            return renderChildren(el, list)
        }
    }

    static func tidy(_ markdown: String) -> String {
        // [ \t]+$ per line, keeping exactly-two-space hard breaks.
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            var end = line.endIndex
            while end > line.startIndex, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" {
                end = line.index(before: end)
            }
            let run = line[end...]
            if run.isEmpty || run == "  " { return line }
            return String(line[..<end])
        }
        var s = lines.joined(separator: "\n")
        s = AppRegex.replace(s, "\n{3,}", "\n\n")
        return AppRegex.replace(s, "^\(AppRegex.ws)+|\(AppRegex.ws)+$", "")
    }

    /// Converts an HTML fragment; empty string when nothing usable remains.
    public static func convert(_ html: String) -> String {
        let body = HTMLParser.parse(html)
        for el in body.descendants(where: { droppedTags.contains($0.tagName) }) { el.remove() }
        return tidy(renderChildren(body, nil))
    }

    /// Only convert when the HTML carries structure or emphasis.
    public static func isWorthConverting(_ html: String) -> Bool {
        let re = try! NSRegularExpression(pattern: "<\(AppRegex.ws)*(strong|b|em|i|del|s|strike|code|pre|a|img|h[1-6]|ul|ol|li|blockquote|table|hr)\\b", options: [.caseInsensitive])
        return re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) != nil
    }
}

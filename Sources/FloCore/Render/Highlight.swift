import Foundation

/// A port of the parts of @lezer/highlight the editor uses: tags with parent
/// chains, `styleTags` node rules (with "/..." inheritance) and HighlightStyles
/// that match a tag or its nearest styled ancestor tag.
final class HTag: Hashable {
    let name: String
    let parent: HTag?
    init(_ name: String, _ parent: HTag? = nil) {
        self.name = name
        self.parent = parent
    }
    static func == (a: HTag, b: HTag) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
    var chain: [HTag] { var out: [HTag] = []; var t: HTag? = self; while let x = t { out.append(x); t = x.parent }; return out }
}

enum T {
    // lezer standard tags (subset with the real parent relations)
    static let comment = HTag("comment")
    static let name = HTag("name")
    static let typeName = HTag("typeName", name)
    static let tagName = HTag("tagName", typeName)
    static let propertyName = HTag("propertyName", name)
    static let attributeName = HTag("attributeName", propertyName)
    static let className = HTag("className", name)
    static let labelName = HTag("labelName", name)
    static let namespace = HTag("namespace", name)
    static let macroName = HTag("macroName", name)
    static let variableName = HTag("variableName", name)
    static let literal = HTag("literal")
    static let string = HTag("string", literal)
    static let character = HTag("character", string)
    static let attributeValue = HTag("attributeValue", string)
    static let number = HTag("number", literal)
    static let bool = HTag("bool", literal)
    static let regexp = HTag("regexp", literal)
    static let escape = HTag("escape", literal)
    static let url = HTag("url", literal)
    static let keyword = HTag("keyword")
    static let atom = HTag("atom")
    static let content = HTag("content")
    static let heading = HTag("heading", content)
    static let heading1 = HTag("heading1", heading)
    static let heading2 = HTag("heading2", heading)
    static let heading3 = HTag("heading3", heading)
    static let heading4 = HTag("heading4", heading)
    static let heading5 = HTag("heading5", heading)
    static let heading6 = HTag("heading6", heading)
    static let contentSeparator = HTag("contentSeparator", content)
    static let list = HTag("list", content)
    static let quote = HTag("quote", content)
    static let emphasis = HTag("emphasis", content)
    static let strong = HTag("strong", content)
    static let link = HTag("link", content)
    static let monospace = HTag("monospace", content)
    static let strikethrough = HTag("strikethrough", content)
    static let invalid = HTag("invalid")
    static let meta = HTag("meta")
    static let processingInstruction = HTag("processingInstruction", meta)
    static let punctuation = HTag("punctuation")
    static let angleBracket = HTag("angleBracket", punctuation)
    // prosemark's Tag.define() tags: no parent
    static let headerMark = HTag("pm.headerMark")
    static let fencedCode = HTag("pm.fencedCode")
    static let linkURL = HTag("pm.linkURL")
    static let escapeMark = HTag("pm.escapeMark")
    static let emoji = HTag("pm.emoji")
    static let emojiMark = HTag("pm.emojiMark")
    static let listMark = HTag("pm.listMark")
    static let dash = HTag("pm.dash")
    static let mathDelimiter = HTag("pm.mathDelimiter")
    static let mathFormula = HTag("pm.mathFormula")
}

/// Node name -> (tag, inheritsToDescendants). Last writer wins, like `extend`.
enum NodeTags {
    static let rules: [String: (HTag, Bool)] = {
        var r: [String: (HTag, Bool)] = [:]
        func set(_ names: String, _ tag: HTag, inherit: Bool = false) {
            for n in names.split(separator: " ") { r[String(n)] = (tag, inherit) }
        }
        // @lezer/markdown markdownHighlighting
        set("Blockquote", T.quote, inherit: true)
        set("HorizontalRule", T.contentSeparator)
        set("ATXHeading1 SetextHeading1", T.heading1, inherit: true)
        set("ATXHeading2 SetextHeading2", T.heading2, inherit: true)
        set("ATXHeading3", T.heading3, inherit: true)
        set("ATXHeading4", T.heading4, inherit: true)
        set("ATXHeading5", T.heading5, inherit: true)
        set("ATXHeading6", T.heading6, inherit: true)
        set("Comment CommentBlock", T.comment)
        set("Escape", T.escape)
        set("Entity", T.character)
        set("Emphasis", T.emphasis, inherit: true)
        set("StrongEmphasis", T.strong, inherit: true)
        set("Link Image", T.link, inherit: true)
        set("OrderedList BulletList", T.list, inherit: true)
        set("InlineCode CodeText", T.monospace)
        set("URL Autolink", T.url)
        set("HeaderMark HardBreak QuoteMark ListMark LinkMark EmphasisMark CodeMark", T.processingInstruction)
        set("CodeInfo LinkLabel", T.labelName)
        set("LinkTitle", T.string)
        set("Paragraph", T.content)
        // GFM
        set("Strikethrough", T.strikethrough, inherit: true)
        set("StrikethroughMark TableDelimiter", T.processingInstruction)
        set("TableHeader", T.heading, inherit: true)
        set("TableCell", T.content)
        set("Task", T.list)
        set("TaskMarker", T.atom)
        // prosemark overrides (additionalMarkdownSyntaxTags, emoji, dash, escape, math)
        set("HeaderMark", T.headerMark)
        set("FencedCode", T.fencedCode)
        set("URL", T.linkURL)
        set("ListMark", T.listMark)
        set("EscapeMark", T.escapeMark)
        set("Emoji", T.emoji)
        set("EmojiMark", T.emojiMark)
        set("Dash", T.dash)
        set("MathMark", T.mathDelimiter)
        set("MathFormula", T.mathFormula)
        return r
    }()
}

/// One HighlightStyle: tag -> style mutation.
struct HighlightStyle {
    let rules: [HTag: (inout CharStyle) -> Void]
    func style(for tag: HTag) -> ((inout CharStyle) -> Void)? {
        for t in tag.chain { if let f = rules[t] { return f } }
        return nil
    }
}

enum Highlighters {
    /// prosemark baseSyntaxHighlights
    static let base = HighlightStyle(rules: [
        T.heading1: { $0.sizeEm = 1.6; $0.weight = 700 },
        T.heading2: { $0.sizeEm = 1.4; $0.weight = 700 },
        T.heading3: { $0.sizeEm = 1.2; $0.weight = 700 },
        T.heading4: { $0.weight = 700 },
        T.heading5: { $0.weight = 700 },
        T.heading6: { $0.weight = 700 },
        T.headerMark: { $0.color = .muted; $0.opacity = 0.4 },
        T.strong: { $0.weight = 700 },
        T.emphasis: { $0.italic = true },
        T.strikethrough: { $0.strike = true; $0.color = .muted },
        T.meta: { $0.color = .muted },
        T.comment: { $0.color = .muted },
        T.listMark: { $0.color = .muted; $0.paddingLeftCh = 1 },
        T.escapeMark: { $0.color = .inherit },
        T.linkURL: { $0.color = .link; $0.underline = true; $0.clickableLink = true },
        T.mathDelimiter: { $0.color = .muted },
        T.mathFormula: { $0.mono = true },
    ])
    /// prosemark generalSyntaxHighlights
    static let general = HighlightStyle(rules: [
        T.link: { $0.color = .link },
        T.keyword: { $0.color = .syntax("keyword") },
        T.atom: { $0.color = .syntax("atom") }, T.bool: { $0.color = .syntax("atom") },
        T.url: { $0.color = .syntax("atom") }, T.contentSeparator: { $0.color = .syntax("atom") },
        T.labelName: { $0.color = .syntax("atom") },
        T.literal: { $0.color = .syntax("literal") },
        T.string: { $0.color = .syntax("string") },
        T.regexp: { $0.color = .syntax("regexp") },
        T.escape: { $0.color = .inherit },
        T.typeName: { $0.color = .syntax("typeNamespace") }, T.namespace: { $0.color = .syntax("typeNamespace") },
        T.className: { $0.color = .syntax("className") },
        T.macroName: { $0.color = .syntax("specialVariable") },
        T.comment: { $0.color = .muted },
        T.invalid: { $0.color = .invalid },
    ])
    /// use-prosemark-editor.ts Prec.highest override: semibold instead of bold.
    static let app = HighlightStyle(rules: [
        T.strong: { $0.weight = 600 },
        T.heading: { $0.weight = 600 },
        T.heading1: { $0.weight = 600 }, T.heading2: { $0.weight = 600 }, T.heading3: { $0.weight = 600 },
        T.heading4: { $0.weight = 600 }, T.heading5: { $0.weight = 600 }, T.heading6: { $0.weight = 600 },
    ])
    static let all = [base, general, app]
}

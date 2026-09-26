import Foundation

// Faithful port of @lezer/markdown 1.6.3 (plus the GFM and Flo State extensions)
// operating on UTF-16 code units, so every position equals the JS string index.

typealias MDText = [UInt16]

/// Node type ids. The first block mirrors lezer's `Type` enum; the rest are the
/// node types defined by the configured extensions.
enum MDType {
    static let Document = 1
    static let CodeBlock = 2
    static let FencedCode = 3
    static let Blockquote = 4
    static let HorizontalRule = 5
    static let BulletList = 6
    static let OrderedList = 7
    static let ListItem = 8
    static let ATXHeading1 = 9
    static let SetextHeading1 = 15
    static let SetextHeading2 = 16
    static let HTMLBlock = 17
    static let LinkReference = 18
    static let Paragraph = 19
    static let CommentBlock = 20
    static let ProcessingInstructionBlock = 21
    static let Escape = 22
    static let Entity = 23
    static let HardBreak = 24
    static let Emphasis = 25
    static let StrongEmphasis = 26
    static let Link = 27
    static let Image = 28
    static let InlineCode = 29
    static let HTMLTag = 30
    static let Comment = 31
    static let ProcessingInstruction = 32
    static let Autolink = 33
    static let HeaderMark = 34
    static let QuoteMark = 35
    static let ListMark = 36
    static let LinkMark = 37
    static let EmphasisMark = 38
    static let CodeMark = 39
    static let CodeText = 40
    static let CodeInfo = 41
    static let LinkTitle = 42
    static let LinkLabel = 43
    static let URL = 44
    // Extensions
    static let Table = 45
    static let TableHeader = 46
    static let TableRow = 47
    static let TableCell = 48
    static let TableDelimiter = 49
    static let Task = 50
    static let TaskMarker = 51
    static let Strikethrough = 52
    static let StrikethroughMark = 53
    static let Frontmatter = 54
    static let FrontmatterMark = 55
    static let FrontmatterContent = 56
    static let EscapeMark = 57
    static let Emoji = 58
    static let EmojiMark = 59
    static let Dash = 60
    static let Math = 61
    static let MathMark = 62
    static let MathFormula = 63

    static let names: [String] = [
        "", "Document", "CodeBlock", "FencedCode", "Blockquote", "HorizontalRule", "BulletList",
        "OrderedList", "ListItem", "ATXHeading1", "ATXHeading2", "ATXHeading3", "ATXHeading4",
        "ATXHeading5", "ATXHeading6", "SetextHeading1", "SetextHeading2", "HTMLBlock",
        "LinkReference", "Paragraph", "CommentBlock", "ProcessingInstructionBlock",
        "Escape", "Entity", "HardBreak", "Emphasis", "StrongEmphasis", "Link", "Image",
        "InlineCode", "HTMLTag", "Comment", "ProcessingInstruction", "Autolink",
        "HeaderMark", "QuoteMark", "ListMark", "LinkMark", "EmphasisMark", "CodeMark",
        "CodeText", "CodeInfo", "LinkTitle", "LinkLabel", "URL",
        "Table", "TableHeader", "TableRow", "TableCell", "TableDelimiter", "Task", "TaskMarker",
        "Strikethrough", "StrikethroughMark", "Frontmatter", "FrontmatterMark", "FrontmatterContent",
        "EscapeMark", "Emoji", "EmojiMark", "Dash", "Math", "MathMark", "MathFormula",
    ]
}

/// A syntax element with absolute document positions.
final class MDElt {
    let type: Int
    let from: Int
    var to: Int
    var children: [MDElt]
    init(_ type: Int, _ from: Int, _ to: Int, _ children: [MDElt] = []) {
        self.type = type
        self.from = from
        self.to = to
        self.children = children
    }

    func toSyntaxNode() -> SyntaxNode {
        SyntaxNode(name: MDType.names[type], from: from, to: to, children: children.map { $0.toSyntaxNode() })
    }
}

// MARK: - Character helpers

@inline(__always) func mdCh(_ t: MDText, _ i: Int) -> Int {
    (i >= 0 && i < t.count) ? Int(t[i]) : -1
}

/// lezer's `space`: space, tab, LF, CR.
@inline(__always) func mdSpace(_ c: Int) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

/// JavaScript regexp `\s`.
@inline(__always) func jsSpace(_ c: Int) -> Bool {
    if c < 0 { return false }
    if c <= 32 { return c == 32 || (c >= 9 && c <= 13) }
    if c < 0xa0 { return false }
    switch c {
    case 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: return true
    case 0x2000...0x200a: return true
    default: return false
    }
}

/// JavaScript regexp `\w` (ASCII).
@inline(__always) func jsWord(_ c: Int) -> Bool {
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
}
@inline(__always) func isAsciiAlpha(_ c: Int) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
@inline(__always) func isAsciiDigit(_ c: Int) -> Bool { c >= 48 && c <= 57 }
@inline(__always) func isAsciiAlnum(_ c: Int) -> Bool { isAsciiAlpha(c) || isAsciiDigit(c) }
@inline(__always) func asciiLower(_ c: Int) -> Int { (c >= 65 && c <= 90) ? c + 32 : c }

/// `/[\p{S}|\p{P}]/u` tested against a single UTF-16 code unit.
func mdPunctuation(_ c: Int) -> Bool {
    if c < 0 { return false }
    if c < 128 {
        return (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
    }
    guard let s = Unicode.Scalar(UInt32(c)) else { return false }
    switch s.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation,
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
        return true
    default:
        return false
    }
}

func mdSkipSpace(_ t: MDText, _ from: Int) -> Int {
    var i = from
    while i < t.count && mdSpace(Int(t[i])) { i += 1 }
    return i
}

func mdSkipSpaceBack(_ t: MDText, _ from: Int, _ to: Int) -> Int {
    var i = from
    while i > to && mdSpace(Int(t[i - 1])) { i -= 1 }
    return i
}

func jsSkipSpace(_ t: MDText, _ from: Int) -> Int {
    var i = from
    while i < t.count && jsSpace(Int(t[i])) { i += 1 }
    return i
}

/// JS `str.slice(from, to)` semantics for non-negative arguments.
@inline(__always) func mdSlice(_ t: MDText, _ from: Int, _ to: Int) -> MDText {
    let f = max(0, min(from, t.count)), e = max(0, min(to, t.count))
    return f < e ? Array(t[f..<e]) : []
}

@inline(__always) func mdStarts(_ t: MDText, _ at: Int, _ s: StaticString, caseInsensitive: Bool = false) -> Bool {
    let n = s.utf8CodeUnitCount
    if at < 0 || at + n > t.count { return false }
    let p = s.utf8Start
    for k in 0..<n {
        let c = Int(t[at + k]), b = Int(p[k])
        if caseInsensitive { if asciiLower(c) != asciiLower(b) { return false } } else if c != b { return false }
    }
    return true
}

func mdContains(_ t: MDText, _ s: StaticString, caseInsensitive: Bool = false) -> Bool {
    let n = s.utf8CodeUnitCount
    if n > t.count { return false }
    for i in 0...(t.count - n) where mdStarts(t, i, s, caseInsensitive: caseInsensitive) { return true }
    return false
}


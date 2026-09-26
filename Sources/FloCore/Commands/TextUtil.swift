import Foundation

// Ports of @codemirror/state text helpers (findClusterBreak, countColumn,
// charCategorizer, wordAt) plus a few JS-regex stand-ins used by the command
// ports. All positions are UTF-16 offsets.

public enum CharCategory { case word, space, other }

enum CMText {
    /// JS `\s` membership for one UTF-16 unit.
    static func isJSSpace(_ u: UInt16) -> Bool {
        switch u {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return u >= 0x2000 && u <= 0x200A
        }
    }

    static func isSpaceOrTab(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }

    /// `/\S/.test(s)`
    static func hasNonSpace(_ units: ArraySlice<UInt16>) -> Bool { units.contains { !isJSSpace($0) } }
    static func hasNonSpace(_ s: String) -> Bool { s.utf16.contains { !isJSSpace($0) } }

    /// JS `String.prototype.trim()`
    static func trim(_ s: String) -> String {
        let u = Array(s.utf16)
        var a = 0, b = u.count
        while a < b && isJSSpace(u[a]) { a += 1 }
        while b > a && isJSSpace(u[b - 1]) { b -= 1 }
        return String(utf16CodeUnits: Array(u[a..<b]), count: b - a)
    }

    static func trimEnd(_ s: String) -> String {
        let u = Array(s.utf16)
        var b = u.count
        while b > 0 && isJSSpace(u[b - 1]) { b -= 1 }
        return String(utf16CodeUnits: Array(u[0..<b]), count: b)
    }

    /// CM `findClusterBreak`: next grapheme boundary after (or before) `pos`.
    static func findClusterBreak(_ str: [UInt16], _ pos: Int, forward: Bool = true, includeExtending: Bool = true) -> Int {
        if forward {
            if pos >= str.count { return pos }
            let c = str[pos]
            if c < 0x80 && c != 0x0D && (pos + 1 >= str.count || str[pos + 1] < 0x300) { return pos + 1 }
        } else {
            if pos <= 0 { return pos }
            let c = str[pos - 1]
            if c < 0x80 && (pos >= str.count || str[pos] < 0x300) { return pos - 1 }
        }
        // Slow path: Swift grapheme segmentation.
        let s = String(utf16CodeUnits: str, count: str.count)
        var boundaries = [0]
        var off = 0
        for ch in s { off += ch.utf16.count; boundaries.append(off) }
        if forward {
            return boundaries.first { $0 > pos } ?? pos
        }
        return boundaries.last { $0 < pos } ?? pos
    }

    static func findClusterBreak(_ str: String, _ pos: Int, forward: Bool = true) -> Int {
        findClusterBreak(Array(str.utf16), pos, forward: forward)
    }

    /// CM `countColumn`.
    static func countColumn(_ string: String, tabSize: Int, to: Int? = nil) -> Int {
        let u = Array(string.utf16)
        let end = min(to ?? u.count, u.count)
        var n = 0, i = 0
        while i < end && i < u.count {
            if u[i] == 9 {
                n += tabSize - (n % tabSize)
                i += 1
            } else {
                n += 1
                i = findClusterBreak(u, i)
            }
        }
        return n
    }

    /// CM `makeCategorizer("")` (markdown defines no extra word chars).
    static func categorize(_ s: String) -> CharCategory {
        if !hasNonSpace(s) { return .space }
        if hasWordChar(s) { return .word }
        return .other
    }

    /// `/[\p{Alphabetic}\p{Number}_]/u`
    static func hasWordChar(_ s: String) -> Bool {
        for sc in s.unicodeScalars {
            if sc == "_" { return true }
            if sc.properties.isAlphabetic { return true }
            switch sc.properties.generalCategory {
            case .decimalNumber, .letterNumber, .otherNumber: return true
            default: continue
            }
        }
        return false
    }

    /// Leading run matching `[ \t]*`.
    static func leadingSpaceTab(_ s: String) -> Int {
        var n = 0
        for u in s.utf16 { if u == 0x20 || u == 0x09 { n += 1 } else { break } }
        return n
    }

    /// Leading run matching `\s*`.
    static func leadingWhitespace(_ s: String) -> Int {
        var n = 0
        for u in s.utf16 { if isJSSpace(u) { n += 1 } else { break } }
        return n
    }

    static func utf16Slice(_ s: String, _ from: Int, _ to: Int? = nil) -> String {
        let u = Array(s.utf16)
        let a = max(0, min(from, u.count)), b = max(a, min(to ?? u.count, u.count))
        return String(utf16CodeUnits: Array(u[a..<b]), count: b - a)
    }

    static func len(_ s: String) -> Int { s.utf16.count }
}

/// Minimal JS-flavoured regex helper over NSRegularExpression with UTF-16
/// offsets (JS string indices).
struct JSRegex {
    let re: NSRegularExpression
    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }
    struct Match {
        let ranges: [NSRange]
        let source: NSString
        var index: Int { ranges[0].location }
        var length: Int { ranges[0].length }
        /// Group text or nil when the group did not participate (JS undefined).
        subscript(_ i: Int) -> String? {
            let r = ranges[i]
            return r.location == NSNotFound ? nil : source.substring(with: r)
        }
        func len(_ i: Int) -> Int { let r = ranges[i]; return r.location == NSNotFound ? 0 : r.length }
    }
    func exec(_ s: String) -> Match? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Match(ranges: (0..<m.numberOfRanges).map { m.range(at: $0) }, source: ns)
    }
    func test(_ s: String) -> Bool { exec(s) != nil }
}

extension EditorState {
    /// CM `charCategorizer(at)`; markdown adds no word chars.
    func categorize(_ s: String) -> CharCategory { CMText.categorize(s) }

    /// CM `wordAt(pos)`.
    public func wordAt(_ pos: Int) -> SelectionRange? {
        let line = doc.lineAt(pos)
        let text = Array(line.text.utf16)
        var start = pos - line.from, end = pos - line.from
        while start > 0 {
            let prev = CMText.findClusterBreak(text, start, forward: false)
            if CMText.categorize(String(utf16CodeUnits: Array(text[prev..<start]), count: start - prev)) != .word { break }
            start = prev
        }
        while end < text.count {
            let next = CMText.findClusterBreak(text, end)
            if CMText.categorize(String(utf16CodeUnits: Array(text[end..<next]), count: next - end)) != .word { break }
            end = next
        }
        return start == end ? nil : SelectionRange.range(start + line.from, end + line.from)
    }

    /// Default CM facets as configured in the web app.
    var tabSize: Int { 4 }
    var indentUnit: String { "  " }
    var indentUnitWidth: Int { 2 }
}

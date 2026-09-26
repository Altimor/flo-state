import Foundation
import FloCore

// Port of @codemirror/search 6.7.0 string search as the app uses it
// (editor-search-store.ts / editor-search-overlay.tsx): `SearchCursor` with a
// `toLowerCase` normalizer, and the `StringQuery` operations behind
// findNext / findPrevious / replaceNext / replaceAll / the match highlighter.

public struct SearchMatch: Equatable {
    public var from: Int
    public var to: Int
    /// False when the match starts or ends inside a character that expands
    /// to several characters when normalized.
    public var precise: Bool
    public init(from: Int, to: Int, precise: Bool = true) { self.from = from; self.to = to; self.precise = precise }
}

/// `SearchCursor(doc, query, from, to, s => s.toLowerCase())`. Text is
/// NFKD-normalized and lowercased per code point, the query as a whole.
public struct SearchCursor {
    let units: [UInt16]
    let query: [UInt16]
    var pos: Int
    let end: Int
    private var partials: [(from: Int, index: Int, precise: Bool)] = []

    public init(_ doc: Text, _ query: String, from: Int = 0, to: Int? = nil, caseInsensitive: Bool = true) {
        units = doc.units
        pos = max(0, from)
        end = min(doc.length, to ?? doc.length)
        self.query = SearchCursor.normalizeWhole(query, lower: caseInsensitive)
        lower = caseInsensitive
    }
    private let lower: Bool

    static func normalizeWhole(_ s: String, lower: Bool) -> [UInt16] {
        let n = s.decomposedStringWithCompatibilityMapping
        return Array((lower ? n.lowercased() : n).utf16)
    }

    nonisolated(unsafe) private static var cache: [UInt32: [UInt16]] = [:]
    private static let lock = NSLock()

    /// normalize(basicNormalize(ch)) for one code point.
    static func normalizeChar(_ cp: UInt32, lower: Bool) -> [UInt16] {
        if cp < 0x80 {
            if lower && cp >= 65 && cp <= 90 { return [UInt16(cp + 32)] }
            return [UInt16(cp)]
        }
        if cp >= 0xD800 && cp <= 0xDFFF { return [UInt16(cp)] } // lone surrogate: JS leaves it alone
        let key = cp | (lower ? 0x8000_0000 : 0)
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        guard let sc = Unicode.Scalar(cp) else { return [UInt16(truncatingIfNeeded: cp)] }
        let r = normalizeWhole(String(Character(sc)), lower: lower)
        cache[key] = r
        return r
    }

    public var isDone: Bool { pos >= end && true }

    /// `next()`: the next match, skipping matches that overlap the previous one.
    public mutating func next() -> SearchMatch? {
        partials.removeAll()
        return nextOverlapping()
    }

    public mutating func nextOverlapping() -> SearchMatch? {
        if query.isEmpty { pos = end; return nil }
        while pos < end {
            let start = pos
            let u = units[pos]
            var cp = UInt32(u), size = 1
            if u >= 0xD800 && u < 0xDC00 && pos + 1 < end {
                let l = units[pos + 1]
                if l >= 0xDC00 && l < 0xE000 { cp = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(l) - 0xDC00); size = 2 }
            }
            pos += size
            let norm = SearchCursor.normalizeChar(cp, lower: lower)
            if norm.isEmpty { continue }
            var p = start, posPrecise = true
            for i in 0..<norm.count {
                let code = norm[i]
                if let m = match(code, p, posPrecise, pos, i == norm.count - 1) { return m }
                if i == norm.count - 1 { break }
                if posPrecise && i < size && units[start + i] == code { p += 1 } else { posPrecise = false }
            }
        }
        return nil
    }

    private mutating func match(_ code: UInt16, _ pos: Int, _ posPrecise: Bool, _ end: Int, _ endPrecise: Bool) -> SearchMatch? {
        var found: SearchMatch? = nil
        var i = 0
        while i < partials.count {
            var keep = false
            if query[partials[i].index] == code {
                if partials[i].index == query.count - 1 {
                    found = SearchMatch(from: partials[i].from, to: end, precise: endPrecise && partials[i].precise)
                } else {
                    partials[i].index += 1
                    keep = true
                }
            }
            if keep { i += 1 } else { partials.remove(at: i) }
        }
        if query[0] == code {
            if query.count == 1 { found = SearchMatch(from: pos, to: end, precise: posPrecise && endPrecise) }
            else { partials.append((pos, 1, posPrecise)) }
        }
        return found
    }
}

/// `new SearchQuery({search, caseSensitive: false, regexp: false, replace})`
/// (the overlay doesn't pass `literal`, so `\n`, `\r`, `\t`, `\\` are unquoted).
public struct FindQuery: Equatable {
    public var search: String
    public var replace: String
    public var caseSensitive = false
    public var literal = false
    public init(search: String, replace: String = "") { self.search = search; self.replace = replace }

    public var valid: Bool { !search.isEmpty }
    public var unquoted: String { unquote(search) }

    public func unquote(_ text: String) -> String {
        if literal { return text }
        var out = ""
        var it = text.makeIterator()
        while let c = it.next() {
            if c == "\\" {
                // /\\([nrt\\])/g
                var copy = it
                if let n = copy.next(), "nrt\\".contains(n) {
                    it = copy
                    out.append(n == "n" ? "\n" : n == "r" ? "\r" : n == "t" ? "\t" : "\\")
                    continue
                }
            }
            out.append(c)
        }
        return out
    }

    private var qlen: Int { unquoted.utf16.count }

    func cursor(_ doc: Text, _ from: Int, _ to: Int) -> SearchCursor {
        SearchCursor(doc, unquoted, from: from, to: to, caseInsensitive: !caseSensitive)
    }

    public func nextMatch(_ doc: Text, _ curFrom: Int, _ curTo: Int) -> SearchMatch? {
        var c = cursor(doc, curTo, doc.length)
        var m = c.nextOverlapping()
        if m == nil {
            let end = min(doc.length, curFrom + qlen)
            c = cursor(doc, 0, end)
            m = c.nextOverlapping()
        }
        guard let r = m, !(r.from == curFrom && r.to == curTo) else { return nil }
        return r
    }

    func prevMatchInRange(_ doc: Text, _ from: Int, _ to: Int) -> SearchMatch? {
        var pos = to
        while true {
            let start = max(from, pos - 10000 - qlen)
            var c = cursor(doc, start, pos)
            var range: SearchMatch? = nil
            while let m = c.nextOverlapping() { range = m }
            if range != nil { return range }
            if start == from { return nil }
            pos -= 10000
        }
    }

    public func prevMatch(_ doc: Text, _ curFrom: Int, _ curTo: Int) -> SearchMatch? {
        var found = prevMatchInRange(doc, 0, curFrom)
        if found == nil { found = prevMatchInRange(doc, max(0, curTo - qlen), doc.length) }
        guard let f = found, f.from != curFrom || f.to != curTo else { return nil }
        return f
    }

    public func matchAll(_ doc: Text, limit: Int = Int.max) -> [SearchMatch]? {
        var c = cursor(doc, 0, doc.length)
        var out: [SearchMatch] = []
        while let m = c.next() {
            if out.count >= limit { return nil }
            out.append(m)
        }
        return out
    }

    /// Matches the highlighter paints for the visible span `from..<to`.
    public func highlight(_ doc: Text, _ from: Int, _ to: Int) -> [SearchMatch] {
        var c = cursor(doc, max(0, from - qlen), min(to + qlen, doc.length))
        var out: [SearchMatch] = []
        while let m = c.next() { out.append(m) }
        return out
    }

    // MARK: commands (return the transaction CM would dispatch)

    /// `findNext`: first match after the main selection's end, wrapping.
    public func findNext(_ state: EditorState) -> TransactionSpec? {
        guard valid else { return nil }
        let to = state.selection.main.to
        guard let n = nextMatch(state.doc, to, to) else { return nil }
        return TransactionSpec(selection: .single(n.from, n.to), userEvent: "select.search")
    }

    public func findPrevious(_ state: EditorState) -> TransactionSpec? {
        guard valid else { return nil }
        let from = state.selection.main.from
        guard let p = prevMatch(state.doc, from, from) else { return nil }
        return TransactionSpec(selection: .single(p.from, p.to), userEvent: "select.search")
    }

    /// `replaceNext`: replace the selected match (selecting the replacement),
    /// or select the next match when the selection isn't one.
    public func replaceNext(_ state: EditorState) -> TransactionSpec? {
        guard valid else { return nil }
        let from = state.selection.main.from, to = state.selection.main.to
        guard let match = nextMatch(state.doc, from, from) else { return nil }
        var next: SearchMatch? = match
        var changes: [Change] = []
        if !match.precise {
            next = nextMatch(state.doc, match.from, match.to)
        } else if match.from == from && match.to == to {
            changes.append(Change(from: match.from, to: match.to, insert: unquote(replace)))
        }
        let cs = state.changes(changes)
        var sel: EditorSelection? = nil
        if let n = next { sel = EditorSelection.single(n.from, n.to).map(cs) }
        return TransactionSpec(changes: changes, selection: sel, userEvent: "input.replace")
    }

    public func replaceAll(_ state: EditorState) -> TransactionSpec? {
        guard valid else { return nil }
        let rep = unquote(replace)
        let changes = (matchAll(state.doc) ?? []).filter { $0.precise }.map { Change(from: $0.from, to: $0.to, insert: rep) }
        if changes.isEmpty { return nil }
        return TransactionSpec(changes: changes, userEvent: "input.replace.all")
    }
}

/// The overlay's counter and the scrollbar overview (raw query, not unquoted).
public enum FindCount {
    public struct Info: Equatable { public var current: Int; public var total: Int }

    /// `computeMatchInfo`.
    public static func matchInfo(_ state: EditorState, _ query: String) -> Info? {
        if query.isEmpty { return nil }
        let head = state.selection.main.head
        var total = 0, current = 0
        var c = SearchCursor(state.doc, query)
        while let m = c.next() {
            total += 1
            if current == 0 && m.from <= head && m.to >= head { current = total }
            else if current == 0 && m.from > head { current = total }
        }
        if total > 0 && current == 0 { current = 1 }
        return Info(current: current, total: total)
    }

    public static let maxOverviewMatches = 5000

    /// `collectMatches`.
    public static func collect(_ state: EditorState, _ query: String) -> (ranges: [SearchMatch], activeIndex: Int, docLength: Int)? {
        if query.isEmpty { return nil }
        let head = state.selection.main.head
        var ranges: [SearchMatch] = []
        var active = -1
        var c = SearchCursor(state.doc, query)
        while let m = c.next() {
            let idx = ranges.count
            ranges.append(m)
            if active == -1 && m.from <= head && m.to >= head { active = idx }
            else if active == -1 && m.from > head { active = idx }
            if ranges.count >= maxOverviewMatches { break }
        }
        if !ranges.isEmpty && active == -1 { active = 0 }
        return (ranges, active, max(1, state.doc.length))
    }
}

import Foundation

/// A full-text hit: one matching line in one note.
public struct ContentHit: Equatable {
    public var path: String
    public var relativePath: String
    /// 1-based line number.
    public var line: Int
    /// UTF-16 offset of the match in the file, and its length.
    public var offset: Int
    public var length: Int
    /// The line, trimmed and shortened around the match.
    public var snippet: String
    /// UTF-16 offsets in `snippet` covered by the match.
    public var highlights: [Int]
}

/// Full-text search across the workspace's notes: case- and diacritic-insensitive
/// substring match, first match per line, ranked by where it matched (note name,
/// then headings, then body) and recency. File contents are cached by mtime while
/// the search is open (so each keystroke doesn't re-read the disk) and dropped when it closes.
public final class ContentSearch {
    private struct Entry { var modifiedAt: UInt64; var doc: Doc }
    private var cache: [String: Entry] = [:]

    /// A note's text plus its case/diacritic-folded copy (searched with a literal scan).
    final class Doc {
        let text: NSString
        let folded: NSString
        init(_ s: String) { text = s as NSString; folded = ContentSearch.fold(s) as NSString }
        func lineNumber(at utf16: Int) -> Int {
            var n = 1, i = 0
            while i < utf16 { if text.character(at: i) == 10 { n += 1 }; i += 1 }
            return n
        }
    }

    public init() {}

    /// `overrides`: unsaved buffers of open notes (path → current text), searched instead of disk.
    public func search(_ query: String, in files: [IndexedFile], overrides: [String: String] = [:],
                       limit: Int = 50, perFile: Int = 3) -> [ContentHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let needle = ContentSearch.fold(q)
        let nameNeedle = needle
        var scored: [(score: Int, hit: ContentHit)] = []
        let byRecency = files.sorted { $0.modifiedAt > $1.modifiedAt }
        for (rank, f) in byRecency.enumerated() {
            guard let note = overrides[f.path].map(Doc.init) ?? doc(of: f) else { continue }
            let ns = note.text, hay = note.folded
            let sameLength = hay.length == ns.length
            var searchFrom = 0, inFile = 0
            while inFile < perFile, searchFrom < ns.length {
                // folding keeps UTF-16 length for almost all text; otherwise search the original directly
                let r = sameLength
                    ? hay.range(of: needle, options: .literal, range: NSRange(location: searchFrom, length: hay.length - searchFrom))
                    : ns.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                guard r.location != NSNotFound else { break }
                let lineR = ns.lineRange(for: NSRange(location: r.location, length: 0))
                searchFrom = NSMaxRange(lineR)          // first match per line
                var content = lineR
                while content.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
                let line = ns.substring(with: content)
                let heading = line.hasPrefix("#")
                let score = (heading ? 2_000 : 1_000) - min(rank, 999)
                let (snippet, hl) = ContentSearch.snippet(line, matchAt: r.location - content.location, length: r.length)
                scored.append((score, ContentHit(path: f.path, relativePath: f.relativePath, line: note.lineNumber(at: r.location),
                                                 offset: r.location, length: r.length, snippet: snippet, highlights: hl)))
                inFile += 1
            }
        }
        // note-name matches rank first
        let nameHits = Set(files.filter { ContentSearch.fold(($0.name as NSString).deletingPathExtension).contains(nameNeedle) }.map(\.path))
        return scored.enumerated().sorted { a, b in
            let an = nameHits.contains(a.element.hit.path), bn = nameHits.contains(b.element.hit.path)
            if an != bn { return an }
            return a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.prefix(limit).map(\.element.hit)
    }

    private func doc(of f: IndexedFile) -> Doc? {
        if let e = cache[f.path], e.modifiedAt == f.modifiedAt { return e.doc }
        guard let data = FileManager.default.contents(atPath: f.path),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let d = Doc(s)
        cache[f.path] = Entry(modifiedAt: f.modifiedAt, doc: d)
        return d
    }

    public func invalidate(_ path: String) { cache[path] = nil }
    /// Drop all cached note text (called when the search closes).
    public func clear() { cache.removeAll() }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Trim the line and keep ~40 chars of context before the match.
    static func snippet(_ line: String, matchAt loc: Int, length: Int) -> (String, [Int]) {
        let u = Array(line.utf16)
        var start = 0
        while start < loc && (u[start] == 32 || u[start] == 9) { start += 1 }   // leading indent
        var prefix = ""
        if loc - start > 40 {
            start = loc - 40
            while start < loc, u[start] != 32 { start += 1 }   // cut at a word boundary
            prefix = "…"
        }
        let end = min(u.count, max(loc + length + 120, start + 160))
        let body = String(utf16CodeUnits: Array(u[start..<end]), count: end - start)
        let text = prefix + body + (end < u.count ? "…" : "")
        let base = prefix.utf16.count + (loc - start)
        return (text, Array(base..<(base + length)))
    }
}

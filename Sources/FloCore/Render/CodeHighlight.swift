import Foundation
import JavaScriptCore

/// Syntax highlighting of fenced code (any @codemirror/language-data
/// language) and of HTML in markdown (lang-html), computed by the web
/// editor's own lezer / legacy-mode parsers running in JavaScriptCore
/// (Resources/codehl.js, built by tools/codehl). Results are cached per
/// (kind, info, text, ranges), so re-planning a block costs a dictionary hit.
public final class CodeHighlighter {
    public static let shared = CodeHighlighter()

    /// Style of one prosemark HighlightStyle rule.
    struct Rule {
        var color: String?
        var weight: Int?
        var italic = false
        var sizeEm: Double?
        var strike = false
    }

    /// A highlighted span relative to the highlighted text, with its rules in
    /// stylesheet order (later rules win).
    struct Span { var from: Int; var to: Int; var rules: [Int] }

    private var ctx: JSContext?
    private var fn: JSValue?
    private(set) var rules: [Rule] = []
    private var failed = false
    private var cache: [String: [Span]] = [:]
    private let lock = NSLock()

    private init() {}

    private func boot() -> Bool {
        if fn != nil { return true }
        if failed { return false }
        guard let url = FloResources.bundle.url(forResource: "codehl", withExtension: "js", subdirectory: "Resources"),
              let src = try? String(contentsOf: url, encoding: .utf8), let c = JSContext() else { failed = true; return false }
        c.exceptionHandler = { _, e in NSLog("codehl: %@", e?.toString() ?? "?") }
        c.evaluateScript(src)
        guard let f = c.objectForKeyedSubscript("floHighlight"), !f.isUndefined,
              let rs = c.objectForKeyedSubscript("floHighlightRules").toArray() as? [[String: Any]] else { failed = true; return false }
        rules = rs.map { d in
            Rule(color: d["color"] as? String, weight: (d["weight"] as? NSNumber)?.intValue, italic: (d["italic"] as? Bool) ?? false,
                 sizeEm: (d["size"] as? NSNumber)?.doubleValue, strike: (d["strike"] as? Bool) ?? false)
        }
        ctx = c; fn = f
        return true
    }

    /// kind "code" (info = fence info string) or "html". Ranges are relative to `text`.
    func highlight(kind: String, info: String, text: String, ranges: [(Int, Int)]) -> [Span] {
        guard !ranges.isEmpty else { return [] }
        let key = "\(kind)\u{1}\(info)\u{1}\(ranges.map { "\($0.0),\($0.1)" }.joined(separator: ";"))\u{1}\(text)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        guard boot(), let f = fn else { return [] }
        let args: [Any] = [kind, info, text, ranges.map { [$0.0, $0.1] }]
        var r = f.call(withArguments: args)
        // a language module loads in a microtask (drained when the call returns): ask again
        if r?.isString == true { r = f.call(withArguments: args) }
        var spans: [Span] = []
        if let flat = r?.toArray() as? [NSNumber] {
            var i = 0
            while i + 1 < flat.count {
                var s = Span(from: flat[i].intValue, to: flat[i + 1].intValue, rules: [])
                i += 2
                while i < flat.count, flat[i].intValue >= 0 { s.rules.append(flat[i].intValue); i += 1 }
                i += 1
                s.rules.sort()
                spans.append(s)
            }
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = spans
        return spans
    }

    /// Apply a span's rules onto a char style.
    func apply(_ span: Span, to st: inout CharStyle) {
        let inherited = st.color
        for i in span.rules where i < rules.count {
            let r = rules[i]
            if let c = r.color {
                switch c {
                case "muted": st.color = .muted
                case "link": st.color = .link
                case "invalid": st.color = .invalid
                case "inherit": st.color = inherited
                default: st.color = .syntax(c)
                }
            }
            if let w = r.weight { st.weight = w }
            if r.italic { st.italic = true }
            if let s = r.sizeEm { st.sizeEm = s }
            if r.strike { st.strike = true }
        }
    }
}

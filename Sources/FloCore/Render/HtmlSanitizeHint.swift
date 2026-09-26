import Foundation

/// Whether DOMPurify (with html-block-decorations.ts's ALLOWED_TAGS) would
/// leave anything: an allowed element, or text outside elements whose
/// content DOMPurify drops. Planning must be synchronous; the real sanitiser
/// runs in the renderer.
public enum HtmlSanitizeHint {
    static let allowed: Set<String> = [
        "div", "p", "span", "br", "hr", "section", "article", "aside", "header", "footer", "nav", "main", "details", "summary",
        "h1", "h2", "h3", "h4", "h5", "h6", "strong", "em", "b", "i", "u", "s", "del", "ins", "sub", "sup", "code", "pre",
        "blockquote", "kbd", "mark", "small", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr",
        "th", "td", "caption", "colgroup", "col", "img", "picture", "source", "video", "audio", "figure", "figcaption", "a",
        "ruby", "rt", "rp",
    ]
    /// DOMPurify FORBID_CONTENTS defaults (their text is dropped too).
    static let dropContent: Set<String> = [
        "annotation-xml", "audio", "colgroup", "desc", "foreignobject", "head", "iframe", "math", "mi", "mn", "mo", "ms",
        "mtext", "noembed", "noframes", "plaintext", "script", "style", "svg", "template", "thead", "title",
        "video", "xmp",
    ]
    // tags; comments, doctype, <?…?> and <![CDATA[…]]> (bogus comments in HTML) are dropped
    static let tagRE = try! NSRegularExpression(pattern: #"<(/?)([a-zA-Z][\w-]*)[^>]*>|<!--[\s\S]*?-->|<![^>]*>|<\?[^>]*>"#)
    /// Table parts the parser ignores outside a <table>.
    static let tableParts: Set<String> = ["thead", "tbody", "tfoot", "tr", "td", "th", "col", "colgroup", "caption"]

    // Results of the real sanitiser (DOMPurify in the renderer), keyed by the raw block.
    private static var known: [String: Bool] = [:]
    private static let lock = NSLock()

    /// The plan-time decision: the real sanitiser's verdict when known, else the port below.
    public static func renders(_ html: String) -> Bool {
        lock.lock(); let k = known[html]; lock.unlock()
        return k ?? mayRender(html)
    }

    /// Record the real sanitiser's verdict; returns true when it differs from what planning assumed.
    @discardableResult
    public static func record(_ html: String, renders: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let assumed = known[html] ?? mayRender(html)
        if known.count > 2000 { known.removeAll() }
        known[html] = renders
        return assumed != renders
    }

    /// Text as the HTML parser sees it: character references decoded.
    static func decoded(_ t: String) -> String {
        guard t.contains("&") else { return t }
        var out = t
        for (e, v) in [("&nbsp;", "\u{A0}"), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#160;", "\u{A0}"), ("&#xA0;", "\u{A0}")] {
            out = out.replacingOccurrences(of: e, with: v, options: .caseInsensitive)
        }
        return out
    }

    /// Elements the HTML parser puts in <head> when they come before any body content.
    static let headOnly: Set<String> = ["meta", "link", "base", "title", "style", "script", "noscript", "template"]

    public static func mayRender(_ html: String) -> Bool {
        let ns = html as NSString
        var last = 0, depthDrop = 0, tableDepth = 0
        for m in tagRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if depthDrop == 0, decoded(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                .contains(where: { !$0.isWhitespace }) { return true }
            last = m.range.location + m.range.length
            guard m.range(at: 2).location != NSNotFound else { continue }
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let closing = m.range(at: 1).length > 0
            if name == "table" { tableDepth = max(0, tableDepth + (closing ? -1 : 1)) }
            if tableParts.contains(name) && tableDepth == 0 { continue }
            if allowed.contains(name) && !closing && depthDrop == 0 { return true }
            if dropContent.contains(name) { depthDrop = max(0, depthDrop + (closing ? -1 : 1)) }
        }
        return depthDrop == 0 && decoded(ns.substring(from: last)).contains(where: { !$0.isWhitespace })
    }
}

import Foundation

/// Helpers for porting JS regex code: `\s` in JS is a fixed set that differs
/// from ICU's, so patterns spell it out via `AppRegex.ws`.
enum AppRegex {
    static let ws = #"[\t\n\u000B\f\r    -     　﻿]"#
    static let nonWs = #"[^\t\n\u000B\f\r    -     　﻿]"#

    static var cache: [String: NSRegularExpression] = [:]
    static let lock = NSLock()

    static func re(_ pattern: String, multiline: Bool = false) -> NSRegularExpression {
        let key = (multiline ? "m:" : "s:") + pattern
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        var opts: NSRegularExpression.Options = []
        if multiline { opts.insert(.anchorsMatchLines) }
        let r = try! NSRegularExpression(pattern: pattern, options: opts)
        cache[key] = r
        return r
    }

    static func replace(_ s: String, _ pattern: String, _ template: String, multiline: Bool = false) -> String {
        let r = re(pattern, multiline: multiline)
        return r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    static func matches(_ s: String, _ pattern: String, multiline: Bool = false) -> [NSTextCheckingResult] {
        re(pattern, multiline: multiline).matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    static func test(_ s: String, _ pattern: String, multiline: Bool = false) -> Bool {
        re(pattern, multiline: multiline).firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func firstMatch(_ s: String, _ pattern: String, multiline: Bool = false) -> [String?]? {
        let ns = s as NSString
        guard let m = re(pattern, multiline: multiline).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// JS `String.prototype.trim` (JS whitespace + line terminators).
    static func trim(_ s: String) -> String {
        replace(s, "^\(ws)+|\(ws)+$", "")
    }

    static func split(_ s: String, _ pattern: String) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var last = 0
        for m in re(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }
}

// MARK: - Frontmatter (src/lib/frontmatter.ts)

public enum TitleSource: String { case frontmatter, h1, none }

public struct ParsedFile: Equatable {
    public var frontmatter: String?
    public var body: String
}

public struct ParsedDocument: Equatable {
    public var frontmatter: String?
    public var body: String
    public var title: String
    public var titleSource: TitleSource
}

public enum Frontmatter {
    /// `parseFrontmatter`: `/^---\n([\s\S]*?\n)?---(?:\n|$)/`.
    public static func parse(_ raw: String) -> ParsedFile {
        guard let m = AppRegex.firstMatch(raw, #"^---\n([\s\S]*?\n)?---(?:\n|$)"#) else {
            return ParsedFile(frontmatter: nil, body: raw)
        }
        let whole = m[0]!
        var fm = ""
        if let g = m[1], !g.isEmpty { fm = g.hasSuffix("\n") ? String(g.dropLast()) : g }
        let body = (raw as NSString).substring(from: (whole as NSString).length)
        return ParsedFile(frontmatter: fm, body: body)
    }

    /// `serializeFile` / `serializeDocument`.
    public static func serialize(_ frontmatter: String?, body: String) -> String {
        guard let fm = frontmatter else { return body }
        return "---\n\(fm)\n---\n\(body)"
    }

    public static func parseDocument(_ raw: String) -> ParsedDocument {
        let p = parse(raw)
        let t = inferTitle(body: p.body, frontmatter: p.frontmatter)
        return ParsedDocument(frontmatter: p.frontmatter, body: p.body, title: t.title, titleSource: t.source)
    }

    public static func inferTitle(body: String, frontmatter: String?) -> (title: String, source: TitleSource) {
        if let t = frontmatterTitle(frontmatter) { return (t, .frontmatter) }
        if let t = leadingHeadingTitle(body) { return (t, .h1) }
        return ("", .none)
    }

    /// `parseFrontmatterObject`: `{}` for empty, nil when not a mapping or invalid.
    public static func parseObject(_ frontmatter: String?) -> [(String, YAMLValue)]? {
        guard let fm = frontmatter, !AppRegex.trim(fm).isEmpty else { return [] }
        guard let v = try? YAML.parse(fm), case let .object(pairs) = v else { return nil }
        return pairs
    }

    static func frontmatterTitle(_ frontmatter: String?) -> String? {
        guard let obj = parseObject(frontmatter) else { return nil }
        guard case let .string(title)? = obj.last(where: { $0.0 == "title" })?.1 else { return nil }
        let normalized = AppRegex.trim(title)
        return normalized.isEmpty ? nil : normalized
    }

    static func leadingHeadingTitle(_ body: String) -> String? {
        let afterBlank = AppRegex.replace(body, #"^(?:[ \t]*\n)*"#, "")
        let ns = afterBlank as NSString
        let nl = ns.range(of: "\n")
        let firstLine = nl.location == NSNotFound ? afterBlank : ns.substring(to: nl.location)
        guard let m = AppRegex.firstMatch(firstLine, "^#\(AppRegex.ws)+(.*)$") else { return nil }
        // JS `.` excludes line terminators; ICU `.` also excludes them by default.
        let title = AppRegex.trim(AppRegex.replace(m[1] ?? "", "\(AppRegex.ws)+#+\(AppRegex.ws)*$", ""))
        return title.isEmpty ? nil : title
    }

    /// `getFrontmatterDisplayDate`: first of `date` / `updated` that formats.
    public static func displayDate(_ frontmatter: String?, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let obj = parseObject(frontmatter) else { return nil }
        for key in ["date", "updated"] {
            if let v = obj.last(where: { $0.0 == key })?.1, let f = formatDateValue(v, locale: locale, timeZone: timeZone) { return f }
        }
        return nil
    }

    static func formatDateValue(_ value: YAMLValue, locale: Locale, timeZone: TimeZone) -> String? {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMMdyyyy")
        switch value {
        case let .string(s):
            let trimmed = AppRegex.trim(s)
            if trimmed.isEmpty { return nil }
            guard let date = JSDate.parse(trimmed, timeZone: timeZone) else { return trimmed }
            return formatter.string(from: date)
        case let .number(n) where n.isFinite:
            let ms = n > 1_000_000_000_000 ? n : n * 1000
            return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        default:
            return nil
        }
    }
}

/// The subset of JS `Date.parse` that frontmatter dates use.
enum JSDate {
    static func parse(_ s: String, timeZone: TimeZone) -> Date? {
        // ISO date-only: UTC midnight.
        if let m = AppRegex.firstMatch(s, #"^(\d{4})-(\d{2})-(\d{2})$"#) {
            return components(Int(m[1]!)!, Int(m[2]!)!, Int(m[3]!)!, 0, 0, 0, 0, TimeZone(identifier: "UTC")!)
        }
        // ISO date-time: Z / offset → that zone; otherwise local time.
        if let m = AppRegex.firstMatch(s, #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3})\d*)?)?(Z|[+-]\d{2}:?\d{2})?$"#) {
            var tz = timeZone
            if let z = m[8] {
                if z == "Z" { tz = TimeZone(identifier: "UTC")! }
                else {
                    let sign = z.hasPrefix("-") ? -1 : 1
                    let digits = z.dropFirst().replacingOccurrences(of: ":", with: "")
                    let h = Int(digits.prefix(2)) ?? 0, mm = Int(digits.suffix(2)) ?? 0
                    tz = TimeZone(secondsFromGMT: sign * (h * 3600 + mm * 60)) ?? tz
                }
            }
            let ms = m[7].map { Int($0.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0 } ?? 0
            return components(Int(m[1]!)!, Int(m[2]!)!, Int(m[3]!)!, Int(m[4]!)!, Int(m[5]!)!, Int(m[6] ?? "0")!, ms, tz)
        }
        // Common prose forms V8 also accepts ("March 7, 2024", "7 March 2024", "2024/03/07").
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for fmt in ["MMMM d, yyyy", "MMM d, yyyy", "d MMMM yyyy", "d MMM yyyy", "yyyy/MM/dd", "MM/dd/yyyy", "MMMM d yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func components(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, _ ms: Int, _ tz: TimeZone) -> Date? {
        guard (1...12).contains(mo), (1...31).contains(d), h < 25, mi < 60, s < 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        c.nanosecond = ms * 1_000_000
        return cal.date(from: c)
    }
}

// MARK: - Frontmatter panel entries (src/lib/yaml-entries.ts)

public struct YamlEntry: Equatable {
    public var id: String
    public var key: String
    public var value: String
    public var isComplex: Bool
    public init(id: String = YamlEntries.makeEntryId(), key: String, value: String, isComplex: Bool) {
        self.id = id; self.key = key; self.value = value; self.isComplex = isComplex
    }
}

public enum YamlEntries {
    private static var nextId = 0
    private static let lock = NSLock()

    public static func makeEntryId() -> String {
        lock.lock(); defer { lock.unlock() }
        let id = "fm-\(nextId)"
        nextId += 1
        return id
    }

    public static func parse(_ yamlString: String) -> [YamlEntry] {
        if AppRegex.trim(yamlString).isEmpty { return [] }
        let parsed: YAMLValue
        do { parsed = try YAML.parse(yamlString) } catch {
            return [YamlEntry(key: "", value: yamlString, isComplex: false)]
        }
        guard case let .object(pairs) = parsed else { return [] }
        return pairs.map { key, value in
            switch value {
            case .null: return YamlEntry(key: key, value: "", isComplex: false)
            case .array, .object: return YamlEntry(key: key, value: AppRegex.trim(YAML.stringify(value)), isComplex: true)
            default: return YamlEntry(key: key, value: value.jsString, isComplex: false)
            }
        }
    }

    public static func serialize(_ entries: [YamlEntry]) -> String {
        let filtered = entries.filter { !AppRegex.trim($0.key).isEmpty }
        if filtered.isEmpty { return "" }
        var obj: [(String, YAMLValue)] = []
        func set(_ k: String, _ v: YAMLValue) {
            if let idx = obj.firstIndex(where: { $0.0 == k }) { obj[idx].1 = v } else { obj.append((k, v)) }
        }
        for e in filtered {
            if e.isComplex {
                if let v = try? YAML.parse(e.value) { set(e.key, v) } else { set(e.key, .string(e.value)) }
            } else {
                set(e.key, coerceScalar(e.value))
            }
        }
        return AppRegex.trim(YAML.stringify(.object(YAML.jsOrdered(obj))))
    }

    /// `coerceScalar`.
    public static func coerceScalar(_ value: String) -> YAMLValue {
        if value.isEmpty { return .string("") }
        if value == "true" { return .bool(true) }
        if value == "false" { return .bool(false) }
        if value == "null" { return .null }
        let num = JSNumber.parse(value)
        if !num.isNaN && !AppRegex.trim(value).isEmpty { return .number(num) }
        return .string(value)
    }
}

// MARK: - Document stats (src/lib/document-stats.ts)

public struct DocumentStats: Equatable {
    public var words: Int
    public var characters: Int
    public var paragraphs: Int
    public init(words: Int, characters: Int, paragraphs: Int) { self.words = words; self.characters = characters; self.paragraphs = paragraphs }
    public static let empty = DocumentStats(words: 0, characters: 0, paragraphs: 0)
}

public enum DocumentStatsCalculator {
    static func normalize(_ content: String) -> String {
        let ws = AppRegex.ws
        var s = AppRegex.replace(content, "^\(ws){0,3}(?:#{1,6}|[-*+]|[0-9]+[.)]|>)\(ws)+", "", multiline: true)
        s = AppRegex.replace(s, "`+", "")
        s = AppRegex.replace(s, #"\[\[([^\]]+)\]\]"#, "$1")
        s = AppRegex.replace(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        return AppRegex.trim(s)
    }

    public static func stats(_ content: String) -> DocumentStats {
        let normalized = normalize(content)
        let words = normalized.isEmpty ? 0 : AppRegex.matches(normalized, "\(AppRegex.nonWs)+").count
        let characters = AppRegex.replace(normalized, "\(AppRegex.ws)+", " ").unicodeScalars.count
        let paragraphs = normalized.isEmpty ? 0 : AppRegex.split(normalized, "\n\(AppRegex.ws)*\n").filter {
            !AppRegex.trim(AppRegex.replace($0, "\(AppRegex.ws)+", " ")).isEmpty
        }.count
        return DocumentStats(words: words, characters: characters, paragraphs: paragraphs)
    }
}

// MARK: - Headings (heading-slug.ts, use-document-headings.ts)

public enum HeadingSlug {
    /// github-slugger compatible: lowercase, strip U+2000–U+206F, U+2E00–U+2E7F
    /// and ASCII punctuation (except `-` and `_`), trim, whitespace → `-`.
    public static func slugify(_ text: String) -> String {
        let stripped = AppRegex.replace(text.lowercased(), "[\u{2000}-\u{206F}\u{2E00}-\u{2E7F}!\"#$%&'()*+,./:;<=>?@\\[\\]\\\\^`{|}~]", "")
        return AppRegex.replace(AppRegex.trim(stripped), "\(AppRegex.ws)+", "-")
    }
}

/// `createHeadingSlugger`: `-2`, `-3` … for duplicates, never colliding with
/// an earlier (possibly auto-numbered) slug.
public final class HeadingSlugger {
    private var used = Set<String>()
    private var counts: [String: Int] = [:]
    public init() {}

    public func slug(_ text: String) -> String {
        let base = HeadingSlug.slugify(text)
        var n = (counts[base] ?? 0) + 1
        var candidate = n == 1 ? base : "\(base)-\(n)"
        while used.contains(candidate) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        counts[base] = n
        used.insert(candidate)
        return candidate
    }
}

public struct DocumentHeading: Equatable {
    public var level: Int
    public var text: String
    /// 0-based line index.
    public var line: Int
    /// UTF-16 offset of the line start.
    public var pos: Int
    public var slug: String
}

public enum DocumentHeadings {
    public static let defaultMaxDepth = 3
    public static let fullDepth = 6

    /// `parseDocumentHeadings`. When `slugDepth > maxDepth`, deeper headings
    /// still consume slugs so duplicate numbering matches the whole document.
    public static func parse(_ content: String, maxDepth: Int = defaultMaxDepth, slugDepth: Int? = nil) -> [DocumentHeading] {
        let slugDepth = max(maxDepth, slugDepth ?? maxDepth)
        let slugger = HeadingSlugger()
        var headings: [DocumentHeading] = []
        var inFence = false
        var fenceChar: Character?
        var fenceLen = 0
        var pos = 0
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = AppRegex.replace(line, "^\(AppRegex.ws)+", "")
            if let fm = AppRegex.firstMatch(trimmed, "^(`{3,}|~{3,})"), let marker = fm[1] {
                let ch = marker.first!
                if !inFence {
                    inFence = true; fenceChar = ch; fenceLen = marker.count
                } else if ch == fenceChar && marker.count >= fenceLen {
                    inFence = false; fenceChar = nil; fenceLen = 0
                }
            } else if !inFence {
                if let m = AppRegex.firstMatch(line, "^(#{1,6})\(AppRegex.ws)+(.+?)\(AppRegex.ws)*#*\(AppRegex.ws)*$") {
                    let level = m[1]!.count
                    let text = AppRegex.trim(m[2]!)
                    if !text.isEmpty && level <= slugDepth {
                        let slug = slugger.slug(text)
                        if level <= maxDepth {
                            headings.append(DocumentHeading(level: level, text: text, line: i, pos: pos, slug: slug))
                        }
                    }
                }
            }
            pos += (line as NSString).length + 1
        }
        return headings
    }

    /// Rail/anchor view: H1–H3 shown, slugs computed against the full depth.
    public static func forOutline(_ content: String, maxDepth: Int = defaultMaxDepth) -> [DocumentHeading] {
        parse(content, maxDepth: maxDepth, slugDepth: fullDepth)
    }

    /// `buildSlugIndex`: first heading wins per slug.
    public static func slugIndex(_ headings: [DocumentHeading]) -> [String: DocumentHeading] {
        var index: [String: DocumentHeading] = [:]
        for h in headings where index[h.slug] == nil { index[h.slug] = h }
        return index
    }

    /// Outline "Copy heading link": `[text](#slug)`.
    public static func headingLink(_ heading: DocumentHeading) -> String { "[\(heading.text)](#\(heading.slug))" }
}

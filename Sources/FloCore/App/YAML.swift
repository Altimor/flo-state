import Foundation

/// A YAML value as the `yaml` npm package's `parse()` would hand it to JS
/// (core schema: no timestamps; maps become plain objects).
public indirect enum YAMLValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([YAMLValue])
    /// Ordered as JS `Object.entries` would enumerate the resulting object.
    case object([(String, YAMLValue)])

    public static func == (a: YAMLValue, b: YAMLValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y || (x.isNaN && y.isNaN)
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> YAMLValue? {
        if case let .object(pairs) = self { return pairs.last(where: { $0.0 == key })?.1 }
        return nil
    }

    public var isCollection: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    /// JS `String(value)` for scalars.
    public var jsString: String {
        switch self {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(n): return JSNumber.toString(n)
        case let .string(s): return s
        case .array, .object: return ""
        }
    }
}

public struct YAMLError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// JS number helpers.
public enum JSNumber {
    /// `Number.prototype.toString()`.
    public static func toString(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n < 0 ? "-Infinity" : "Infinity" }
        if n == 0 { return "0" }
        let a = abs(n)
        if a >= 1e21 || a < 1e-6 {
            // Exponent form: d.ddde+XX
            var s = "\(n)" // Swift: 1e+21 prints as "1e+21"
            if !s.contains("e") { s = String(format: "%g", n) }
            s = s.replacingOccurrences(of: "e-0", with: "e-").replacingOccurrences(of: "e+0", with: "e+")
            if let r = s.range(of: "e"), !s[r.upperBound...].hasPrefix("-"), !s[r.upperBound...].hasPrefix("+") {
                s.insert("+", at: r.upperBound)
            }
            return s
        }
        return ConfigFile.rustDisplay(n)
    }

    /// JS `Number(string)` (returns NaN for invalid input).
    public static func parse(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }
        if s == "Infinity" || s == "+Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }
        let lower = s.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            let digits = String(s.dropFirst(2))
            guard !digits.isEmpty, let v = UInt64(digits, radix: radix) else { return .nan }
            return Double(v)
        }
        // Decimal literal: no "inf"/"nan" words, no hex floats.
        if lower.contains("inf") || lower.contains("nan") || lower.contains("x") { return .nan }
        return ConfigFile.parseRustFloat(s) ?? .nan
    }
}

/// A small YAML reader/writer covering what frontmatter uses: block maps and
/// sequences, flow collections, plain/quoted/block scalars, comments.
public enum YAML {
    // MARK: - Parse

    public static func parse(_ text: String) throws -> YAMLValue {
        var p = BlockParser(text: text)
        return try p.parseDocument()
    }

    // MARK: Core-schema scalar resolution

    static func resolvePlain(_ s: String) -> YAMLValue {
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .number(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .number(-.infinity)
        case ".nan", ".NaN", ".NAN": return .number(.nan)
        default: break
        }
        if s.hasPrefix("0o"), s.count > 2, s.dropFirst(2).allSatisfy({ $0 >= "0" && $0 <= "7" }), let v = UInt64(s.dropFirst(2), radix: 8) {
            return .number(Double(v))
        }
        if s.hasPrefix("0x"), s.count > 2, s.dropFirst(2).allSatisfy({ $0.isHexDigit }), let v = UInt64(s.dropFirst(2), radix: 16) {
            return .number(Double(v))
        }
        if isCoreInt(s), let d = Double(s) { return .number(d) }
        if isCoreFloat(s), let d = ConfigFile.parseRustFloat(s) { return .number(d) }
        return .string(s)
    }

    static func isCoreInt(_ s: String) -> Bool {
        var body = Substring(s)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        return !body.isEmpty && body.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// `[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?`
    static func isCoreFloat(_ s: String) -> Bool {
        s.range(of: #"^[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    // MARK: - Block parser

    struct Line {
        let indent: Int
        let text: String   // content after indent, comments stripped for structure lines
        let raw: String    // the full original line
        let number: Int
    }

    struct BlockParser {
        var lines: [String]
        var i = 0

        init(text: String) {
            var ls = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            if ls.last == "" { ls.removeLast() }
            lines = ls
        }

        static func indentOf(_ s: String) -> Int {
            var n = 0
            for c in s { if c == " " { n += 1 } else { break } }
            return n
        }

        static func isBlankOrComment(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasPrefix("#")
        }

        mutating func skipBlank() {
            while i < lines.count, BlockParser.isBlankOrComment(lines[i]) { i += 1 }
        }

        mutating func parseDocument() throws -> YAMLValue {
            skipBlank()
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) == "---" { i += 1; skipBlank() }
            guard i < lines.count else { return .null }
            let v = try parseNode(minIndent: 0, parentIndent: -1)
            skipBlank()
            if i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t != "..." && t != "---" { throw YAMLError(message: "Unexpected content at line \(i + 1)") }
            }
            return v
        }

        /// Parses the block node starting at the current line (whose indent must be > parentIndent).
        mutating func parseNode(minIndent: Int, parentIndent: Int) throws -> YAMLValue {
            skipBlank()
            guard i < lines.count else { return .null }
            let line = lines[i]
            let indent = BlockParser.indentOf(line)
            if indent <= parentIndent { return .null }
            let content = String(line.dropFirst(indent))
            if content.hasPrefix("\t") { throw YAMLError(message: "Tabs are not allowed as indentation") }
            if isSeqItem(content) { return try parseSequence(indent: indent) }
            if try splitMapKey(content) != nil { return try parseMapping(indent: indent) }
            // A scalar (possibly multi-line plain, quoted or flow) at this level.
            return try parseScalarBlock(indent: indent, parentIndent: parentIndent)
        }

        func isSeqItem(_ content: String) -> Bool { content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t") }

        /// Returns (key, rest-after-colon) when `content` is `key: …` / `key:`.
        func splitMapKey(_ content: String) throws -> (String, String)? {
            let chars = Array(content)
            guard !chars.isEmpty else { return nil }
            var idx = 0
            var key: String
            if chars[0] == "\"" || chars[0] == "'" {
                guard let (s, end) = YAML.scanQuoted(chars, from: 0) else { return nil }
                key = s
                idx = end
                while idx < chars.count, chars[idx] == " " { idx += 1 }
                guard idx < chars.count, chars[idx] == ":" else { return nil }
                guard idx + 1 == chars.count || chars[idx + 1] == " " || chars[idx + 1] == "\t" else { return nil }
                return (key, String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces))
            }
            if chars[0] == "[" || chars[0] == "{" || chars[0] == "#" || chars[0] == "|" || chars[0] == ">" { return nil }
            if chars[0] == "?" && (chars.count == 1 || chars[1] == " ") { throw YAMLError(message: "Explicit keys are not supported") }
            while idx < chars.count {
                if chars[idx] == ":" && (idx + 1 == chars.count || chars[idx + 1] == " " || chars[idx + 1] == "\t") {
                    key = String(chars[..<idx]).trimmingCharacters(in: .whitespaces)
                    if key.isEmpty { return ("", String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces)) }
                    return (key, String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces))
                }
                if chars[idx] == "#" && idx > 0 && (chars[idx - 1] == " " || chars[idx - 1] == "\t") { return nil }
                idx += 1
            }
            return nil
        }

        mutating func parseMapping(indent: Int) throws -> YAMLValue {
            var pairs: [(String, YAMLValue)] = []
            var seen = Set<String>()
            while true {
                skipBlank()
                guard i < lines.count else { break }
                let line = lines[i]
                let ind = BlockParser.indentOf(line)
                if ind < indent { break }
                if ind > indent { throw YAMLError(message: "Bad indentation of a mapping entry at line \(i + 1)") }
                let content = String(line.dropFirst(ind))
                if content == "---" || content == "..." { break }
                guard let (rawKey, rest) = try splitMapKey(content) else {
                    throw YAMLError(message: "Implicit map keys need to be followed by map values at line \(i + 1)")
                }
                let keyValue: YAMLValue
                if rawKey.hasPrefix("\"") || rawKey.hasPrefix("'") || content.hasPrefix("\"") || content.hasPrefix("'") {
                    keyValue = .string(rawKey)
                } else {
                    keyValue = YAML.resolvePlain(rawKey)
                }
                let key = YAML.jsObjectKey(keyValue)
                if seen.contains(key) { throw YAMLError(message: "Map keys must be unique at line \(i + 1)") }
                seen.insert(key)
                i += 1
                let value = try parseValue(rest: rest, ownerIndent: indent, allowSameIndentSeq: true)
                pairs.append((key, value))
            }
            return .object(YAML.jsOrdered(pairs))
        }

        mutating func parseSequence(indent: Int) throws -> YAMLValue {
            var items: [YAMLValue] = []
            while true {
                skipBlank()
                guard i < lines.count else { break }
                let line = lines[i]
                let ind = BlockParser.indentOf(line)
                if ind < indent { break }
                if ind > indent { throw YAMLError(message: "Bad indentation of a sequence at line \(i + 1)") }
                let content = String(line.dropFirst(ind))
                guard isSeqItem(content) else { break }
                let rest = content == "-" ? "" : String(content.dropFirst(2))
                let restTrim = rest.trimmingCharacters(in: .whitespaces)
                let itemIndent = ind + 2 + (rest.count - rest.drop(while: { $0 == " " }).count)
                let restIsKey = try splitMapKey(restTrim) != nil
                if !restTrim.isEmpty && (isSeqItem(restTrim) || restIsKey) && !restTrim.hasPrefix("[") && !restTrim.hasPrefix("{") {
                    // Compact nested collection: rewrite the line so the item starts at its own indent.
                    lines[i] = String(repeating: " ", count: itemIndent) + restTrim
                    items.append(try parseNode(minIndent: itemIndent, parentIndent: ind))
                } else {
                    i += 1
                    items.append(try parseValue(rest: rest.trimmingCharacters(in: .whitespaces), ownerIndent: ind, allowSameIndentSeq: false))
                }
            }
            return .array(items)
        }

        /// Value following `key:` or `- ` on the same line (possibly empty → nested block).
        mutating func parseValue(rest: String, ownerIndent: Int, allowSameIndentSeq: Bool) throws -> YAMLValue {
            var rest = YAML.stripTag(rest)
            if rest.hasPrefix("&") { // anchor: drop it
                rest = String(rest.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
            }
            if rest.isEmpty || rest.hasPrefix("#") {
                skipBlank()
                guard i < lines.count else { return .null }
                let ind = BlockParser.indentOf(lines[i])
                let content = String(lines[i].dropFirst(ind))
                if ind > ownerIndent { return try parseNode(minIndent: ind, parentIndent: ownerIndent) }
                if allowSameIndentSeq && ind == ownerIndent && isSeqItem(content) { return try parseSequence(indent: ind) }
                return .null
            }
            if rest.hasPrefix("*") { throw YAMLError(message: "Aliases are not supported") }
            if rest.hasPrefix("|") || rest.hasPrefix(">") {
                return .string(try parseBlockScalar(header: rest, ownerIndent: ownerIndent))
            }
            if rest.hasPrefix("[") || rest.hasPrefix("{") {
                var text = rest
                // Flow collections may span lines.
                while !YAML.flowBalanced(text), i < lines.count {
                    text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                var fp = FlowParser(chars: Array(text))
                let v = try fp.parseValue()
                fp.skipSpaces()
                if fp.idx < fp.chars.count && fp.chars[fp.idx] != "#" { throw YAMLError(message: "Unexpected content after flow collection") }
                return v
            }
            if rest.hasPrefix("\"") || rest.hasPrefix("'") {
                var text = rest
                while YAML.scanQuoted(Array(text), from: 0) == nil, i < lines.count {
                    text += "\n" + lines[i]
                    i += 1
                }
                guard let (s, end) = YAML.scanQuoted(Array(text), from: 0) else { throw YAMLError(message: "Missing closing quote") }
                let tail = String(Array(text)[end...]).trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty && !tail.hasPrefix("#") { throw YAMLError(message: "Unexpected content after quoted scalar") }
                return .string(s)
            }
            // Plain scalar; may continue on more-indented lines.
            var parts = [YAML.stripComment(rest)]
            if try splitMapKey(rest) != nil { throw YAMLError(message: "Nested mappings are not allowed in compact mappings") }
            while i < lines.count {
                let l = lines[i]
                if BlockParser.isBlankOrComment(l) {
                    // Blank lines inside a multi-line plain scalar become newlines.
                    var j = i
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count, BlockParser.indentOf(lines[j]) > ownerIndent, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                       lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        parts.append(contentsOf: Array(repeating: "\n", count: j - i))
                        i = j
                        continue
                    }
                    break
                }
                let ind = BlockParser.indentOf(l)
                if ind <= ownerIndent { break }
                let t = l.trimmingCharacters(in: .whitespaces)
                if try splitMapKey(t) != nil { throw YAMLError(message: "Unexpected map entry in plain scalar at line \(i + 1)") }
                parts.append(YAML.stripComment(t))
                i += 1
            }
            return YAML.resolvePlain(YAML.foldPlain(parts))
        }

        mutating func parseScalarBlock(indent: Int, parentIndent: Int) throws -> YAMLValue {
            let content = String(lines[i].dropFirst(indent))
            i += 1
            return try parseValue(rest: content, ownerIndent: parentIndent, allowSameIndentSeq: false)
        }

        mutating func parseBlockScalar(header: String, ownerIndent: Int) throws -> String {
            let folded = header.hasPrefix(">")
            var chomp: Character = " "
            var explicitIndent: Int?
            for c in YAML.stripComment(String(header.dropFirst())) {
                if c == "-" || c == "+" { chomp = c } else if let d = c.wholeNumberValue { explicitIndent = d }
            }
            var body: [String] = []
            var blockIndent: Int? = explicitIndent.map { ownerIndent + $0 }
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { body.append(""); i += 1; continue }
                let ind = BlockParser.indentOf(l)
                if blockIndent == nil {
                    if ind <= ownerIndent { break }
                    blockIndent = ind
                }
                if ind < blockIndent! { break }
                body.append(String(l.dropFirst(blockIndent!)))
                i += 1
            }
            // Trailing blank lines belong to chomping.
            var trailing = 0
            while let last = body.last, last.isEmpty { body.removeLast(); trailing += 1 }
            var text: String
            if folded {
                text = ""
                for (k, line) in body.enumerated() {
                    if k == 0 { text = line; continue }
                    let prev = body[k - 1]
                    if line.isEmpty || prev.isEmpty || line.hasPrefix(" ") || prev.hasPrefix(" ") { text += "\n" + line }
                    else { text += " " + line }
                }
                // Collapse "\n" + "" sequences like YAML folding of blank lines.
                text = text.replacingOccurrences(of: "\n\n", with: "\n\n")
            } else {
                text = body.joined(separator: "\n")
            }
            if body.isEmpty { return chomp == "+" ? String(repeating: "\n", count: trailing) : "" }
            switch chomp {
            case "-": return text
            case "+": return text + "\n" + String(repeating: "\n", count: trailing)
            default: return text + "\n"
            }
        }
    }

    static func foldPlain(_ parts: [String]) -> String {
        var out = ""
        var pendingNewlines = 0
        for (k, p) in parts.enumerated() {
            if p == "\n" { pendingNewlines += 1; continue }
            if k == 0 { out = p; continue }
            if pendingNewlines > 0 { out += String(repeating: "\n", count: pendingNewlines); pendingNewlines = 0 }
            else { out += " " }
            out += p
        }
        return out
    }

    static func stripComment(_ s: String) -> String {
        let chars = Array(s)
        for k in chars.indices where chars[k] == "#" && k > 0 && (chars[k - 1] == " " || chars[k - 1] == "\t") {
            return String(chars[..<k]).trimmingCharacters(in: .whitespaces)
        }
        if s.hasPrefix("#") { return "" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func stripTag(_ s: String) -> String {
        guard s.hasPrefix("!") else { return s }
        return String(s.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
    }

    static func flowBalanced(_ s: String) -> Bool {
        var depth = 0
        var quote: Character?
        for c in s {
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c }
            else if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" { depth -= 1 }
        }
        return depth <= 0
    }

    /// Scans a quoted scalar starting at `from`; returns (value, index after closing quote).
    static func scanQuoted(_ chars: [Character], from: Int) -> (String, Int)? {
        guard from < chars.count else { return nil }
        let q = chars[from]
        var out = ""
        var k = from + 1
        var pendingBreak = false
        while k < chars.count {
            let c = chars[k]
            if q == "'" {
                if c == "'" {
                    if k + 1 < chars.count && chars[k + 1] == "'" { out.append("'"); k += 2; continue }
                    return (out, k + 1)
                }
            } else {
                if c == "\"" { return (out, k + 1) }
                if c == "\\" && k + 1 < chars.count {
                    let e = chars[k + 1]
                    k += 2
                    switch e {
                    case "n": out += "\n"
                    case "t", "\t": out += "\t"
                    case "r": out += "\r"
                    case "0": out += "\0"
                    case "a": out += "\u{07}"
                    case "b": out += "\u{08}"
                    case "e": out += "\u{1B}"
                    case "f": out += "\u{0C}"
                    case "v": out += "\u{0B}"
                    case "N": out += "\u{85}"
                    case "_": out += "\u{A0}"
                    case "L": out += "\u{2028}"
                    case "P": out += "\u{2029}"
                    case " ": out += " "
                    case "/": out += "/"
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    case "\n":
                        while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    case "x", "u", "U":
                        let len = e == "x" ? 2 : (e == "u" ? 4 : 8)
                        guard k + len <= chars.count, let v = UInt32(String(chars[k..<k + len]), radix: 16),
                              let scalar = Unicode.Scalar(v) else { return nil }
                        out.unicodeScalars.append(scalar)
                        k += len
                    default: out.append(e)
                    }
                    continue
                }
            }
            if c == "\n" {
                // Line folding inside quoted scalars.
                while out.hasSuffix(" ") || out.hasSuffix("\t") { out.removeLast() }
                var n = 0
                k += 1
                while k < chars.count {
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    if k < chars.count, chars[k] == "\n" { n += 1; k += 1 } else { break }
                }
                out += n == 0 ? " " : String(repeating: "\n", count: n)
                pendingBreak = false
                continue
            }
            _ = pendingBreak
            out.append(c)
            k += 1
        }
        return nil
    }

    // MARK: Flow

    struct FlowParser {
        let chars: [Character]
        var idx = 0

        mutating func skipSpaces() {
            while idx < chars.count, chars[idx] == " " || chars[idx] == "\t" || chars[idx] == "\n" { idx += 1 }
        }

        mutating func parseValue() throws -> YAMLValue {
            skipSpaces()
            guard idx < chars.count else { return .null }
            switch chars[idx] {
            case "[":
                idx += 1
                var items: [YAMLValue] = []
                while true {
                    skipSpaces()
                    guard idx < chars.count else { throw YAMLError(message: "Unterminated flow sequence") }
                    if chars[idx] == "]" { idx += 1; return .array(items) }
                    let v = try parseEntry(inMap: false)
                    items.append(v.1 == nil ? v.0 : .object([(YAML.jsObjectKey(v.0), v.1!)]))
                    skipSpaces()
                    guard idx < chars.count else { throw YAMLError(message: "Unterminated flow sequence") }
                    if chars[idx] == "," { idx += 1; continue }
                    if chars[idx] == "]" { idx += 1; return .array(items) }
                    throw YAMLError(message: "Expected , or ] in flow sequence")
                }
            case "{":
                idx += 1
                var pairs: [(String, YAMLValue)] = []
                var seen = Set<String>()
                while true {
                    skipSpaces()
                    guard idx < chars.count else { throw YAMLError(message: "Unterminated flow mapping") }
                    if chars[idx] == "}" { idx += 1; return .object(YAML.jsOrdered(pairs)) }
                    let (k, v) = try parseEntry(inMap: true)
                    let key = YAML.jsObjectKey(k)
                    if seen.contains(key) { throw YAMLError(message: "Map keys must be unique") }
                    seen.insert(key)
                    pairs.append((key, v ?? .null))
                    skipSpaces()
                    guard idx < chars.count else { throw YAMLError(message: "Unterminated flow mapping") }
                    if chars[idx] == "," { idx += 1; continue }
                    if chars[idx] == "}" { idx += 1; return .object(YAML.jsOrdered(pairs)) }
                    throw YAMLError(message: "Expected , or } in flow mapping")
                }
            case "\"", "'":
                guard let (s, end) = YAML.scanQuoted(chars, from: idx) else { throw YAMLError(message: "Missing closing quote") }
                idx = end
                return .string(s)
            default:
                return YAML.resolvePlain(scanPlain())
            }
        }

        mutating func scanPlain() -> String {
            var out = ""
            while idx < chars.count {
                let c = chars[idx]
                if c == "," || c == "]" || c == "}" || c == "[" || c == "{" { break }
                if c == ":" && (idx + 1 == chars.count || " ,]}\n".contains(chars[idx + 1])) { break }
                if c == "#" && out.hasSuffix(" ") { break }
                out.append(c)
                idx += 1
            }
            return out.trimmingCharacters(in: .whitespaces)
        }

        /// A flow entry: `value` or `key: value`.
        mutating func parseEntry(inMap: Bool) throws -> (YAMLValue, YAMLValue?) {
            let key = try parseValue()
            skipSpaces()
            if idx < chars.count, chars[idx] == ":" {
                idx += 1
                skipSpaces()
                if idx < chars.count, chars[idx] == "," || chars[idx] == "}" || chars[idx] == "]" { return (key, .null) }
                return (key, try parseValue())
            }
            return (key, inMap ? .null : nil)
        }
    }

    // MARK: JS object semantics

    /// Key string a YAML key becomes on a plain JS object.
    static func jsObjectKey(_ v: YAMLValue) -> String {
        switch v {
        case .null: return ""
        case let .string(s): return s
        default: return v.jsString
        }
    }

    /// JS property enumeration order: array-index keys ascending first, then
    /// the rest in insertion order.
    static func jsOrdered(_ pairs: [(String, YAMLValue)]) -> [(String, YAMLValue)] {
        func arrayIndex(_ k: String) -> UInt32? {
            guard let v = UInt32(k), v != UInt32.max, String(v) == k else { return nil }
            return v
        }
        let indexed = pairs.compactMap { p in arrayIndex(p.0).map { ($0, p) } }.sorted { $0.0 < $1.0 }.map { $0.1 }
        let rest = pairs.filter { arrayIndex($0.0) == nil }
        return indexed + rest
    }

    // MARK: - Stringify (yaml v2 `stringify`, lineWidth 0)

    public static func stringify(_ value: YAMLValue) -> String {
        var out = ""
        switch value {
        case let .object(pairs) where !pairs.isEmpty:
            writeMap(pairs, indent: "", into: &out)
        case let .array(items) where !items.isEmpty:
            writeSeq(items, indent: "", into: &out)
        default:
            out = scalarString(value, indent: "", implicitKey: false) + "\n"
        }
        return out
    }

    static func writeMap(_ pairs: [(String, YAMLValue)], indent: String, into out: inout String) {
        for (k, v) in pairs {
            let key = scalarString(.string(k), indent: indent, implicitKey: true)
            switch v {
            case let .object(p) where !p.isEmpty:
                out += "\(indent)\(key):\n"
                writeMap(p, indent: indent + "  ", into: &out)
            case let .array(items) where !items.isEmpty:
                out += "\(indent)\(key):\n"
                writeSeq(items, indent: indent + "  ", into: &out)
            default:
                out += "\(indent)\(key): \(scalarString(v, indent: indent + "  ", implicitKey: false))\n"
            }
        }
    }

    static func writeSeq(_ items: [YAMLValue], indent: String, into out: inout String) {
        for v in items {
            switch v {
            case let .object(p) where !p.isEmpty:
                var inner = ""
                writeMap(p, indent: indent + "  ", into: &inner)
                out += "\(indent)- " + String(inner.dropFirst(indent.count + 2))
            case let .array(sub) where !sub.isEmpty:
                var inner = ""
                writeSeq(sub, indent: indent + "  ", into: &inner)
                out += "\(indent)- " + String(inner.dropFirst(indent.count + 2))
            default:
                out += "\(indent)- \(scalarString(v, indent: indent + "  ", implicitKey: false))\n"
            }
        }
    }

    static func scalarString(_ v: YAMLValue, indent: String, implicitKey: Bool) -> String {
        switch v {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .number(n):
            if n.isNaN { return ".nan" }
            if n.isInfinite { return n < 0 ? "-.inf" : ".inf" }
            if n == 0 && n.sign == .minus { return "-0" }
            return JSNumber.toString(n)
        case .object: return "{}"
        case .array: return "[]"
        case let .string(s): return stringString(s, indent: indent, implicitKey: implicitKey)
        }
    }

    static let plainBlocker = try! NSRegularExpression(
        pattern: #"^[\n\t ,\[\]{}#&*!|>'"%@`]|^[?-]$|^[?-][ \t]|[\n:][ \t]|[ \t]\n|[\n\t ]#|[\n\t :]$"#)

    static func stringString(_ value: String, indent: String, implicitKey: Bool) -> String {
        if implicitKey && value.contains("\n") { return quoted(value) }
        let range = NSRange(value.startIndex..., in: value)
        if plainBlocker.firstMatch(in: value, range: range) != nil {
            return (implicitKey || !value.contains("\n")) ? quoted(value) : blockString(value, indent: indent)
        }
        if !implicitKey && value.contains("\n") { return blockString(value, indent: indent) }
        // Would a plain rendering read back as something other than a string?
        if case .string = resolvePlain(value) {} else { return quoted(value) }
        if value.isEmpty { return quoted(value) }
        return value
    }

    static func quoted(_ value: String) -> String {
        let hasDouble = value.contains("\"")
        let hasSingle = value.contains("'")
        if hasDouble && !hasSingle { return "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        return doubleQuoted(value)
    }

    static func doubleQuoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\0": out += "\\0"
            case "\u{07}": out += "\\a"
            case "\u{0B}": out += "\\v"
            case "\u{1B}": out += "\\e"
            default:
                if scalar.value < 0x20 { out += String(format: "\\x%02x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func blockString(_ value: String, indent: String) -> String {
        var body = value
        var trailing = 0
        while body.hasSuffix("\n") { body.removeLast(); trailing += 1 }
        let chomp = trailing == 0 ? "-" : (trailing == 1 ? "" : "+")
        let indentIndicator = body.hasPrefix(" ") ? String(indent.count) : ""
        let lines = body.components(separatedBy: "\n").map { $0.isEmpty ? "" : indent + $0 }
        var out = "|\(indentIndicator)\(chomp)\n" + lines.joined(separator: "\n")
        if trailing > 1 { out += String(repeating: "\n", count: trailing - 1) }
        return out
    }
}

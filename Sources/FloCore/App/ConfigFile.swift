import Foundation

/// A value parsed from a Ghostty-style config file (port of `config.rs::ConfigValue`).
public enum ConfigValue: Equatable, CustomStringConvertible {
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([String])

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var numberValue: Double? { if case let .number(n) = self { return n }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var listValue: [String]? { if case let .list(l) = self { return l }; return nil }

    public var description: String {
        switch self {
        case let .bool(b): return "bool(\(b))"
        case let .number(n): return "number(\(n))"
        case let .string(s): return "string(\(s))"
        case let .list(l): return "list(\(l))"
        }
    }

    /// JSON representation used by `get_settings` (`config_value_to_json`).
    public var json: JSONValue {
        switch self {
        case let .bool(b): return .bool(b)
        case let .number(n): return n.isFinite ? .double(n) : .null
        case let .string(s): return .string(s)
        case let .list(l): return .array(l.map { .string($0) })
        }
    }

    /// `json_to_config_value`: arrays keep only their string members.
    public init?(json: JSONValue) {
        switch json {
        case let .bool(b): self = .bool(b)
        case let .int(i): self = .number(Double(i))
        case let .double(d): self = .number(d)
        case let .string(s): self = .string(s)
        case let .array(a): self = .list(a.compactMap { $0.stringValue })
        default: return nil
        }
    }
}

/// Parser/serializer for the `key = value` config format (port of `config.rs`).
///
/// There is no quoting: the value is everything after the first `=`, trimmed.
/// `true`/`false` (ASCII case-insensitive) are booleans, anything Rust's
/// `f64::from_str` accepts and is finite is a number, everything else a string.
/// A key that appears more than once becomes a list of its raw value strings.
public enum ConfigFile {
    // MARK: Values

    /// `value_to_string`: integral numbers print without a fractional part.
    public static func valueToString(_ value: ConfigValue) -> String {
        switch value {
        case let .bool(b): return b ? "true" : "false"
        case let .number(n): return formatNumber(n)
        case let .string(s): return s
        case .list: return ""
        }
    }

    /// Rust's `if n == (n as i64) as f64 { (n as i64).to_string() } else { n.to_string() }`.
    public static func formatNumber(_ n: Double) -> String {
        if n.isFinite, let i = rustAsI64(n), Double(i) == n { return String(i) }
        return rustDisplay(n)
    }

    /// Rust `as i64` saturates; NaN becomes 0.
    private static func rustAsI64(_ n: Double) -> Int64? {
        if n.isNaN { return 0 }
        if n >= 9.223372036854775807e18 { return Int64.max }
        if n <= -9.223372036854775808e18 { return Int64.min }
        return Int64(n)
    }

    /// Rust's `Display` for f64: shortest round-trip digits, never exponent notation.
    static func rustDisplay(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n < 0 ? "-inf" : "inf" }
        let s = "\(n)"
        guard let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        let mantissa = String(s[s.startIndex..<eIdx])
        let exp = Int(s[s.index(after: eIdx)...]) ?? 0
        let negative = mantissa.hasPrefix("-")
        let m = negative ? String(mantissa.dropFirst()) : mantissa
        let parts = m.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = intPart + fracPart
        var pointPos = intPart.count + exp
        while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); pointPos -= 1 }
        var result: String
        if pointPos <= 0 {
            result = "0." + String(repeating: "0", count: -pointPos) + digits
        } else if pointPos >= digits.count {
            result = digits + String(repeating: "0", count: pointPos - digits.count)
        } else {
            let idx = digits.index(digits.startIndex, offsetBy: pointPos)
            result = String(digits[..<idx]) + "." + String(digits[idx...])
        }
        if result.contains(".") {
            while result.hasSuffix("0") { result.removeLast() }
            if result.hasSuffix(".") { result.removeLast() }
        }
        return (negative ? "-" : "") + result
    }

    /// Rust `str::parse::<f64>` grammar (no hex, no underscores; `inf`/`nan` words).
    public static func parseRustFloat(_ s: String) -> Double? {
        var chars = Substring(s)
        var sign = 1.0
        if chars.first == "+" || chars.first == "-" {
            if chars.first == "-" { sign = -1 }
            chars = chars.dropFirst()
        }
        let lower = chars.lowercased()
        if lower == "inf" || lower == "infinity" { return sign * .infinity }
        if lower == "nan" { return .nan }
        var sawDigit = false
        var idx = chars.startIndex
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        while idx < chars.endIndex, isDigit(chars[idx]) { sawDigit = true; idx = chars.index(after: idx) }
        if idx < chars.endIndex, chars[idx] == "." {
            idx = chars.index(after: idx)
            while idx < chars.endIndex, isDigit(chars[idx]) { sawDigit = true; idx = chars.index(after: idx) }
        }
        guard sawDigit else { return nil }
        if idx < chars.endIndex, chars[idx] == "e" || chars[idx] == "E" {
            idx = chars.index(after: idx)
            if idx < chars.endIndex, chars[idx] == "+" || chars[idx] == "-" { idx = chars.index(after: idx) }
            var expDigit = false
            while idx < chars.endIndex, isDigit(chars[idx]) { expDigit = true; idx = chars.index(after: idx) }
            guard expDigit else { return nil }
        }
        guard idx == chars.endIndex else { return nil }
        var body = String(chars)
        if body.hasPrefix(".") { body = "0" + body }
        if body.hasSuffix(".") { body += "0" }
        body = body.replacingOccurrences(of: ".e", with: ".0e").replacingOccurrences(of: ".E", with: ".0E")
        guard let v = Double(body) else { return nil }
        return sign * v
    }

    /// `parse_value`.
    public static func parseValue(_ s: String) -> ConfigValue {
        let trimmed = rustTrim(s)
        if trimmed.lowercased() == "true" && trimmed.utf8.count == 4 { return .bool(true) }
        if trimmed.lowercased() == "false" && trimmed.utf8.count == 5 { return .bool(false) }
        if let n = parseRustFloat(trimmed), n.isFinite { return .number(n) }
        return .string(trimmed)
    }

    // MARK: Lines

    /// Rust `str::lines`: splits on `\n`, strips one trailing `\r` per line, and
    /// does not yield a final empty line after a trailing newline.
    public static func rustLines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Rust `str::trim` (Unicode White_Space).
    public static func rustTrim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, scalars[start].properties.isWhitespace { start = scalars.index(after: start) }
        while end > start, scalars[scalars.index(before: end)].properties.isWhitespace { end = scalars.index(before: end) }
        return String(scalars[start..<end])
    }

    private static func splitOnce(_ s: String, _ sep: Character) -> (String, String)? {
        guard let idx = s.firstIndex(of: sep) else { return nil }
        return (String(s[..<idx]), String(s[s.index(after: idx)...]))
    }

    // MARK: Parse / serialize

    /// `parse_config`. Returns key → value.
    public static func parse(_ content: String) -> [String: ConfigValue] {
        var map: [String: ConfigValue] = [:]
        var listKeys: [String: [String]] = [:]
        for line in rustLines(content) {
            let trimmed = rustTrim(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let (rawKey, rawValue) = splitOnce(trimmed, "=") else { continue }
            let key = rustTrim(rawKey)
            let valueStr = rustTrim(rawValue)
            if listKeys[key] != nil {
                listKeys[key]!.append(valueStr)
            } else if let first = map.removeValue(forKey: key) {
                let firstStr: String
                switch first {
                case let .string(s): firstStr = s
                case let .number(n): firstStr = formatNumber(n)
                case let .bool(b): firstStr = b ? "true" : "false"
                case let .list(l): firstStr = l.joined(separator: ", ")
                }
                listKeys[key] = [firstStr, valueStr]
            } else {
                map[key] = parseValue(valueStr)
            }
        }
        for (key, values) in listKeys { map[key] = .list(values) }
        return map
    }

    private static func emit(_ key: String, _ value: ConfigValue, into result: inout String) {
        if case let .list(items) = value {
            for item in items { result += "\(key) = \(item)\n" }
        } else {
            result += "\(key) = \(valueToString(value))\n"
        }
    }

    /// `serialize_config`: rewrites `original` in place (comments, blanks and
    /// unrecognised lines kept; removed keys dropped; list keys written at the
    /// position of their first line), then appends new keys (sorted, for
    /// determinism — Rust iterates a HashMap here).
    public static func serialize(_ values: [String: ConfigValue], original: String) -> String {
        var result = ""
        var written = Set<String>()
        for line in rustLines(original) {
            let trimmed = rustTrim(line)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                result += line + "\n"
                continue
            }
            if let (rawKey, _) = splitOnce(trimmed, "=") {
                let key = rustTrim(rawKey)
                if written.contains(key) { continue }
                if let value = values[key] {
                    emit(key, value, into: &result)
                    written.insert(key)
                }
            } else {
                result += line + "\n"
            }
        }
        for key in values.keys.sorted() where !written.contains(key) {
            emit(key, values[key]!, into: &result)
        }
        return result
    }

    /// `remove_key_from_config`.
    public static func removeKey(_ key: String, from original: String) -> String {
        var result = ""
        for line in rustLines(original) {
            let trimmed = rustTrim(line)
            if let (k, _) = splitOnce(trimmed, "="), rustTrim(k) == key { continue }
            result += line + "\n"
        }
        return result
    }
}

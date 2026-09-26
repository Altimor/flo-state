import Foundation

/// Order-preserving JSON value used for the app-data files (sessions, recents)
/// so that unknown fields round-trip and output matches `serde_json`'s
/// `to_string_pretty` byte-for-byte (2-space indent, `"key": value`).
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            // Object equality is key-set based, like serde's Map.
            for (k, v) in a {
                guard let other = b.first(where: { $0.0 == k })?.1, other == v else { return false }
            }
            return true
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(pairs) = self { return pairs.first(where: { $0.0 == key })?.1 }
        return nil
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectValue: [(String, JSONValue)]? { if case let .object(o) = self { return o }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var doubleValue: Double? {
        switch self {
        case let .int(i): return Double(i)
        case let .double(d): return d
        default: return nil
        }
    }
    public var intValue: Int64? {
        switch self {
        case let .int(i): return i
        case let .double(d) where d.rounded() == d && abs(d) < 9.2e18: return Int64(d)
        default: return nil
        }
    }
    public var isNull: Bool { if case .null = self { return true }; return false }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "JSON parse error: \(message)" }
}

public enum JSON {
    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.b.count else { throw JSONParseError(message: "trailing characters") }
        return v
    }

    public static func parse(data: Data) throws -> JSONValue {
        guard let s = String(data: data, encoding: .utf8) else { throw JSONParseError(message: "invalid utf8") }
        return try parse(s)
    }

    /// `serde_json::to_string_pretty` formatting.
    public static func prettyString(_ value: JSONValue) -> String {
        var out = ""
        write(value, indent: 0, into: &out)
        return out
    }

    private static func write(_ v: JSONValue, indent: Int, into out: inout String) {
        switch v {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .int(i): out += String(i)
        case let .double(d): out += formatDouble(d)
        case let .string(s): out += quote(s)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (idx, item) in items.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                write(item, indent: indent + 1, into: &out)
                if idx < items.count - 1 { out += "," }
                out += "\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (idx, (k, item)) in pairs.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                out += quote(k) + ": "
                write(item, indent: indent + 1, into: &out)
                if idx < pairs.count - 1 { out += "," }
                out += "\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        }
    }

    static func formatDouble(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded() && abs(d) < 1e16 { return String(Int64(d)) + ".0" }
        return "\(d)"
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        mutating func value() throws -> JSONValue {
            guard i < b.count else { throw JSONParseError(message: "unexpected end") }
            switch b[i] {
            case UInt8(ascii: "{"):
                i += 1
                var pairs: [(String, JSONValue)] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                while true {
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw JSONParseError(message: "expected key") }
                    let k = try string()
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw JSONParseError(message: "expected :") }
                    i += 1
                    skipWS()
                    let v = try value()
                    if let idx = pairs.firstIndex(where: { $0.0 == k }) { pairs[idx].1 = v } else { pairs.append((k, v)) }
                    skipWS()
                    guard i < b.count else { throw JSONParseError(message: "unterminated object") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                    throw JSONParseError(message: "expected , or }")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [JSONValue] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipWS()
                    items.append(try value())
                    skipWS()
                    guard i < b.count else { throw JSONParseError(message: "unterminated array") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw JSONParseError(message: "expected , or ]")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true"); return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false"); return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null"); return .null
            default:
                return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { throw JSONParseError(message: "bad literal") }
            i += w.count
        }

        mutating func number() throws -> JSONValue {
            let start = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            var isFloat = false
            while i < b.count {
                let c = b[i]
                if c >= 0x30 && c <= 0x39 { i += 1; continue }
                if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") || c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                    isFloat = true; i += 1; continue
                }
                break
            }
            guard i > start, let s = String(bytes: b[start..<i], encoding: .utf8) else { throw JSONParseError(message: "bad number") }
            if !isFloat, let v = Int64(s) { return .int(v) }
            guard let d = Double(s) else { throw JSONParseError(message: "bad number \(s)") }
            return .double(d)
        }

        mutating func string() throws -> String {
            i += 1 // opening quote
            var bytes: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: bytes, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { break }
                    let e = b[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "n"): bytes.append(0x0A)
                    case UInt8(ascii: "t"): bytes.append(0x09)
                    case UInt8(ascii: "r"): bytes.append(0x0D)
                    case UInt8(ascii: "b"): bytes.append(0x08)
                    case UInt8(ascii: "f"): bytes.append(0x0C)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if code >= 0xD800 && code < 0xDC00, i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: bytes.append(e)
                    }
                    continue
                }
                bytes.append(c)
                i += 1
            }
            throw JSONParseError(message: "unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let s = String(bytes: b[i..<i + 4], encoding: .ascii), let v = UInt32(s, radix: 16) else {
                throw JSONParseError(message: "bad \\u escape")
            }
            i += 4
            return v
        }
    }
}

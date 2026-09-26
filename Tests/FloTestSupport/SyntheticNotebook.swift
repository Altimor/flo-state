import Foundation

/// Deterministic synthetic markdown for tests that need a large, realistic
/// document: a dated notebook (`## yyyy.mm.dd` sections) mixing paragraphs,
/// bullet/task/ordered lists, sub-headings, quotes, links and inline marks.
/// Mirrors `oracle/make_sandbox.py`'s Journal.md (same shape, not byte-identical).
public enum SyntheticNotebook {
    static let words = """
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et \
    dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea \
    commodo consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur \
    excepteur sint occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum
    """.split(separator: " ").map(String.init)

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    static func sentence(_ r: inout RNG, _ lo: Int = 6, _ hi: Int = 16) -> String {
        var ws = (0..<r.int(lo, hi)).map { _ in r.pick(words) }
        let i = r.int(0, ws.count - 1), k = r.unit()
        if k < 0.08 { ws[i] = "**\(ws[i])**" }
        else if k < 0.14 { ws[i] = "*\(ws[i])*" }
        else if k < 0.18 { ws[i] = "`\(ws[i])`" }
        else if k < 0.21 { ws[i] = "[\(ws[i])](https://example.com/\(ws[i]))" }
        else if k < 0.24 { ws[i] = r.pick(["[[Notes]]", "[[Groceries]]", "[[Project Alpha]]"]) }
        let s = ws.joined(separator: " ")
        return s.prefix(1).uppercased() + s.dropFirst() + r.pick([".", ".", ".", "?", "!"])
    }

    static func paragraph(_ r: inout RNG, _ n: Int? = nil) -> String {
        (0..<(n ?? r.int(1, 4))).map { _ in sentence(&r) }.joined(separator: " ")
    }

    /// About `bytes` UTF-8 bytes (default ~110 KB) of dated notebook markdown, ending with a newline.
    public static func journal(bytes: Int = 110_000, seed: UInt64 = 7) -> String {
        var r = RNG(state: seed)
        var lines = ["# Journal", "", paragraph(&r, 2), ""]
        var size = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var day = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        func add(_ l: String) { lines.append(l); size += l.utf8.count + 1 }
        while size < bytes {
            let c = cal.dateComponents([.year, .month, .day], from: day)
            add(String(format: "## %04d.%02d.%02d", c.year!, c.month!, c.day!)); add("")
            for _ in 0..<r.int(1, 4) {
                let k = r.unit()
                if k < 0.35 {
                    add(paragraph(&r)); add("")
                } else if k < 0.6 {
                    for _ in 0..<r.int(2, 5) {
                        add("* " + sentence(&r, 3, 10))
                        if r.unit() < 0.3 { add("  * " + sentence(&r, 3, 8)) }
                    }
                    add("")
                } else if k < 0.75 {
                    for _ in 0..<r.int(2, 4) { add("- [\(r.unit() < 0.4 ? "x" : " ")] " + sentence(&r, 2, 7)) }
                    add("")
                } else if k < 0.85 {
                    for i in 0..<r.int(2, 4) { add("\(i + 1). " + sentence(&r, 3, 9)) }
                    add("")
                } else if k < 0.92 {
                    let h = (0..<r.int(1, 4)).map { _ in r.pick(words) }.joined(separator: " ")
                    add("### " + h.prefix(1).uppercased() + h.dropFirst()); add("")
                    add(paragraph(&r, 1)); add("")
                } else {
                    add("> " + sentence(&r)); add("")
                }
            }
            day = cal.date(byAdding: .day, value: r.int(1, 3), to: day)!
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }
}

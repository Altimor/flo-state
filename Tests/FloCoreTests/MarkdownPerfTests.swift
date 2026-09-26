import XCTest
import FloCore
import FloTestSupport

/// Rough parse benchmark: ~20KB of notebook-style markdown.
final class MarkdownPerfTests: XCTestCase {
    func testParse20KB() {
        let doc = String(SyntheticNotebook.journal(bytes: 21_000).utf16.prefix(20_000))!
        _ = FloMarkdown.parse(doc)
        let runs = 50
        let t0 = Date()
        var nodes = 0
        for _ in 0..<runs { nodes = FloMarkdown.parse(doc).dump().count }
        let ms = Date().timeIntervalSince(t0) * 1000 / Double(runs)
        print(String(format: "MARKDOWN PARSE: %d UTF-16 units, %d nodes, %.3f ms/parse (incl. dump)", doc.utf16.count, nodes, ms))
        XCTAssertLessThan(ms, 200)
    }
}

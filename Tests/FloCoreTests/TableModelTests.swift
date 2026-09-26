import XCTest
@testable import FloCore

final class TableModelTests: XCTestCase {
    func testParseTable() {
        let t = ParsedTable.parse("| a | b |\n|:--|--:|\n| 1 | 2 |\n")!
        XCTAssertEqual(t.headers, ["a", "b"])
        XCTAssertEqual(t.alignments, [.left, .right])
        XCTAssertEqual(t.rows, [["1", "2"]])
        XCTAssertNil(ParsedTable.parse("| a |\n| x |\n"))
        XCTAssertEqual(ParsedTable.parseCells("a \\| b | c"), ["a \\| b", "c"])
    }

    func testCellInline() {
        XCTAssertEqual(CellMarkdown.parse("~~old~~ *soft*"), [
            .element(tag: .s, className: nil, href: nil, wikiTarget: nil, children: [.text("old")]),
            .text(" "),
            .element(tag: .em, className: nil, href: nil, wikiTarget: nil, children: [.text("soft")]),
        ])
        XCTAssertEqual(CellMarkdown.parse("see [[Page|Alias]] `[[x]]`"), [
            .text("see "),
            .element(tag: .span, className: "cm-wiki-link", href: nil, wikiTarget: "Page|Alias", children: [.text("Alias")]),
            .text(" "),
            .element(tag: .code, className: "cm-inline-code", href: nil, wikiTarget: nil, children: [.text("[[x]]")]),
        ])
    }
}

import XCTest
@testable import FloCore

final class TableGridTests: XCTestCase {
    let src = "| a | b |\n| --- | ---: |\n| 1 | 2 |\n| 3 | 4 |"

    func testRoundTrip() {
        let g = TableGrid(markdown: src)!
        XCTAssertEqual(g.rows, [["a", "b"], ["1", "2"], ["3", "4"]])
        XCTAssertEqual(g.alignments, [nil, .right])
        XCTAssertEqual(g.markdown, src)
    }

    func testEmptyTableParsesAndRenders() {
        let md = TableGrid.empty(rows: 3, columns: 2).markdown
        XCTAssertEqual(md, "|  |  |\n| --- | --- |\n|  |  |\n|  |  |")
        XCTAssertNotNil(ParsedTable.parse(md))
        let plan = RenderPlanner.plan(EditorState(md + "\n"))
        XCTAssertTrue(plan.widgets.contains { if case .table = $0.kind { return true }; return false })
    }

    func testRowsAndColumns() {
        var g = TableGrid(markdown: src)!
        g.insertRow(at: 1)
        XCTAssertEqual(g.rows[1], ["", ""])
        g.deleteRow(1)
        g.insertColumn(at: 1)
        XCTAssertEqual(g.rows.map { $0.count }, [3, 3, 3])
        XCTAssertEqual(g.alignments, [nil, nil, .right])
        g.deleteColumn(1)
        XCTAssertEqual(g.markdown, src)
        g.moveRow(2, to: 0)
        XCTAssertEqual(g.rows.map { $0[0] }, ["3", "a", "1"])
        g.moveColumn(1, to: 0)
        XCTAssertEqual(g.rows[0], ["4", "3"])
        XCTAssertEqual(g.alignments, [.right, nil])
        // never below one row / column
        var one = TableGrid.empty(rows: 1, columns: 1)
        one.deleteRow(0); one.deleteColumn(0)
        XCTAssertEqual(one.rowCount, 1); XCTAssertEqual(one.columnCount, 1)
    }

    func testCellTextEscaping() {
        var g = TableGrid(markdown: src)!
        g.setCell(1, 0, editable: "x | y\nsecond line")
        XCTAssertEqual(g.rows[1][0], "x \\| y<br>second line")
        XCTAssertEqual(TableGrid.editableText(g.rows[1][0]), "x | y\nsecond line")
        XCTAssertEqual(TableGrid(markdown: g.markdown)!.rows[1][0], "x \\| y<br>second line")
    }

    func testWidthsInDashes() {
        var g = TableGrid(markdown: src)!
        XCTAssertNil(ParsedTable.parse(g.markdown)!.explicitWidths(unit: 8))
        g.setWidths([80, 200], unit: 8)
        XCTAssertEqual(g.dashes, [10, 25])
        let t = ParsedTable.parse(g.markdown)!
        XCTAssertEqual(t.explicitWidths(unit: 8), [80, 200])
        XCTAssertEqual(t.alignments, [nil, .right])
        g.setWidths([100, 100], unit: 8)
        XCTAssertNotNil(ParsedTable.parse(g.markdown)!.explicitWidths(unit: 8), "equal widths stay explicit")
        g.setWidths(nil, unit: 8)
        XCTAssertNil(ParsedTable.parse(g.markdown)!.explicitWidths(unit: 8))
    }

    func testTablesRenderWhateverTheSelectionUnlessMarkdown() {
        let doc = "x\n\n" + src + "\n"
        let inside = (doc as NSString).range(of: "| 1").location + 2
        let st = EditorState(doc, selection: .cursor(inside))
        func hasTable(_ p: RenderPlan) -> Bool { p.widgets.contains { if case .table = $0.kind { return true }; return false } }
        XCTAssertTrue(hasTable(RenderPlanner.plan(st)), "the table editor stays even with the caret inside")
        let start = (doc as NSString).range(of: "| a").location
        XCTAssertFalse(hasTable(RenderPlanner.plan(st, markdownTables: [start])), "markdown mode shows the source")
    }
}

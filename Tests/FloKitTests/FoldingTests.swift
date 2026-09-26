import XCTest
import AppKit
@testable import FloKit
import FloCore

@MainActor
final class FoldingTests: XCTestCase {
    let doc = "# Title\n\n## A\none\ntwo\n### A1\nthree\n## B\nfour\n"

    func lineTop(_ r: KeyReplayer, _ pos: Int) -> CGFloat {
        let tlm = r.controller.textView.textLayoutManager!, tcm = tlm.textContentManager!
        tlm.ensureLayout(for: tlm.documentRange)
        let f = tlm.textLayoutFragment(for: tcm.location(tcm.documentRange.location, offsetBy: pos)!)!
        return f.layoutFragmentFrame.minY + (f.textLineFragments.first?.typographicBounds.minY ?? 0)
    }

    func testSections() {
        let s = HeadingSections.all(Text(doc))
        let t = Text(doc)
        XCTAssertEqual(s.keys.sorted(), [1, 3, 6, 8])
        XCTAssertEqual(s[3], Fold(from: t.line(3).to, to: t.line(7).to))   // ## A swallows ### A1
        XCTAssertEqual(s[6], Fold(from: t.line(6).to, to: t.line(7).to))
        XCTAssertEqual(s[8], Fold(from: t.line(8).to, to: t.line(10).to))  // to doc end
        XCTAssertEqual(s[1], Fold(from: t.line(1).to, to: t.line(10).to))
        XCTAssertTrue(HeadingSections.all(Text("## lonely")).isEmpty)
        XCTAssertTrue(HeadingSections.all(Text("#nospace\nx")).isEmpty)
    }

    func testFoldHidesAndNavigates() {
        let r = KeyReplayer()
        r.load(doc, selection: .cursor(0))
        let t = Text(doc)
        let bTop = lineTop(r, t.line(8).from)
        XCTAssertTrue(r.controller.toggleFold(line: 3))
        XCTAssertEqual(r.controller.folds.count, 1)
        // "## B" moves up to right under "## A"
        let aTop = lineTop(r, t.line(3).from)
        let bTopFolded = lineTop(r, t.line(8).from)
        XCTAssertLessThan(bTopFolded, bTop - 50)
        XCTAssertLessThan(bTopFolded - aTop, 70)
        // Down from the heading lands on the next visible line
        r.controller.textView.setSelectedRange(NSRange(location: t.line(3).to, length: 0))
        let vl = r.controller.layout.visualLine(at: t.line(3).to, assoc: 0, state: r.controller.state)
        XCTAssertEqual(vl.map { [$0.from, $0.to] }, [t.line(3).from, t.line(3).to], "visual line")
        let direct = r.controller.layout.moveVertically(r.controller.state, .cursor(t.line(3).to), forward: true)
        XCTAssertEqual(t.lineAt(direct.head).number, 8, "direct layout; folded=\(Array(r.controller.applier.foldedLines)) sel=\(r.selection.main.head)")
        r.press("Down")
        XCTAssertEqual(t.lineAt(r.selection.main.head).number, 8)
        // Right at the heading end jumps over the folded section
        r.controller.textView.setSelectedRange(NSRange(location: t.line(3).to, length: 0))
        r.press("Right")
        XCTAssertEqual(r.selection.main.head, t.line(7).to)
        // typing above maps the fold
        r.controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        r.press("t:X")
        XCTAssertEqual(r.controller.folds, [Fold(from: t.line(3).to + 1, to: t.line(7).to + 1)])
        // unfold restores layout
        XCTAssertTrue(r.controller.toggleFold(line: 3))
        XCTAssertTrue(r.controller.folds.isEmpty)
        XCTAssertEqual(lineTop(r, t.line(8).from + 1), bTop, accuracy: 0.5)
    }

    func testCollapseExpandAll() {
        let r = KeyReplayer()
        r.load(doc, selection: .cursor(0))
        XCTAssertTrue(r.controller.collapseAllHeadings())
        // depth >= 2 only: ## A, ### A1, ## B
        XCTAssertEqual(r.controller.folds.count, 3)
        XCTAssertTrue(r.controller.expandAllHeadings())
        XCTAssertTrue(r.controller.folds.isEmpty)
    }

    func testEditingInsideDropsFold() {
        let r = KeyReplayer()
        let t = Text(doc)
        r.load(doc, selection: .cursor(0))
        r.controller.toggleFold(line: 8)
        // delete across the fold boundary
        r.controller.textView.setSelectedRange(NSRange(location: t.line(8).from, length: t.length - t.line(8).from))
        r.press("Backspace")
        XCTAssertTrue(r.controller.folds.isEmpty)
        XCTAssertEqual(r.controller.textView.string, r.doc)
    }
}

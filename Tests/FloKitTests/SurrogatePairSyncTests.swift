import XCTest
@testable import FloKit
@testable import FloCore

final class SurrogatePairSyncTests: XCTestCase {
    func check(_ doc: String, at: Int, type: String, replacing len: Int = 0, line: UInt = #line) {
        let c = EditorController(theme: EditorTheme())
        c.load(doc, selection: .cursor(at))
        c.textView.setSelectedRange(NSRange(location: at, length: len))
        c.textView.insertText(type, replacementRange: NSRange(location: NSNotFound, length: 0))
        let s = c.state.doc.string
        print("CASE", doc.debugDescription, "->", s.debugDescription, "| view", c.textView.string.debugDescription)
        XCTAssertFalse(s.contains("\u{FFFD}"), line: line)
        XCTAssertFalse(c.textView.string.contains("\u{FFFD}"), line: line)
    }
    func testTypingEmojiInTables() {
        let t = "| Item | Status |\n| --- | --- |\n| First row |  |\n"
        let cell = (t as NSString).range(of: "|  |").location + 2
        check(t, at: cell, type: "🔴")
        let t2 = "| Item | Status |\n| --- | --- |\n| First row | 🟢 |\n"
        let e = (t2 as NSString).range(of: "🟢").location
        check(t2, at: e, type: "🔴", replacing: 2)
        check(t2, at: e + 2, type: "🔴")
        check(t2, at: e, type: "🔴")
        check("a 🟢 b", at: 2, type: "🔴", replacing: 2)
    }
}

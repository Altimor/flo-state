import XCTest
@testable import FloCore

final class OrderedListIndentTests: XCTestCase {
    /// Put the caret at "|" and press keys; returns the text with "|" at the caret.
    func run(_ text: String, _ keys: [String]) -> String {
        let caret = (text as NSString).range(of: "|").location
        let doc = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        let s = EditorSession(state: EditorState(doc: Text(doc), selection: .cursor(caret)))
        for k in keys { _ = s.handle(k) }
        let out = s.state.doc.string as NSString
        return out.replacingCharacters(in: NSRange(location: s.state.selection.main.head, length: 0), with: "|")
    }

    func testIndentStartsNestedListAtOneAndRenumbersOuter() {
        XCTAssertEqual(run("1. a\n2. b|\n3. c\n", ["Tab"]), "1. a\n   1. b|\n2. c\n")
    }
    func testIndentJoinsExistingSubList() {
        XCTAssertEqual(run("1. a\n   1. x\n2. b|\n3. c\n", ["Tab"]), "1. a\n   1. x\n   2. b|\n2. c\n")
    }
    func testOutdentReturnsToParentLevel() {
        XCTAssertEqual(run("1. a\n   1. b|\n2. c\n", ["Shift-Tab"]), "1. a\n2. b|\n3. c\n")
    }
    func testFirstItemCannotIndent() {
        XCTAssertEqual(run("1. a|\n2. b\n", ["Tab"]), "1. a|\n2. b\n")
    }
    func testTypingSequence() {
        // type the user's example: Enter continues, Tab nests at 1, Shift-Tab back continues at 2
        let s = EditorSession(state: EditorState(doc: Text("1. xxx"), selection: .cursor(6)))
        _ = s.handle("Enter"); _ = s.insertText("xxx"); _ = s.handle("Tab")
        _ = s.handle("Enter"); _ = s.handle("Shift-Tab"); _ = s.insertText("xxx")
        XCTAssertEqual(s.state.doc.string, "1. xxx\n   1. xxx\n2. xxx")
    }
    func testBulletsUnaffected() {
        XCTAssertEqual(run("- a\n- b|\n", ["Tab"]), "- a\n  - b|\n")
    }
}

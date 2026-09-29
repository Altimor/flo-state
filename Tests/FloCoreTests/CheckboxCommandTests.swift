import XCTest
@testable import FloCore

final class CheckboxCommandTests: XCTestCase {
    func run(_ text: String, _ keys: [String]) -> String {
        let caret = (text as NSString).range(of: "|").location
        let doc = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        let s = EditorSession(state: EditorState(doc: Text(doc), selection: .cursor(caret)))
        for k in keys { if k.hasPrefix("t:") { s.insertText(String(k.dropFirst(2))) } else { _ = s.handle(k) } }
        return (s.state.doc.string as NSString).replacingCharacters(in: NSRange(location: s.state.selection.main.head, length: 0), with: "|")
    }
    func testCmdShift9MakesCheckboxes() {
        XCTAssertEqual(run("- bul|let", ["Mod-Shift-9"]), "- [ ] bul|let")
        XCTAssertEqual(run("  3. item|", ["Mod-Shift-9"]), "  - [ ] item|")
        XCTAssertEqual(run("plain|", ["Mod-Shift-9"]), "- [ ] plain|")
        XCTAssertEqual(run("|", ["Mod-Shift-9"]), "- [ ] |")
        XCTAssertEqual(run("- [ ] task|", ["Mod-Shift-9"]), "- task|", "toggles back to a bullet")
    }
    func testCmdShift8And7ConvertAnyListLine() {
        XCTAssertEqual(run("- [ ] task|", ["Mod-Shift-8"]), "- task|")
        XCTAssertEqual(run("  - [x] done|", ["Mod-Shift-8"]), "  - done|")
        XCTAssertEqual(run("2. item|", ["Mod-Shift-8"]), "- item|")
        XCTAssertEqual(run("- bul|let", ["Mod-Shift-8"]), "bul|let", "toggles off, caret kept")
        XCTAssertEqual(run("plain|", ["Mod-Shift-8"]), "- plain|")
        XCTAssertEqual(run("- [ ] task|", ["Mod-Shift-7"]), "1. task|")
        XCTAssertEqual(run("  - bullet|", ["Mod-Shift-7"]), "  1. bullet|")
        XCTAssertEqual(run("1. item|", ["Mod-Shift-7"]), "item|", "toggles off")
    }
    /// Converting a checkbox to a bullet keeps the caret in place, so typing extends the item instead of
    /// replacing the whole line (bullet included).
    func testTypingAfterConvertingKeepsTheBullet() {
        XCTAssertEqual(run("- [ ] task|", ["Mod-Shift-8", "t:x"]), "- taskx|")
        XCTAssertEqual(run("- [ ] |", ["Mod-Shift-8", "t:a"]), "- a|")
        XCTAssertEqual(run("- [ ] task|", ["Mod-Shift-7", "t:x"]), "1. taskx|")
    }
    func testCmdDotMarksDone() {
        XCTAssertEqual(run("- [ ] a|", ["Mod-."]), "- [x] a|")
        XCTAssertEqual(run("- [x] a|", ["Mod-."]), "- [ ] a|")
        XCTAssertEqual(run("  - [ ] nested|", ["Mod-."]), "  - [x] nested|")
    }
}

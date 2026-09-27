import XCTest
@testable import FloCore

final class CheckboxCommandTests: XCTestCase {
    func run(_ text: String, _ keys: [String]) -> String {
        let caret = (text as NSString).range(of: "|").location
        let doc = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        let s = EditorSession(state: EditorState(doc: Text(doc), selection: .cursor(caret)))
        for k in keys { _ = s.handle(k) }
        return (s.state.doc.string as NSString).replacingCharacters(in: NSRange(location: s.state.selection.main.head, length: 0), with: "|")
    }
    func testCmdShift9MakesCheckboxes() {
        XCTAssertEqual(run("- bul|let", ["Mod-Shift-9"]), "- [ ] bul|let")
        XCTAssertEqual(run("  3. item|", ["Mod-Shift-9"]), "  - [ ] item|")
        XCTAssertEqual(run("plain|", ["Mod-Shift-9"]), "- [ ] plain|")
        XCTAssertEqual(run("|", ["Mod-Shift-9"]), "- [ ] |")
        XCTAssertEqual(run("- [ ] task|", ["Mod-Shift-9"]), "- task|", "toggles back to a bullet")
    }
    func testCmdDotMarksDone() {
        XCTAssertEqual(run("- [ ] a|", ["Mod-."]), "- [x] a|")
        XCTAssertEqual(run("- [x] a|", ["Mod-."]), "- [ ] a|")
        XCTAssertEqual(run("  - [ ] nested|", ["Mod-."]), "  - [x] nested|")
    }
}

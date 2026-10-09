import XCTest
@testable import FloCore

final class LinkSpanTests: XCTestCase {
    func apply(_ doc: String, _ from: Int, _ to: Int, _ cmd: Command) -> String {
        let s = EditorSession(state: EditorState(doc: Text(doc), selection: .single(from, to)))
        _ = s.run(cmd)
        return s.state.doc.string
    }

    /// Shift-Cmd-Left from the end of a bullet selects the whole line (marker included): Cmd-K links only the text.
    func testLinkSkipsLinePrefixes() {
        XCTAssertEqual(apply("- item text", 0, 11, Formatting.insertLink), "- [item text](url)")
        XCTAssertEqual(apply("  * [ ] task", 0, 12, Formatting.insertLink), "  * [ ] [task](url)")
        XCTAssertEqual(apply("## Title", 0, 8, Formatting.insertLink), "## [Title](url)")
        XCTAssertEqual(apply("plain words", 6, 11, Formatting.insertLink), "plain [words](url)")
    }

    func testBoldSkipsCheckboxToo() {
        XCTAssertEqual(apply("- [ ] task", 0, 10, Formatting.toggleBold), "- [ ] **task**")
        XCTAssertEqual(apply("- item", 0, 6, Formatting.toggleBold), "- **item**")
    }
}

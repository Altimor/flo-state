import XCTest
@testable import FloCore

/// Mod-B / Mod-I pressed again undo what the first press did (they used to stack markers).
final class FormatToggleTests: XCTestCase {
    private func press(_ text: String, _ anchor: Int, _ head: Int, _ keys: [String]) -> (String, Int, Int) {
        let s = EditorSession(state: EditorState(text, selection: .single(anchor, head)))
        for k in keys { s.handle(k) }
        let m = s.state.selection.main
        return (s.state.doc.string, m.from, m.to)
    }

    func testBoldTwiceOnAWordAtTheCaret() {
        let once = press("say hello now", 6, 6, ["Mod-b"])
        XCTAssertEqual(once.0, "say **hello** now")
        let twice = press("say hello now", 6, 6, ["Mod-b", "Mod-b"])
        XCTAssertEqual(twice.0, "say hello now")
        XCTAssertEqual(twice.1, 4); XCTAssertEqual(twice.2, 9)
    }

    func testBoldTwiceOnASelection() {
        XCTAssertEqual(press("say hello now", 4, 9, ["Mod-b"]).0, "say **hello** now")
        let twice = press("say hello now", 4, 9, ["Mod-b", "Mod-b"])
        XCTAssertEqual(twice.0, "say hello now")
        XCTAssertEqual(twice.1, 4); XCTAssertEqual(twice.2, 9)
        XCTAssertEqual(press("say hello now", 4, 9, ["Mod-b", "Mod-b", "Mod-b"]).0, "say **hello** now")
    }

    func testBoldTwiceOnAnEmptySpot() {
        // only the opening marker: no auto-closed pair
        XCTAssertEqual(press("a  b", 2, 2, ["Mod-b"]).0, "a ** b")
        XCTAssertEqual(press("a  b", 2, 2, ["Mod-i"]).0, "a * b")
        let twice = press("a  b", 2, 2, ["Mod-b", "Mod-b"])
        XCTAssertEqual(twice.0, "a  b")
        XCTAssertEqual(twice.1, 2)
    }

    func testItalicTwiceAndInsideBold() {
        XCTAssertEqual(press("say hello now", 4, 9, ["Mod-i", "Mod-i"]).0, "say hello now")
        XCTAssertEqual(press("say hello now", 6, 6, ["Mod-i", "Mod-i"]).0, "say hello now")
        // italic on bold text and back
        XCTAssertEqual(press("say **hello** now", 6, 11, ["Mod-i"]).0, "say ***hello*** now")
        XCTAssertEqual(press("say **hello** now", 6, 11, ["Mod-i", "Mod-i"]).0, "say **hello** now")
        // bold inside italic doesn't mistake the italic star for bold
        XCTAssertEqual(press("say *hello* now", 5, 10, ["Mod-b"]).0, "say ***hello*** now")
    }
}

/// Cmd-Left on a list item lands after the marker, not before the hidden "- ".
final class ListLineStartTests: XCTestCase {
    private func home(_ text: String, _ caret: Int, _ key: String = "Mod-ArrowLeft") -> (Int, Int) {
        let s = EditorSession(state: EditorState(text, selection: .cursor(caret)))
        s.handle(key)
        return (s.state.selection.main.anchor, s.state.selection.main.head)
    }

    func testCmdLeftStopsAfterTheMarker() {
        XCTAssertEqual(home("- hello", 7).1, 2)
        XCTAssertEqual(home("  * nested item", 15).1, 4)
        XCTAssertEqual(home("- [ ] task", 10).1, 6)
        XCTAssertEqual(home("- [x] done", 10).1, 6)
        XCTAssertEqual(home("12. twelfth", 11).1, 4)
        XCTAssertEqual(home("plain line", 10).1, 0)
        XCTAssertEqual(home("- hello", 7, "Shift-Mod-ArrowLeft").0, 7)
        XCTAssertEqual(home("- hello", 7, "Shift-Mod-ArrowLeft").1, 2)
    }

    func testStartingBoldOnABulletKeepsItABullet() {
        // "* **" is a rule in CommonMark; while typing on a bullet it must stay a list item
        let names = { (t: String) -> [String] in
            var out: [String] = []
            func walk(_ n: SyntaxNode) { out.append(n.name); n.children.forEach(walk) }
            walk(FloMarkdown.parse(t).root)
            return out
        }
        XCTAssertFalse(names("- a\n    * **").contains("HorizontalRule"))
        XCTAssertFalse(names("* **").contains("HorizontalRule"))
        XCTAssertTrue(names("a\n\n* * *").contains("HorizontalRule"))
        XCTAssertTrue(names("a\n\n***").contains("HorizontalRule"))
        XCTAssertTrue(names("a\n\n---").contains("HorizontalRule"))
    }
}

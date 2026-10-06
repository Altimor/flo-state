import XCTest
@testable import FloCore
@testable import FloKit

/// Typing re-plans only around the edit, wherever it is in the note (the end of the note used to
/// re-plan and restyle the whole document on every keystroke).
final class PlanCacheTests: XCTestCase {
    private func typeAtEnd(_ text: String, _ keys: [String]) -> [String?] {
        let cache = PlanCache()
        let s = EditorSession(state: EditorState(text, selection: .cursor(text.utf16.count)))
        _ = cache.update(s.state)
        var reasons: [String?] = []
        for k in keys {
            if k == "Enter" || k == "Backspace" { s.handle(k) } else { s.insertText(k) }
            let u = cache.update(s.state)
            reasons.append(u.dirtyLines == nil ? (cache.fullReason ?? "?") : nil)
        }
        return reasons
    }

    func testTypingAtTheEndOfAListIsIncremental() {
        let text = "# Notes\n\nSome text.\n\n- one\n- two\n- three"
        let r = typeAtEnd(text, ["x", "y", "Enter", "a", "b", "Enter", "Backspace", "Backspace", "z"])
        XCTAssertEqual(r.compactMap { $0 }, [], "\(r)")
    }

    func testTypingAtTheEndOfAParagraphIsIncremental() {
        let text = "# Notes\n\n- a\n- b\n\nLast paragraph"
        let r = typeAtEnd(text, ["x", "Enter", "y", "Enter", "Enter", "q", "Backspace"])
        XCTAssertEqual(r.compactMap { $0 }, [], "\(r)")
    }

    func testTypingAtTheEndAfterANewlineIsIncremental() {
        let text = "# Notes\n\n- a\n- b\n"
        let r = typeAtEnd(text, ["x", "Enter", "y", "Backspace", "Backspace"])
        XCTAssertEqual(r.compactMap { $0 }, [], "\(r)")
    }
}

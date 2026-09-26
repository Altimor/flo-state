import XCTest
import AppKit
@testable import FloKit
import FloCore

@MainActor
final class CaretTests: XCTestCase {
    /// The empty line after a trailing newline must put the caret at the text column, not x=0.
    func testCaretOnTrailingEmptyLine() {
        let r = KeyReplayer()
        let doc = "# Test\n\ntest test test\n\n"
        r.load(doc, selection: .cursor(doc.utf16.count))
        let tv = r.controller.textView
        let end = tv.firstRect(forCharacterRange: NSRange(location: doc.utf16.count, length: 0), actualRange: nil)
        let body = tv.firstRect(forCharacterRange: NSRange(location: 8, length: 0), actualRange: nil)
        XCTAssertEqual(end.minX, body.minX, accuracy: 1)
        // still true after typing a newline at the end
        r.press("Enter")
        let end2 = tv.firstRect(forCharacterRange: NSRange(location: r.doc.utf16.count, length: 0), actualRange: nil)
        XCTAssertEqual(end2.minX, body.minX, accuracy: 1)
    }
}

import AppKit
import XCTest
@testable import FloCore
@testable import FloKit

@MainActor
final class CheckboxClickTests: XCTestCase {
    var window: NSWindow!
    override func tearDown() { window?.close(); window = nil }

    func editor(_ text: String) -> EditorController {
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let c = EditorController(theme: EditorTheme())
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = content
        c.scrollView.frame = content.bounds
        content.addSubview(c.scrollView)
        c.layoutColumn()
        c.load(text, selection: .cursor(text.utf16.count))
        c.layoutColumn()
        content.layoutSubtreeIfNeeded()
        return c
    }

    /// The point just left of a line's text (where the box is drawn).
    func boxPoint(_ c: EditorController, contentAt pos: Int, dx: CGFloat = -14) -> NSPoint {
        let screen = c.textView.firstRect(forCharacterRange: NSRange(location: pos, length: 0), actualRange: nil)
        let r = c.textView.convert(window.convertFromScreen(screen), from: nil)
        return NSPoint(x: r.minX + dx, y: r.midY)
    }

    func testClickingTheBoxTogglesIt() {
        let c = editor("# Today\n- [ ] Task A\n- [ ] Task B\n\nend")
        let a = ("# Today\n- [ ] " as NSString).length
        XCTAssertTrue(c.toggleCheckbox(at: boxPoint(c, contentAt: a)))
        XCTAssertEqual(c.text, "# Today\n- [x] Task A\n- [ ] Task B\n\nend")
        XCTAssertTrue(c.toggleCheckbox(at: boxPoint(c, contentAt: a)))
        XCTAssertEqual(c.text, "# Today\n- [ ] Task A\n- [ ] Task B\n\nend")
        // clicking the text itself doesn't toggle
        XCTAssertFalse(c.toggleCheckbox(at: boxPoint(c, contentAt: a + 2, dx: 0)))
        XCTAssertEqual(c.text, "# Today\n- [ ] Task A\n- [ ] Task B\n\nend")
        // nested item
        let c2 = editor("- [ ] A\n  - [ ] C\n")
        let cpos = ("- [ ] A\n  - [ ] " as NSString).length
        XCTAssertTrue(c2.toggleCheckbox(at: boxPoint(c2, contentAt: cpos)))
        XCTAssertEqual(c2.text, "- [ ] A\n  - [x] C\n")
    }
}

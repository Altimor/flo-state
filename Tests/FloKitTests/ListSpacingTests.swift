import AppKit
import XCTest
@testable import FloCore
@testable import FloKit

@MainActor
final class ListSpacingTests: XCTestCase {
    var window: NSWindow!
    override func tearDown() { window?.close(); window = nil }

    func makeEditor(_ text: String) -> EditorController {
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let c = EditorController(theme: EditorTheme())
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        window.contentView = content
        c.scrollView.frame = content.bounds
        content.addSubview(c.scrollView)
        c.layoutColumn()
        c.load(text, selection: .cursor(0))
        c.layoutColumn()
        let tlm = c.textView.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        return c
    }

    /// Top of line `n`'s glyphs, growing downwards (screen rects grow upwards).
    func top(_ c: EditorController, line n: Int) -> CGFloat {
        let l = c.state.doc.line(n)
        return -c.textView.firstRect(forCharacterRange: NSRange(location: l.to - 1, length: 1), actualRange: nil).maxY
    }

    /// Text directly above a list sits as far from the first bullet as the bullets are from each other.
    func testTextAboveAListGetsTheBulletGap() throws {
        let c = makeEditor("Intro\n- first item\n- second item\n")
        let textToFirst = top(c, line: 2) - top(c, line: 1)
        let bulletToBullet = top(c, line: 3) - top(c, line: 2)
        XCTAssertEqual(textToFirst, bulletToBullet, accuracy: 0.5)
        // edit the line above away: the first bullet loses the extra gap again (incremental re-apply)
        _ = c.run { t in t.dispatch(TransactionSpec(changes: [Change(from: 0, to: 6, insert: "")])); return true }
        let tlm = c.textView.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        XCTAssertEqual(c.text, "- first item\n- second item\n")
        XCTAssertEqual(top(c, line: 2) - top(c, line: 1), bulletToBullet, accuracy: 0.5)
    }
}

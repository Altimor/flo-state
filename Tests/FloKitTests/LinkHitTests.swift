import AppKit
import XCTest
@testable import FloCore
@testable import FloKit

/// A link opens only when the click is on its characters, not merely nearest to them.
@MainActor
final class LinkHitTests: XCTestCase {
    var window: NSWindow!
    override func tearDown() { window?.close(); window = nil }

    func testOnlyClicksOnTheLinkTextHitIt() throws {
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let c = EditorController(theme: EditorTheme())
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        window.contentView = content
        c.scrollView.frame = content.bounds
        content.addSubview(c.scrollView)
        c.layoutColumn()
        let text = "Intro line\nsee [the docs](https://example.com)\n\nlast line\n"
        c.load(text, selection: .cursor(0))   // caret away from the link: it renders as link text
        c.layoutColumn()
        let tlm = c.textView.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        let tv = c.textView
        func box(_ i: Int) -> CGRect { tv.convert(window.convertFromScreen(tv.firstRect(forCharacterRange: NSRange(location: i, length: 1), actualRange: nil)), from: nil) }
        let linkChar = (text as NSString).range(of: "docs").location
        let on = box(linkChar)
        XCTAssertNotNil(tv.linkHit(at: NSPoint(x: on.midX, y: on.midY)), "on the link text")
        let lineEnd = box((text as NSString).range(of: ")\n").location - 1)
        XCTAssertNil(tv.linkHit(at: NSPoint(x: max(on.maxX, lineEnd.maxX) + 200, y: on.midY)), "blank space after the line")
        XCTAssertNil(tv.linkHit(at: NSPoint(x: on.midX, y: on.maxY + on.height * 1.2)), "the empty line below")
        let see = box((text as NSString).range(of: "see").location)
        XCTAssertNil(tv.linkHit(at: NSPoint(x: see.midX, y: see.midY)), "plain text before it on the same line")
    }
}

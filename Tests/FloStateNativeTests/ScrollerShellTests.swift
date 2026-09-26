import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative
import FloTestSupport

/// The scroller must reflect the real position: at the end of the document the
/// knob is at the bottom (live bug: it showed the middle).
@MainActor
final class ScrollerShellTests: XCTestCase {
    var wc: ShellWindowController!
    var f: ShellFixture!

    override func tearDown() async throws { wc?.window?.close(); wc = nil }

    func knob(_ c: EditorController) -> (value: Double, docH: CGFloat, textBottom: CGFloat) {
        let tv = c.textView, tlm = tv.textLayoutManager!
        var maxY: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fr in
            maxY = fr.layoutFragmentFrame.maxY; return false
        }
        c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
        return (c.scrollView.verticalScroller?.doubleValue ?? -1, tv.frame.height, maxY + tv.textContainerOrigin.y)
    }

    func testScrollerAtBottomAfterOpenResizeAndTyping() async throws {
        let big = SyntheticNotebook.journal()
        f = ShellFixture(files: ["big.md": big, "small.md": "hi"], config: "editor.jump-to-bottom-after-minutes = 0\n")
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        try await f.model.editor.openFileInTabOrFocus(f.p("small.md"))
        try await f.model.editor.openFileInTabOrFocus(f.p("big.md"))
        await f.settle()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        guard let c = wc.root.area.activeFilePane?.controller else { return XCTFail("no editor") }
        func settle() async { for _ in 0..<5 { await Task.yield(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }; wc.window?.displayIfNeeded() }
        func checkAtEnd(_ label: String) async {
            c.textView.setSelectedRange(NSRange(location: (c.textView.string as NSString).length, length: 0))
            c.textView.scrollRangeToVisible(c.textView.selectedRange())
            let clip = c.scrollView.contentView
            let docH = c.textView.frame.height
            clip.scroll(to: NSPoint(x: 0, y: max(0, docH - clip.bounds.height)))
            await settle()
            let k = knob(c)
            // 40vh bottom padding is part of the text view's height (FloTextView.bottomPadding)
            let pad = 0.4 * (wc.window?.contentView?.bounds.height ?? 0)
            XCTAssertEqual(k.docH, k.textBottom + pad, accuracy: 80, "\(label): doc height vs text (web: last line + 40vh, no bottom inset)")
            XCTAssertGreaterThan(k.value, 0.97, "\(label): knob at bottom")
        }
        await settle()
        await checkAtEnd("open")
        wc.window!.setContentSize(NSSize(width: 900, height: 700)); wc.root.layoutSubtreeIfNeeded()
        await settle()
        await checkAtEnd("after resize")
        wc.window!.setContentSize(NSSize(width: 1400, height: 900)); wc.root.layoutSubtreeIfNeeded()
        await settle()
        await checkAtEnd("after resize back")
        try await f.model.editor.openFileInTabOrFocus(f.p("small.md")); await f.settle()
        try await f.model.editor.openFileInTabOrFocus(f.p("big.md")); await f.settle()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        await settle()
        await checkAtEnd("after tab switch")
    }
}

@MainActor
final class ChromeHitTests: XCTestCase {
    /// With the unified toolbar, clicks in the tab row must still reach the tab buttons.
    func testTabRowReceivesClicks() async throws {
        let f = ShellFixture(files: ["a.md": "a", "b.md": "b"], config: "editor.jump-to-bottom-after-minutes = 0\n")
        let wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        defer { wc.window?.close() }
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        try await f.model.editor.openFileInTabOrFocus(f.p("b.md"))
        await f.settle()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        let tabs = wc.root.tabs
        let theme = wc.window!.contentView!.superview!
        let mid = tabs.convert(NSPoint(x: 40, y: 16), to: nil)
        let hit = theme.hitTest(theme.convert(mid, from: nil))
        var v = hit
        while let x = v, x !== tabs { v = x.superview }
        XCTAssertTrue(v === tabs, "hit \(String(describing: hit))")
    }
}

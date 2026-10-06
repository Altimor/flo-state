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

    /// Checking a box near the top while the caret is at the end of a long note doesn't scroll to the caret.
    func testClickingTheBoxDoesNotScroll() {
        let body = (1...200).map { "Line \($0) of filler text" }.joined(separator: "\n")
        let c = editor("- [ ] Top task\n" + body)
        let clip = c.scrollView.contentView
        clip.scroll(to: .zero)
        c.scrollView.reflectScrolledClipView(clip)
        XCTAssertTrue(c.toggleCheckbox(at: boxPoint(c, contentAt: ("- [ ] " as NSString).length)))
        XCTAssertTrue(c.text.hasPrefix("- [x] Top task"))
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 1)
    }

    /// Checking a box plays a short pop over it.
    func testCheckingPopsTheBox() {
        let c = editor("- [ ] Task A\n")
        c.textView.wantsLayer = true
        // draw the box (and record where): offscreen windows only draw fragments through cacheDisplay
        let tv = c.textView, r = tv.visibleRect
        if let rep = tv.bitmapImageRepForCachingDisplay(in: r) { tv.cacheDisplay(in: r, to: rep) }
        XCTAssertNotNil(c.checkboxRects[0])
        XCTAssertTrue(c.toggleCheckbox(at: boxPoint(c, contentAt: ("- [ ] " as NSString).length)))
        let pops = c.textView.layer?.sublayers?.filter { $0.animation(forKey: "pop") != nil } ?? []
        XCTAssertEqual(pops.count, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1)
    }

    /// Checking with the mouse mentions the shortcut, the first three times only.
    func testShortcutTipShowsThreeTimes() {
        let key = EditorController.checkboxTipKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(0, forKey: key)
        let c = editor("- [ ] Task A\n")
        let p = boxPoint(c, contentAt: ("- [ ] " as NSString).length)
        for _ in 0..<5 { XCTAssertTrue(c.toggleCheckbox(at: p)) }
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), 3)
        XCTAssertNotNil(c.checkboxTip)
    }

    /// Clicking quickly (the second click is a double-click) toggles every time.
    func testQuickClicksAllToggle() {
        let c = editor("- [ ] Task A\n")
        let p = boxPoint(c, contentAt: ("- [ ] " as NSString).length)
        let w = c.textView.convert(p, to: nil)
        for n in 1...3 {
            let e = NSEvent.mouseEvent(with: .leftMouseDown, location: w, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: n, clickCount: n, pressure: 1)!
            c.textView.mouseDown(with: e)
        }
        XCTAssertEqual(c.text, "- [x] Task A\n", "three clicks: checked, unchecked, checked")
    }
}

import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

@MainActor
final class ToggleSidebarKeyTests: XCTestCase {
    var wc: ShellWindowController!
    var f: ShellFixture!
    override func tearDown() async throws { wc?.window?.close(); wc = nil }

    func testCmdBackslashTogglesSidebarWithEditorFocused() async throws {
        f = ShellFixture(files: ["a.md": "alpha"])
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        let router = MenuRouter(); router.focusedModel = { [unowned self] in self.f.model }
        let saved = NSApp.mainMenu; NSApp.mainMenu = MainMenu.build(target: router); defer { NSApp.mainMenu = saved }
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.settle(); wc.flush(); wc.root.layoutSubtreeIfNeeded()
        let w = try XCTUnwrap(wc.window)
        XCTAssertTrue(w.firstResponder is NSTextView, "editor focused")
        XCTAssertTrue(f.model.sidebarVisible)
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber,
                                 context: nil, characters: "\\", charactersIgnoringModifiers: "\\", isARepeat: false, keyCode: 42)!
        let passed = wc.handleKey(e)
        if passed != nil { _ = w.performKeyEquivalent(with: e) }
        await f.settle(); wc.flush(); wc.root.layoutSubtreeIfNeeded()
        XCTAssertFalse(f.model.sidebarVisible, "Cmd-\\ hides the sidebar")
    }

    func testSidebarToggleButtonReceivesClicks() async throws {
        f = ShellFixture(files: ["a.md": "a"])
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.settle(); wc.flush(); wc.root.layoutSubtreeIfNeeded()
        let btn = wc.root.sidebar.toggle
        let theme = wc.window!.contentView!.superview!
        let mid = btn.convert(NSPoint(x: btn.bounds.midX, y: btn.bounds.midY), to: nil)
        let hit = theme.hitTest(theme.convert(mid, from: nil))
        var v = hit
        while let x = v, x !== btn { v = x.superview }
                XCTAssertTrue(v === btn, "hit \(String(describing: hit))")
        btn.action?()
        await f.settle(); wc.flush()
        XCTAssertFalse(f.model.sidebarVisible)
    }

    func testToggleHidesSidebarViewWithRealRunLoop() async throws {
        f = ShellFixture(files: ["a.md": "a"])
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.settle(); wc.flush(); wc.root.layoutSubtreeIfNeeded()
        func spin(_ t: Double) { let end = Date().addingTimeInterval(t); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); wc.window?.displayIfNeeded() } }
        XCTAssertFalse(wc.root.sidebar.isHidden)
        f.model.toggleSidebar()
        spin(0.6)
        wc.flush(); wc.root.layoutSubtreeIfNeeded()   // XCTest's main-actor task starves the queued flush
        spin(0.6)
        XCTAssertTrue(wc.root.sidebar.isHidden, "sidebar view hidden after toggle")
        f.model.toggleSidebar()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        spin(0.6)
        XCTAssertFalse(wc.root.sidebar.isHidden)
    }

    func testCollapsedToggleReceivesClicks() async throws {
        f = ShellFixture(files: ["a.md": "a"], config: "appearance.sidebar-visible = false\n")
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.settle(); wc.flush(); wc.root.needsLayout = true; wc.root.layoutSubtreeIfNeeded()
        let btn = wc.root.collapsedToggle
        XCTAssertFalse(btn.isHidden)
        let theme = wc.window!.contentView!.superview!
        let mid = btn.convert(NSPoint(x: btn.bounds.midX, y: btn.bounds.midY), to: nil)
        let hit = theme.hitTest(theme.convert(mid, from: nil))
        var v = hit
        while let x = v, x !== btn { v = x.superview }
                XCTAssertTrue(v === btn, "hit \(String(describing: hit))")
        // the window-drag strip must not swallow clicks on the button (live bug)
        let c = NSPoint(x: btn.frame.midX, y: btn.frame.midY)
        XCTAssertNil(wc.root.dragRegion.hitTest(wc.root.convert(c, to: wc.root.dragRegion.superview)))
    }
}

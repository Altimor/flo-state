import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

/// Switching tabs puts keyboard focus in the new tab's editor.
@MainActor
final class TabFocusTests: XCTestCase {
    var wc: ShellWindowController!
    var f: ShellFixture!

    override func tearDown() async throws { wc?.window?.close(); wc = nil }

    func testSwitchingTabsFocusesEditor() async throws {
        f = ShellFixture(files: ["a.md": "alpha", "b.md": "beta"])
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        try await f.model.editor.openFileInTabOrFocus(f.p("b.md"))
        await f.settle()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        let w = try XCTUnwrap(wc.window)
        for (n, path) in [(1, "a.md"), (2, "b.md"), (1, "a.md")] {
            w.makeFirstResponder(wc.root)   // focus elsewhere (e.g. after clicking the tab strip)
            f.model.editor.activateTab(number: n)
            await f.settle()
            wc.flush(); wc.root.layoutSubtreeIfNeeded()
            let pane = try XCTUnwrap(wc.root.area.activeFilePane)
            XCTAssertEqual(pane.path, f.p(path))
            XCTAssertTrue(w.firstResponder === pane.controller?.textView, "tab \(n): editor not focused")
        }
    }
}

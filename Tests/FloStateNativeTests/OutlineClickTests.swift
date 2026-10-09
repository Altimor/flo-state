import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

/// The heading outline on the right of the editor: clicking an entry jumps to that heading.
@MainActor
final class OutlineClickTests: XCTestCase {
    var wc: ShellWindowController!
    var f: ShellFixture!

    override func tearDown() async throws { wc?.window?.close(); wc = nil }

    func refresh() { wc.flush(); wc.root.layoutSubtreeIfNeeded() }

    func doc() -> String {
        var s = "# Title\n\n"
        for i in 1...12 {
            s += "## Section \(i)\n\n" + String(repeating: "Some paragraph text that takes up room in the note.\n\n", count: 8)
        }
        return s
    }

    func send(_ type: NSEvent.EventType, at p: CGPoint, in view: NSView) {
        let ev = NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: wc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        wc.window!.sendEvent(ev)
    }

    func testClickingAnOutlineEntryJumpsToTheHeading() async throws {
        f = ShellFixture(files: ["a.md": doc()], config: "editor.jump-to-bottom-after-minutes = 0\n")
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1400, height: 900), offscreen: true)
        wc.root.animationsEnabled = false
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.settle()
        refresh()
        let rail = wc.root.area.rail
        XCTAssertGreaterThan(rail.headings.count, 10)
        rail.openPopover()
        let pop = try XCTUnwrap(rail.popover)
        let target = try XCTUnwrap(rail.headings.firstIndex { $0.text == "Section 9" })
        // the row's centre, in the popover list's coordinates (rows: 12 + i * 23.5, 19.5 high)
        let list = pop.scroll.documentView!
        let rowY = 12 + CGFloat(target) * 23.5 + 9.75
        pop.scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, rowY - pop.bounds.height / 2)))
        let p = CGPoint(x: 60, y: rowY)
        // the click goes through the window's own routing (hit-testing, mouse-down then mouse-up), as in the app
        wc.window!.makeKeyAndOrderFront(nil)
        if wc.window!.isKeyWindow {
            send(.leftMouseDown, at: p, in: list)
            send(.leftMouseUp, at: p, in: list)
        } else {
            // an offscreen test window can't become key: deliver the pair to the view the window hit-tests
            let content = wc.window!.contentView!
            let hit = try XCTUnwrap(content.hitTest(content.convert(list.convert(p, to: nil), from: nil)))
            func ev(_ t: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: list.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                   windowNumber: wc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            hit.mouseDown(with: ev(.leftMouseDown))
            hit.mouseUp(with: ev(.leftMouseUp))
        }
        refresh()
        let pane = try XCTUnwrap(wc.root.area.activeFilePane)
        let c = try XCTUnwrap(pane.controller)
        let h = rail.headings[target]
        let line = c.state.doc.lineAt(h.pos)
        XCTAssertEqual(c.state.doc.lineAt(c.state.selection.main.head).number, line.number, "the caret is on the heading line")
        let r = try XCTUnwrap(c.rect(forPosition: h.pos, in: c.textView))
        XCTAssertTrue(c.textView.visibleRect.contains(CGPoint(x: r.midX, y: r.midY)), "the heading is on screen")
    }
}

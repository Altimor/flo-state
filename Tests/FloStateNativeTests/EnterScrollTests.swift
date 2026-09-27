import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative
import FloTestSupport

/// Live bug: pressing Return scrolls the view somewhere random (at the end of the
/// document the pane goes blank). The caret must stay visible after every Return.
@MainActor
final class EnterScrollTests: XCTestCase {
    func enterEvent(_ w: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: false, keyCode: 36)!
    }

    func run(typewriter: Bool) async throws {
        let big = SyntheticNotebook.journal(bytes: 25_000)   // ~8 screens: enough for viewport layout, 4× faster than 110 KB
        let f = ShellFixture(files: ["big.md": big + "\n## 2026.09.26\n\nBefore pressing the return key"],
                             config: "editor.jump-to-bottom-after-minutes = 0\n")
        // A real on-screen window (fully transparent, never key): the live bug
        // needs TextKit's viewport layout, which offscreen windows don't exercise.
        let wc = ShellWindowController(model: f.model, frame: NSRect(x: 100, y: 100, width: 1400, height: 900), offscreen: true)
        wc.window!.alphaValue = 0
        wc.window!.ignoresMouseEvents = true
        wc.window!.orderFrontRegardless()
        defer { wc.window?.close() }
        print("progress: EnterScroll opening workspace"); fflush(stdout)
        await f.open()
        if !typewriter { f.model.typewriterScrolling = false }
        try await f.model.editor.openFileInTabOrFocus(f.p("big.md"))
        print("progress: EnterScroll note open"); fflush(stdout)
        await f.settle()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        guard let pane = wc.root.area.activeFilePane, let c = pane.controller else { return XCTFail("no editor") }
        wc.window!.makeFirstResponder(c.textView)
        func settle() async { for _ in 0..<10 { await Task.yield(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)); wc.window!.displayIfNeeded() } }
        var jumps: [String] = []
        var lastY = c.scrollView.contentView.bounds.origin.y
        let obs = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: c.scrollView.contentView, queue: nil) { _ in
            MainActor.assumeIsolated {
                let y = c.scrollView.contentView.bounds.origin.y
                if abs(y - lastY) > 300 { jumps.append("\(Int(lastY))->\(Int(y)) docH=\(Int(c.textView.frame.height))") }
                lastY = y
            }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        func check(_ label: String) {
            let clip = c.scrollView.contentView.bounds
            guard let caret = c.rect(forPosition: c.state.selection.main.head, in: c.textView) else { return XCTFail("\(label): no caret rect") }
            XCTAssertTrue(clip.intersects(caret), "\(label): caret \(caret) outside visible \(clip) (doc h \(c.textView.frame.height))")
        }
        // at the very end
        c.textView.setSelectedRange(NSRange(location: (c.textView.string as NSString).length, length: 0))
        c.textView.scrollRangeToVisible(c.textView.selectedRange()); await settle()
        lastY = c.scrollView.contentView.bounds.origin.y; jumps = []
        for i in 0..<6 { c.textView.keyDown(with: enterEvent(wc.window!)); await settle(); check("end, return #\(i + 1)"); print("progress: EnterScroll end return #\(i + 1)"); fflush(stdout) }
        XCTAssertEqual(jumps, [], "no scroll jumps while pressing Return at the end")
        jumps = []
        // in the middle of the document
        let mid = (c.textView.string as NSString).length / 2
        c.textView.setSelectedRange(NSRange(location: mid, length: 0))
        c.textView.scrollRangeToVisible(c.textView.selectedRange()); await settle()
        let before = c.scrollView.contentView.bounds.origin.y
        lastY = c.scrollView.contentView.bounds.origin.y; jumps = []
        for i in 0..<3 { c.textView.keyDown(with: enterEvent(wc.window!)); await settle(); print("progress: EnterScroll middle return #\(i + 1)"); fflush(stdout) }
        check("middle")
        XCTAssertEqual(jumps, [], "no scroll jumps while pressing Return in the middle")
        if !typewriter {
            XCTAssertLessThan(abs(c.scrollView.contentView.bounds.origin.y - before), 60, "no big jump on Return in the middle")
        }
    }

    func testReturnKeepsCaretVisibleTypewriter() async throws { try await run(typewriter: true) }
    func testReturnKeepsCaretVisibleNoTypewriter() async throws { try await run(typewriter: false) }
}

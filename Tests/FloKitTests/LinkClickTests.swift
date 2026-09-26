import XCTest
import AppKit
@testable import FloKit
import FloCore

@MainActor
final class LinkClickTests: XCTestCase {
    /// Window point of the middle of char `pos` (text view coordinates → window).
    func point(_ r: KeyReplayer, _ pos: Int) -> NSPoint {
        let screen = r.controller.textView.firstRect(forCharacterRange: NSRange(location: pos, length: 1), actualRange: nil)
        let win = r.window.convertFromScreen(screen)
        return NSPoint(x: win.midX, y: win.midY)
    }

    func click(_ r: KeyReplayer, _ pos: Int) {
        let p = point(r, pos)
        func ev(_ t: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: r.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let tv = r.controller.textView
        if tv.controller?.link(at: tv.characterIndexForInsertion(at: tv.convert(p, from: nil))) != nil {
            tv.mouseDown(with: ev(.leftMouseDown))
            tv.mouseUp(with: ev(.leftMouseUp))
        } else {
            // NSTextView.mouseDown tracks until a mouseUp arrives in the queue
            NSApp.postEvent(ev(.leftMouseUp), atStart: false)
            tv.mouseDown(with: ev(.leftMouseDown))
        }
    }

    func testLinkClicks() {
        let r = KeyReplayer()
        let doc = "see [site](https://x.com) and [[My Note]] end\n\nother line"
        r.load(doc, selection: .cursor(doc.utf16.count))
        var got: [EditorController.LinkClick] = []
        r.controller.onLinkClick = { got.append($0) }
        let ns = doc as NSString
        let sp = ns.range(of: "site").location + 1
        XCTAssertEqual(r.controller.link(at: sp), .href("https://x.com"), "style: \(r.controller.currentPlan!.style(at: sp))")
        let tv = r.controller.textView
        let wp = point(r, sp)
        XCTAssertEqual(tv.characterIndexForInsertion(at: tv.convert(wp, from: nil)), sp, "wp=\(wp) rect=\(tv.firstRect(forCharacterRange: NSRange(location: sp, length: 1), actualRange: nil)) win=\(r.window.frame)")
        click(r, sp)
        XCTAssertEqual(got, [.href("https://x.com")])
        XCTAssertEqual(r.selection.main.head, doc.utf16.count, "caret must not move on a link click")
        click(r, ns.range(of: "[[My").location + 1)
        XCTAssertEqual(got.last, .wiki("My Note"))
        // plain text click moves the caret normally
        got.removeAll()
        click(r, ns.range(of: "other").location + 2)
        XCTAssertTrue(got.isEmpty)
        XCTAssertNotEqual(r.selection.main.head, doc.utf16.count)
    }
}

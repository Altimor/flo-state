import AppKit
import XCTest
@testable import FloCore
@testable import FloKit

@MainActor
final class ImageResizeTests: XCTestCase {
    var window: NSWindow!
    override func tearDown() { window?.close(); window = nil }

    func makeEditor(_ text: String, caret: Int = 0) -> (EditorController, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgr-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 800, height: 400)); img.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 800, height: 400).fill(); img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try! png.write(to: dir.appendingPathComponent("attachments/i.png"))
        let doc = dir.appendingPathComponent("n.md").path
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let c = EditorController(theme: EditorTheme())
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        window.contentView = content
        c.scrollView.frame = content.bounds
        content.addSubview(c.scrollView)
        c.layoutColumn()
        c.documentPath = doc
        c.load(text, selection: .cursor(caret))
        c.layoutColumn()
        c.waitForAsyncWidgets()
        let tlm = c.textView.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        content.layoutSubtreeIfNeeded()
        content.wantsLayer = true
        c.textView.needsDisplay = true
        content.display()
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)   // draws the fragments (records image rects)
        return (c, doc)
    }

    func testDrawnRectIsHitAndResizeWritesWidth() throws {
        let (c, _) = makeEditor("# T\n\n![shot @2x.png](attachments/i.png)\n\nafter\n")
        let hit = try XCTUnwrap(c.imageRects.values.first, "image drawn and recorded")
        XCTAssertGreaterThan(hit.rect.width, 100)
        // the recorded rect is where the pixels are: blue at its centre
        let content = c.scrollView.superview!
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        let mid = c.textView.convert(NSPoint(x: hit.rect.midX, y: hit.rect.midY), to: content)
        let px = rep.colorAt(x: Int(mid.x * CGFloat(rep.pixelsWide) / content.bounds.width),
                             y: Int((content.bounds.height - mid.y) * CGFloat(rep.pixelsHigh) / content.bounds.height))!
        XCTAssertGreaterThan(px.blueComponent, 0.6); XCTAssertLessThan(px.redComponent, 0.4)
        XCTAssertEqual(c.image(at: NSPoint(x: hit.rect.midX, y: hit.rect.midY)), hit)
        // hover shows the handle overlay
        c.imageOverlay.show(hit)
        XCTAssertFalse(c.imageOverlay.isHidden)
        // the corner is on the handle (text view keeps the resize cursor there), the middle isn't
        XCTAssertTrue(c.imageOverlay.handleContains(NSPoint(x: hit.rect.maxX, y: hit.rect.maxY)))
        XCTAssertFalse(c.imageOverlay.handleContains(NSPoint(x: hit.rect.midX, y: hit.rect.midY)))
        // resize writes |N into the alt text; undo restores
        c.setImageWidth(from: hit.from, to: hit.to, width: 320)
        XCTAssertEqual(c.text, "# T\n\n![shot @2x.png|320](attachments/i.png)\n\nafter\n")
        _ = c.handleKey("Mod-z")
        XCTAssertEqual(c.text, "# T\n\n![shot @2x.png](attachments/i.png)\n\nafter\n")
    }

    func testPresetsReplaceAndRemoveWidth() throws {
        let (c, _) = makeEditor("x\n\n![a | 200](attachments/i.png)\n")
        let hit = try XCTUnwrap(c.imageRects.values.first)
        let items = c.imageSizeMenuItems(for: hit)
        XCTAssertEqual(items.map(\.title), ["Image Size: Small", "Image Size: Medium", "Image Size: Large", "Image Size: Full Width", "Image Size: Original Size"])
        c.setImageWidth(from: hit.from, to: hit.to, width: nil)
        XCTAssertEqual(c.text, "x\n\n![a](attachments/i.png)\n")
        c.setImageWidth(from: hit.from, to: c.state.doc.length - 1, width: 150)
        XCTAssertEqual(c.text, "x\n\n![a|150](attachments/i.png)\n")
    }

    /// Live bug: with the caret on the image's line (e.g. right after pasting), the widget is a
    /// zero-length marker after the source, and resizing did nothing.
    func testResizeWithCaretOnTheImageLine() throws {
        let text = "x\n![shot](attachments/i.png)\n"
        let (c, _) = makeEditor(text, caret: 10)
        let hit = try XCTUnwrap(c.imageRects.values.first)
        XCTAssertEqual(hit.from, hit.to, "touched: zero-length widget")
        c.setImageWidth(from: hit.from, to: hit.to, width: 250)
        XCTAssertEqual(c.text, "x\n![shot|250](attachments/i.png)\n")
    }

    /// The real drag path: events queued, then the handle's mouseDown tracks them and commits.
    func testDraggingTheHandleResizes() throws {
        let (c, _) = makeEditor("x\n\n![shot](attachments/i.png)\n\nend\n")
        let hit = try XCTUnwrap(c.imageRects.values.first)
        c.imageOverlay.show(hit)
        let w = try XCTUnwrap(c.textView.window)
        let corner = c.textView.convert(NSPoint(x: hit.rect.maxX, y: hit.rect.maxY), to: nil)
        func ev(_ t: NSEvent.EventType, dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: NSPoint(x: corner.x + dx, y: corner.y), modifierFlags: [], timestamp: 0,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // queued events come back offset by the (offscreen, x = -10000) window origin: compensate
        let o = -w.frame.origin.x
        NSApp.postEvent(ev(.leftMouseDragged, dx: -150 + o), atStart: false)
        NSApp.postEvent(ev(.leftMouseUp, dx: -200 + o), atStart: false)
        c.imageOverlay.mouseDown(with: ev(.leftMouseDown, dx: 0))
        let want = Int((hit.rect.width - 200).rounded())
        XCTAssertEqual(c.text, "x\n\n![shot|\(want)](attachments/i.png)\n\nend\n")
    }
}

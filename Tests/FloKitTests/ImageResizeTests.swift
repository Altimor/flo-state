import AppKit
import XCTest
@testable import FloCore
@testable import FloKit

@MainActor
final class ImageResizeTests: XCTestCase {
    var window: NSWindow!
    override func tearDown() { window?.close(); window = nil }

    func makeEditor(_ text: String, caret: Int = 0, workspace: Bool = false) -> (EditorController, String) {
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
        if workspace { c.workspaceRoot = dir.path }
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

    /// A 3-page, 400×500pt PDF with a red first page, next to the note.
    func writePDF(_ dir: String) {
        let url = URL(fileURLWithPath: dir + "/attachments/doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 0..<3 {
            ctx.beginPDFPage(nil)
            if page == 0 { ctx.setFillColor(NSColor.systemRed.cgColor); ctx.fill(CGRect(x: 50, y: 50, width: 300, height: 400)) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    func testPDFRendersAsAPageCardWithQuickLook() throws {
        let (c0, doc) = makeEditor("x\n")
        writePDF((doc as NSString).deletingLastPathComponent)
        c0.applier.images.invalidate()
        c0.load("# T\n\n![doc](attachments/doc.pdf)\n\nafter\n", selection: .cursor(0))
        c0.layoutColumn(); c0.waitForAsyncWidgets()
        let tlm = c0.textView.textLayoutManager!; tlm.ensureLayout(for: tlm.documentRange)
        let content = c0.scrollView.superview!
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        let hit = try XCTUnwrap(c0.imageRects.values.first, "PDF drawn and recorded")
        XCTAssertEqual(hit.url?.pathExtension, "pdf")
        XCTAssertEqual(hit.rect.width, PDFCard.defaultWidth, accuracy: 1, "compact preview by default")
        XCTAssertEqual(hit.rect.height, PDFCard.defaultWidth * 500 / 400, accuracy: 1, "first page's proportions")
        XCTAssertEqual(c0.applier.images.resolve(markdownSource: "attachments/doc.pdf")?.pdfPageCount, 3)
        // the first page's red rectangle is drawn at the card's centre
        let mid = c0.textView.convert(NSPoint(x: hit.rect.midX, y: hit.rect.midY), to: content)
        let px = rep.colorAt(x: Int(mid.x * CGFloat(rep.pixelsWide) / content.bounds.width),
                             y: Int((content.bounds.height - mid.y) * CGFloat(rep.pixelsHigh) / content.bounds.height))!
        XCTAssertGreaterThan(px.redComponent, 0.6); XCTAssertLessThan(px.blueComponent, 0.4)
        // the Quick Look button is hit exactly where it is drawn, not elsewhere on the card
        let q = PDFCard.quickLookRect(in: hit.rect)
        XCTAssertEqual(c0.pdfQuickLookURL(at: NSPoint(x: q.midX, y: q.midY))?.lastPathComponent, "doc.pdf")
        XCTAssertNil(c0.pdfQuickLookURL(at: NSPoint(x: hit.rect.midX, y: hit.rect.midY)))
        XCTAssertTrue(hit.rect.contains(q))
        // hover: the overlay paints the Quick Look chip (light) over the page's red, only while shown
        c0.imageOverlay.show(hit)
        XCTAssertFalse(c0.imageOverlay.isHidden)
        XCTAssertFalse(c0.imageOverlay.handleContains(NSPoint(x: q.midX, y: q.midY)), "the button isn't under the resize handle")
        let ov = c0.imageOverlay
        let orep = ov.bitmapImageRepForCachingDisplay(in: ov.bounds)!
        ov.cacheDisplay(in: ov.bounds, to: orep)
        let local = PDFCard.quickLookRect(in: CGRect(x: ImageResizeOverlay.handle, y: ImageResizeOverlay.handle, width: hit.rect.width, height: hit.rect.height))
        let chip = orep.colorAt(x: Int(local.midX * CGFloat(orep.pixelsWide) / ov.bounds.width),
                                y: Int((local.minY + 3) * CGFloat(orep.pixelsHigh) / ov.bounds.height))!   // the chip's fill, above the icon
        XCTAssertGreaterThan(chip.alphaComponent, 0.8, "Quick Look chip drawn on hover")
        XCTAssertGreaterThan(chip.greenComponent, 0.8, "light, not dark")
        c0.imageOverlay.show(nil)
        XCTAssertTrue(c0.imageOverlay.isHidden, "hidden when not hovered")
    }

    func click(_ c: EditorController, at p: NSPoint, count: Int) {
        let w = c.textView.convert(p, to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        window.postEvent(ev(.leftMouseUp), atStart: false)  // ends NSTextView's tracking loop, if it runs one
        c.textView.mouseDown(with: ev(.leftMouseDown))
        while NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) != nil {}  // unconsumed mouse-up
    }

    /// Double-clicking a rendered image opens its file (never launches anything here) and
    /// leaves the selection where it was before the first click.
    func testDoubleClickOpensTheImageFile() throws {
        for (text, embed) in [("# T\n\n![shot](attachments/i.png)\n\nafter\n", false), ("# T\n\nsee ![[i.png]] here\n\nafter\n", true)] {
            let (c, doc) = makeEditor(text, caret: (text as NSString).length - 1, workspace: embed)
            var opened: [URL] = []
            c.openImageFile = { opened.append($0) }
            let hit = try XCTUnwrap(c.imageRects.values.first { $0.url != nil }, "image drawn: \(text)")
            let mid = NSPoint(x: hit.rect.midX, y: hit.rect.midY)
            XCTAssertEqual(c.imageFileURL(at: mid)?.lastPathComponent, "i.png")
            XCTAssertEqual(c.imageFileURL(at: NSPoint(x: hit.rect.maxX + 40, y: mid.y)), nil)
            let before = c.state.selection.main
            click(c, at: mid, count: 1)
            XCTAssertEqual(opened, [], "a single click doesn't open")
            click(c, at: mid, count: 2)
            XCTAssertEqual(opened.map { $0.resolvingSymlinksInPath().path },
                           [URL(fileURLWithPath: (doc as NSString).deletingLastPathComponent + "/attachments/i.png").resolvingSymlinksInPath().path])
            XCTAssertEqual(c.state.selection.main, before, "the double-click leaves the selection as it was")
            XCTAssertEqual(c.text, text)
        }
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

    /// Live bug: toggling the sidebar resized the column but the hover box stayed at the old spot.
    func testHoverBoxFollowsColumnChanges() throws {
        let (c, _) = makeEditor("x\n\n![shot](attachments/i.png)\n")
        let hit = try XCTUnwrap(c.imageRects.values.first)
        c.imageOverlay.show(hit)
        c.scrollView.setFrameSize(NSSize(width: 800, height: 900))   // narrower, like the sidebar appearing
        c.layoutColumn()
        XCTAssertTrue(c.imageOverlay.isHidden, "stale box hidden when the column moves")
        c.imageOverlay.show(hit)
        let content = c.scrollView.superview!
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)          // redraw at the new position
        let now = try XCTUnwrap(c.imageRects[hit.from])
        XCTAssertNotEqual(now.rect, hit.rect)
        XCTAssertEqual(c.imageOverlay.hit, now, "box follows the redrawn image")
    }
}

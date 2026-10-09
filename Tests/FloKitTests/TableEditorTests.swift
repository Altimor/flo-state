import XCTest
@testable import FloKit
@testable import FloCore

@MainActor
final class TableEditorTests: XCTestCase {
    let table = "| Name | Qty |\n| --- | --- |\n| Apple | 3 |\n| Pear | 12 |"

    func setup() -> (KeyReplayer, TableOverlayView, Int) {
        let r = KeyReplayer()
        r.load("Intro\n\n" + table + "\n\nafter", selection: .cursor(0))
        let v = MainActor.assumeIsolated { () -> TableOverlayView in
            r.controller.tableOverlay!.sync()
            return r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.first!
        }
        return (r, v, 7)
    }

    func resync(_ r: KeyReplayer) -> TableOverlayView {
        MainActor.assumeIsolated {
            r.controller.tableOverlay!.sync()
            return r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.first!
        }
    }

    func event(_ type: NSEvent.EventType, _ v: NSView, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: v.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testOverlaySitsOnTheDrawnTable() {
        let (r, v, from) = setup()
        let tv = r.controller.textView
        let tlm = tv.textLayoutManager!, tcm = tlm.textContentManager!
        let frag = tlm.textLayoutFragment(for: tcm.location(tcm.documentRange.location, offsetBy: from)!)!
        let layout = v.layout!
        let expectedTop = tv.textContainerOrigin.y + frag.layoutFragmentFrame.minY + frag.textLineFragments[0].typographicBounds.minY + layout.tableTop
        let cell = v.convert(v.cellRect(0, 0), to: tv)
        XCTAssertEqual(cell.minY, expectedTop + layout.cells[0][0].frame.minY, accuracy: 0.5)
        XCTAssertEqual(cell.minX, tv.textContainerOrigin.x + r.controller.applier.gutter + layout.cells[0][0].frame.minX, accuracy: 0.5)
    }

    func testEditCellsAndTab() {
        let (r, v, _) = setup()
        MainActor.assumeIsolated {
            v.beginEditing(row: 1, col: 0)
            let field = v.subviews.compactMap { $0 as? CellEditor }.first!
            XCTAssertEqual(field.string, "Apple")
            field.string = "Banana | split"
            v.endEditing(commit: true)
        }
        XCTAssertTrue(r.doc.contains("| Banana \\| split | 3 |"), r.doc)
        // Tab past the last cell adds a row and edits its first cell
        let v2 = resync(r)
        MainActor.assumeIsolated {
            v2.beginEditing(row: 2, col: 1)
            let field = v2.subviews.compactMap { $0 as? CellEditor }.first!
            field.string = "13"
            _ = v2.textView(field, doCommandBy: #selector(NSResponder.insertTab(_:)))
        }
        XCTAssertTrue(r.doc.contains("| Pear | 13 |\n|  |  |"), r.doc)
        let v3 = resync(r)
        XCTAssertEqual(v3.editingCell?.row, 3)
        XCTAssertEqual(v3.editingCell?.col, 0)
        // Escape cancels
        MainActor.assumeIsolated {
            let field = v3.subviews.compactMap { $0 as? CellEditor }.first!
            field.string = "nope"
            _ = v3.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        XCTAssertFalse(r.doc.contains("nope"))
    }

    func testContextMenu() {
        let (r, v, from) = setup()
        let p = CGPoint(x: v.cellRect(1, 0).midX, y: v.cellRect(1, 0).midY)
        let menu = MainActor.assumeIsolated { v.menu(for: event(.rightMouseDown, v, p))! }
        let titles = menu.items.map { $0.title }
        XCTAssertTrue(titles.contains("Insert Row Below") && titles.contains("Delete Column") && titles.contains("Edit as Markdown"), "\(titles)")
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Insert Row Below"))
        XCTAssertTrue(r.doc.contains("| Apple | 3 |\n|  |  |\n| Pear | 12 |"), r.doc)
        let v2 = resync(r)
        let m2 = MainActor.assumeIsolated { v2.menu(for: event(.rightMouseDown, v2, CGPoint(x: v2.cellRect(1, 1).midX, y: v2.cellRect(1, 1).midY)))! }
        m2.performActionForItem(at: m2.indexOfItem(withTitle: "Delete Column"))
        XCTAssertTrue(r.doc.contains("| Name |\n| --- |\n| Apple |"), r.doc)
        let v3 = resync(r)
        let m3 = MainActor.assumeIsolated { v3.menu(for: event(.rightMouseDown, v3, CGPoint(x: v3.cellRect(0, 0).midX, y: v3.cellRect(0, 0).midY)))! }
        m3.performActionForItem(at: m3.indexOfItem(withTitle: "Edit as Markdown"))
        XCTAssertTrue(r.controller.markdownTables.contains(from))
        XCTAssertTrue(MainActor.assumeIsolated { r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.isEmpty }
                      || { r.controller.currentPlan!.widgets.allSatisfy { if case .table = $0.kind { return false }; return true } }())
    }

    func testDragColumnAndResize() {
        let (r, v, _) = setup()
        MainActor.assumeIsolated {
            // hover the first column, grab its handle, drop it after the second column
            let c0 = v.cellRect(1, 0), c1 = v.cellRect(1, 1)
            v.mouseMoved(with: event(.mouseMoved, v, CGPoint(x: c0.midX, y: c0.midY)))
            let h = v.columnHandleRect(0)
            v.mouseDown(with: event(.leftMouseDown, v, CGPoint(x: h.midX, y: h.midY)))
            v.mouseDragged(with: event(.leftMouseDragged, v, CGPoint(x: c1.maxX - 2, y: h.midY)))
            v.mouseUp(with: event(.leftMouseUp, v, CGPoint(x: c1.maxX - 2, y: h.midY)))
        }
        XCTAssertTrue(r.doc.contains("| Qty | Name |\n| --- | --- |\n| 3 | Apple |"), r.doc)
        let v2 = resync(r)
        let w0 = v2.cellRect(0, 0).width
        MainActor.assumeIsolated {
            // resize the first column by dragging its right border 80pt to the right
            let b = v2.cellRect(0, 0)
            v2.mouseDown(with: event(.leftMouseDown, v2, CGPoint(x: b.maxX, y: b.midY)))
            v2.mouseDragged(with: event(.leftMouseDragged, v2, CGPoint(x: b.maxX + 80, y: b.midY)))
            v2.mouseUp(with: event(.leftMouseUp, v2, CGPoint(x: b.maxX + 80, y: b.midY)))
        }
        let t = ParsedTable.parse(r.doc.components(separatedBy: "\n\n")[1])!
        XCTAssertNotNil(t.explicitWidths(unit: 8), r.doc)
        let v3 = resync(r)
        XCTAssertEqual(v3.cellRect(0, 0).width, w0 + 80, accuracy: 9)
        // a row: drag the last row to the top of the body
        MainActor.assumeIsolated {
            let last = v3.cellRect(2, 0)
            v3.mouseMoved(with: event(.mouseMoved, v3, CGPoint(x: last.midX, y: last.midY)))
            let h = v3.rowHandleRect(2)
            v3.mouseDown(with: event(.leftMouseDown, v3, CGPoint(x: h.midX, y: h.midY)))
            let top = v3.cellRect(1, 0)
            v3.mouseDragged(with: event(.leftMouseDragged, v3, CGPoint(x: h.midX, y: top.minY + 2)))
            v3.mouseUp(with: event(.leftMouseUp, v3, CGPoint(x: h.midX, y: top.minY + 2)))
        }
        XCTAssertTrue(r.doc.contains("| 12 | Pear |\n| 3 | Apple |"), r.doc)
    }

    func testInsertTable() {
        let r = KeyReplayer()
        r.load("Intro", selection: .cursor(5))
        r.controller.insertTable(rows: 3, columns: 4)
        XCTAssertEqual(r.doc, "Intro\n\n|  |  |  |  |\n| --- | --- | --- | --- |\n|  |  |  |  |\n|  |  |  |  |\n")
        let v = resync(r)
        XCTAssertEqual(v.editingCell?.row, 0)
        XCTAssertEqual(v.editingCell?.col, 0)
    }

    /// Picture for eyeballing: hover handles + an edited cell.
    func testSnapshot() throws {
        let (r, v, _) = setup()
        MainActor.assumeIsolated {
            let c = v.cellRect(1, 1)
            v.mouseMoved(with: event(.mouseMoved, v, CGPoint(x: c.midX, y: c.midY)))
            v.beginEditing(row: 2, col: 0)
        }
        let tv = r.controller.textView
        let rect = CGRect(x: 280, y: 150, width: 320, height: 200)
        let rep = tv.bitmapImageRepForCachingDisplay(in: rect)!
        tv.cacheDisplay(in: rect, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/emo/table-editor.png"))
    }
}

@MainActor
final class TableEditorHoverTests: XCTestCase {
    func testHandleStaysWhileMovingToIt() {
        let r = KeyReplayer()
        r.load("Intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\nafter", selection: .cursor(0))
        r.controller.tableOverlay!.sync()
        let v = r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.first!
        func ev(_ p: CGPoint, _ t: NSEvent.EventType = .mouseMoved) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: v.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let cell = v.cellRect(2, 0), handle = v.rowHandleRect(2)
        // from the cell, through the gap, onto the handle: hit-testing keeps claiming the pointer
        for x in stride(from: cell.midX, through: handle.midX, by: -2) {
            let p = CGPoint(x: x, y: cell.midY)
            v.mouseMoved(with: ev(p))
            XCTAssertNotNil(v.hitTest(v.convert(p, to: v.superview!)), "lost the pointer at x=\(x)")
        }
        // and grabbing it drags the row
        v.mouseDown(with: ev(CGPoint(x: handle.midX, y: handle.midY), .leftMouseDown))
        v.mouseDragged(with: ev(CGPoint(x: handle.midX, y: v.cellRect(1, 0).minY + 2), .leftMouseDragged))
        v.mouseUp(with: ev(CGPoint(x: handle.midX, y: v.cellRect(1, 0).minY + 2), .leftMouseUp))
        XCTAssertTrue(r.doc.contains("| 3 | 4 |\n| 1 | 2 |"), r.doc)
    }
}

@MainActor
final class TableEditorCursorTests: XCTestCase {
    /// ↔ over each column border, the arrow over the handles (cursor rects: the text view's I-beam loses there).
    func testCursorRegions() {
        let r = KeyReplayer()
        r.load("Intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter", selection: .cursor(0))
        r.controller.tableOverlay!.sync()
        let v = r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.first!
        let regions = v.cursorRegions()
        func cursor(at p: CGPoint) -> NSCursor? { regions.last { $0.0.contains(p) }?.1 }
        let c0 = v.cellRect(1, 0)
        XCTAssertEqual(cursor(at: CGPoint(x: c0.maxX, y: c0.midY)), .resizeLeftRight)
        XCTAssertEqual(cursor(at: CGPoint(x: v.cellRect(1, 1).maxX - 1, y: c0.midY)), .resizeLeftRight)
        let rh = v.rowHandleRect(1), ch = v.columnHandleRect(0)
        XCTAssertEqual(cursor(at: CGPoint(x: rh.midX, y: rh.midY)), .arrow)
        XCTAssertEqual(cursor(at: CGPoint(x: ch.midX, y: ch.midY)), .arrow)
        XCTAssertNil(cursor(at: CGPoint(x: c0.midX, y: c0.midY)), "cells keep the I-beam")
    }
}

@MainActor
final class TableEditorHiddenCellTests: XCTestCase {
    /// The edited cell's text stays hidden after the table is laid out again (window resize).
    func testEditedCellHiddenAfterRelayout() {
        let r = KeyReplayer()
        r.load("Intro\n\n| a | b |\n| --- | --- |\n| OLDTEXT | 2 |\n\nafter", selection: .cursor(0))
        let o = r.controller.tableOverlay!
        o.sync()
        let v = r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.first!
        v.beginEditing(row: 1, col: 0)
        // a different width: the text draws a freshly laid-out table object
        r.window.setContentSize(NSSize(width: 1100, height: 900))
        r.controller.render(force: true)
        o.sync()
        XCTAssertEqual(o.editingCell(tableAt: 7).map { [$0.0, $0.1] }, [1, 0])
    }
}

@MainActor
final class TableEditorResizeTests: XCTestCase {
    /// After a window resize the overlay's cells sit exactly on the drawn table's cells.
    func testOverlayFollowsResize() throws {
        let r = KeyReplayer()
        r.load("Intro\n\n| Item | Status | Notes |\n| --- | --- | --- |\n| First row | 🔴 |  |\n| a longer second row | 🟢 |  |\n| Third | 🟢 | some longer notes here |\n\nafter",
               selection: .cursor(0))
        let o = r.controller.tableOverlay!
        o.sync()
        r.window.setContentSize(NSSize(width: 900, height: 900))
        r.window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        o.sync()
        let v = r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.first!
        let tv = r.controller.textView
        let box = tv.textStorage!.attribute(.floWidget, at: 7, effectiveRange: nil) as! WidgetBox
        XCTAssertTrue(v.layout === box.table, "the overlay uses the drawn layout")
        let x = v.convert(v.cellRect(3, 0), to: tv).minX
        XCTAssertEqual(x, tv.textContainerOrigin.x + r.controller.applier.gutter + box.table!.cells[3][0].frame.minX, accuracy: 0.5)
        v.beginEditing(row: 3, col: 0)
        let rect = v.convert(v.bounds, to: tv).insetBy(dx: -10, dy: -10)
        let rep = tv.bitmapImageRepForCachingDisplay(in: rect)!
        tv.cacheDisplay(in: rect, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/emo/table-resize.png"))
    }
}

@MainActor
final class TableEditorScreenTests: XCTestCase {
    /// What the window server actually shows (cached fragment drawings included), not a fresh redraw.
    func screen(_ r: KeyReplayer, _ rectInTV: CGRect) -> NSBitmapImageRep? {
        r.window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        r.window.displayIfNeeded()
        let tv = r.controller.textView
        let inWin = tv.convert(rectInTV, to: nil)
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(r.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        let full = NSBitmapImageRep(cgImage: cg)
        let scale = CGFloat(full.pixelsWide) / r.window.frame.width
        let contentH = r.window.contentView!.bounds.height
        let titleH = (r.window.frame.height - contentH) * scale
        let crop = CGRect(x: inWin.minX * scale, y: titleH + (contentH - inWin.maxY) * scale, width: inWin.width * scale, height: inWin.height * scale)
        return cg.cropping(to: crop).map { NSBitmapImageRep(cgImage: $0) }
    }

    func testOldTextGoneOnScreen() throws {
        let r = KeyReplayer()
        r.window.orderFrontRegardless()
        r.load("Intro\n\n| a | b |\n| --- | --- |\n| OLDTEXTHERE | 2 |\n\nafter", selection: .cursor(0))
        let o = r.controller.tableOverlay!
        o.sync()
        let v = r.controller.textView.subviews.compactMap { $0 as? TableOverlayView }.first!
        let cellInTV = v.convert(v.cellRect(1, 0), to: r.controller.textView)
        let before = try XCTUnwrap(screen(r, cellInTV))
        try before.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/emo/screen-before.png"))
        v.beginEditing(row: 1, col: 0)
        (v.subviews.compactMap { $0 as? CellEditor }.first!).string = ""
        let after = try XCTUnwrap(screen(r, cellInTV))
        try after.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/emo/screen-after.png"))
        func dark(_ rep: NSBitmapImageRep) -> Int {
            var n = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.brightnessComponent < 0.5 { n += 1 } } }
            return n
        }
        XCTAssertGreaterThan(dark(before), 20, "the cell text is visible before editing")
        XCTAssertLessThan(dark(after), 5, "the old text is gone once the cell is being edited (and emptied)")
        // typing then ending the edit: the new text shows, the old one doesn't come back
        let ed = v.subviews.compactMap { $0 as? CellEditor }.first!
        ed.string = "Hi"
        let typing = try XCTUnwrap(screen(r, cellInTV))
        try typing.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/emo/screen-typing.png"))
        v.endEditing(commit: true)
        XCTAssertTrue(r.doc.contains("| Hi | 2 |"), r.doc)
        let done = try XCTUnwrap(screen(r, cellInTV))
        try done.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/emo/screen-done.png"))
        XCTAssertGreaterThan(dark(typing), 5, "the typed text shows")
        XCTAssertLessThan(dark(typing), dark(before) / 2, "only the typed text, no old text under it")
        XCTAssertGreaterThan(dark(done), 5, "the committed text is drawn")
        XCTAssertLessThan(dark(done), dark(before) / 2, "and the old text is gone")
    }
}

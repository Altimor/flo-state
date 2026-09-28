import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

/// Offscreen window-level tests: the real views, driven by direct calls and
/// synthesized NSEvents (never posted to the system, never on screen).
@MainActor
final class ShellViewTests: XCTestCase {
    var wc: ShellWindowController!
    var f: ShellFixture!

    func make(_ files: [String: String], config: String = "", size: CGSize = CGSize(width: 1400, height: 900)) async {
        f = ShellFixture(files: files, config: config + "editor.jump-to-bottom-after-minutes = 0\n")
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), offscreen: true)
        wc.root.animationsEnabled = false
        await f.open()
        refresh()
    }

    override func tearDown() async throws {
        wc?.window?.close()
        wc = nil
    }

    /// Dropping a PDF from Finder onto the text copies it into attachments/ and embeds it at the drop point.
    /// (0.1.10 regression: the text view took file drops itself, so the window-level handler never ran.)
    func testDroppingAPDFOnTheTextEmbedsIt() async throws {
        await make(["a.md": "# A\n\nfirst\n"])
        await openTab("a.md")
        let src = f.p("dropped doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = CGContext(URL(fileURLWithPath: src) as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let pane = try XCTUnwrap(wc.root.area.activeFilePane)
        let tv = try XCTUnwrap(pane.controller?.textView)
        let pb = NSPasteboard(name: NSPasteboard.Name("flo-drop-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: src) as NSURL])
        let drag = FakeDrag(pasteboard: pb, location: tv.convert(NSPoint(x: tv.bounds.midX, y: tv.bounds.maxY - 5), to: nil), window: wc.window!)
        XCTAssertEqual(tv.draggingEntered(drag), .copy)
        XCTAssertTrue(tv.performDragOperation(drag))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.p("attachments/dropped doc.pdf")), "copied next to the note")
        XCTAssertTrue(pane.controller!.text.contains("![dropped doc](<attachments/dropped doc.pdf>)") || pane.controller!.text.contains("![dropped doc](attachments/dropped%20doc.pdf)"),
                      pane.controller!.text)
    }

    /// PDFs and images open in a viewer tab: the tab stays (it used to fail decoding the bytes as text and
    /// close again), the pane shows PDFKit / an image view instead of the editor, and the file is untouched.
    func testPDFAndImageOpenInViewerTabs() async throws {
        await make(["a.md": "# A"])
        let pdf = f.p("doc.pdf"), png = f.p("pic.png")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = CGContext(URL(fileURLWithPath: pdf) as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.systemBlue.cgColor); ctx.fill(CGRect(x: 40, y: 40, width: 220, height: 320)); ctx.endPDFPage(); ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let img = NSImage(size: NSSize(width: 64, height: 32)); img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 64, height: 32).fill(); img.unlockFocus()
        try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
        let before = try Data(contentsOf: URL(fileURLWithPath: png))
        for (path, kind) in [(pdf, WorkspaceFS.ViewerKind.pdf), (png, .image)] {
            try await f.model.editor.openFileInTabOrFocus(path)
            await f.settle()
            refresh()
            XCTAssertTrue(f.model.editor.tabs.contains { $0.location == .file(path) }, "tab stays open")
            let pane = try XCTUnwrap(wc.root.area.activeFilePane)
            XCTAssertEqual(pane.path, path)
            XCTAssertNil(pane.controller, "no text editor")
            XCTAssertEqual(pane.viewer?.kind, kind)
            XCTAssertGreaterThan(pane.viewer?.frame.width ?? 0, 100)
            if kind == .pdf {
                XCTAssertEqual(pane.viewer?.pdfView?.document?.pageCount, 2)
                XCTAssertEqual(pane.viewer?.pdfView?.scaleFactor ?? 0, 3, accuracy: 0.01, "300pt page fitted to 900pt, not the full pane")
            }
            else { XCTAssertEqual(pane.viewer?.imageView?.frame.size, CGSize(width: 128, height: 64), "2x bitmap shown at its pixel size") }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: png)), before, "never written")
    }

    /// Crash report (0.1.8): AppKit laid a window out after its controller, the model's other owner, was
    /// released; the root view's `unowned` model then aborted in `setWindowActive` during `layout()`.
    func testRootViewOutlivingItsControllerCanStillLayOut() {
        let data = TFS.tempDir("data")
        var root: ShellRootView?
        var window: NSWindow?
        autoreleasepool {
            let model = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)), importLegacy: false)
            model.systemIsDark = { false }
            let c = ShellWindowController(model: model, frame: NSRect(x: -10000, y: -10000, width: 900, height: 600), offscreen: true)
            root = c.root
            window = c.window
            c.window?.close()
        }
        // the controller (and its reference to the model) is gone; the window and its views are not
        root?.needsLayout = true
        root?.layout()
        root?.setWindowActive(true)
        XCTAssertNotNil(root?.model)
        window = nil
    }

    func refresh() {
        wc.flush()
        wc.root.layoutSubtreeIfNeeded()
    }

    func openTab(_ rel: String) async {
        try! await f.model.editor.openFileInTabOrFocus(f.p(rel))
        await f.settle()
        refresh()
    }

    func mouse(_ type: NSEvent.EventType, at p: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let w = view.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: flags, timestamp: 0, windowNumber: wc.window!.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: wc.window!.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    var pane: EditorPaneView? { wc.root.area.activeFilePane }

    func testTypingAutosavesToDisk() async {
        await make(["a.md": "# A\n\nhello"])
        await openTab("a.md")
        guard let c = pane?.controller else { return XCTFail("no editor") }
        XCTAssertEqual(c.text, "# A\n\nhello")
        c.textView.setSelectedRange(NSRange(location: 11, length: 0))
        c.textView.insertText(" world", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(c.text, "# A\n\nhello world")
        XCTAssertEqual(TFS.read(f.p("a.md")), "# A\n\nhello world\n")
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.cursorPos, 16)
    }

    func testNewFileCaretAfterHash() async {
        await make(["n.md": "# "])
        await openTab("n.md")
        XCTAssertEqual(pane?.controller?.state.selection.main.head, 2)
    }

    func testExternalReloadUpdatesEditorKeepingCaret() async {
        await make(["a.md": "one two three"])
        await openTab("a.md")
        let c = pane!.controller!
        c.textView.setSelectedRange(NSRange(location: 8, length: 0))
        TFS.write(f.p("a.md"), "one")
        f.model.handleWatcherOutputs([.fileChanged(path: f.p("a.md"), kind: .modified)])
        await f.settle()
        refresh()
        XCTAssertEqual(pane!.controller!.text, "one")
        XCTAssertEqual(pane!.controller!.state.selection.main.head, 3, "caret clamped")
        XCTAssertFalse(pane!.controller!.session.env.history.canUndo, "reload not in undo history")
    }

    func testSidebarRowClickOpensAndFocuses() async {
        await make(["a.md": "# Alpha", "b.md": "# Beta"])
        let rows = wc.root.sidebar.rows
        XCTAssertEqual(rows.map { $0.label }, ["Alpha", "Beta"])
        let r = rows[1]
        r.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 16), in: r))
        r.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 20, y: 16), in: r))
        await f.settle()
        refresh()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("b.md"))
        XCTAssertEqual(wc.root.tabs.buttons.map { $0.title }, ["Beta"])
        XCTAssertTrue(wc.root.sidebar.rows[1].isActive)
        XCTAssertEqual(wc.window?.title, wc.model.editor.tabTitle(wc.model.editor.activeTab!))
        // shift-click selects a range without opening
        let r0 = wc.root.sidebar.rows[0]
        r0.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 16), in: r0, flags: .shift))
        r0.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 20, y: 16), in: r0, flags: .shift))
        XCTAssertEqual(f.model.selectedPaths.count, 2)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("b.md"))
    }

    func testFolderClickExpandsAndDragMoves() async {
        await make(["d/x.md": "# X", "a.md": "# A"])
        var rows = wc.root.sidebar.rows
        XCTAssertEqual(rows.map { $0.label }, ["d", "A"])
        rows[0].mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 16), in: rows[0]))
        rows[0].mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 20, y: 16), in: rows[0]))
        refresh()
        rows = wc.root.sidebar.rows
        XCTAssertEqual(rows.map { $0.label }, ["d", "X", "A"])
        XCTAssertEqual(rows[1].frame.minY - rows[0].frame.minY, 33)
        XCTAssertEqual(rows[1].labelX, 12 + 6 + 26, "depth 1 indent")
        // drag "A" onto folder "d"
        let a = rows[2], d = rows[0]
        a.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 16), in: a))
        let target = d.convert(CGPoint(x: 40, y: 16), to: a)
        a.mouseDragged(with: mouse(.leftMouseDragged, at: target, in: a))
        a.mouseUp(with: mouse(.leftMouseUp, at: target, in: a))
        refresh()
        XCTAssertTrue(TFS.exists(f.p("d/a.md")))
        XCTAssertEqual(wc.root.sidebar.rows.map { $0.label }, ["d", "A", "X"])
    }

    func testTabClickCloseAndPlus() async {
        await make(["a.md": "# A", "b.md": "# B"])
        await openTab("a.md")
        await openTab("b.md")
        let tabs = wc.root.tabs
        XCTAssertEqual(tabs.buttons.map { $0.title }, ["A", "B"])
        XCTAssertEqual(tabs.buttons.map { $0.isActive }, [false, true])
        let t0 = tabs.buttons[0]
        t0.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 10, y: 16), in: t0))
        refresh()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"))
        // hover reveals ×; clicking it closes the tab
        let t1 = wc.root.tabs.buttons[1]
        t1.mouseEntered(with: mouse(.mouseMoved, at: .zero, in: t1))
        t1.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: t1.closeRect.midX, y: t1.closeRect.midY), in: t1))
        refresh()
        XCTAssertEqual(wc.root.tabs.buttons.map { $0.title }, ["A"])
        let plus = wc.root.tabs.plus
        plus.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 18, y: 16), in: plus))
        refresh()
        XCTAssertEqual(wc.root.tabs.buttons.map { $0.title }, ["A", "New tab"])
        XCTAssertTrue(wc.root.area.activePane is LauncherView)
    }

    func testKeyboardShortcutsGoThroughTheMenu() async {
        await make(["a.md": "# A", "b.md": "# B"])
        await openTab("a.md")
        await openTab("b.md")
        let router = MenuRouter()
        router.focusedModel = { self.f.model }
        let menu = MainMenu.build(target: router)
        func press(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
            let e = key(chars, code: code, flags: flags)
            // the window monitor lets menu shortcuts through (so NSMenu flashes the title)…
            XCTAssertTrue(wc.handleKey(e) === e, "\(chars) passes the monitor")
            // …and the menu handles them
            return menu.performKeyEquivalent(with: e)
        }
        XCTAssertTrue(press("1", 18, .command))
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"))
        XCTAssertTrue(press("}", 30, [.command, .shift]))
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("b.md"))
        XCTAssertTrue(press("\t", 48, .control))
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"), "Ctrl-Tab (hidden item)")
        XCTAssertTrue(press("o", 31, .command))
        XCTAssertEqual(f.model.palette?.intent, .search)
        XCTAssertNil(wc.handleKey(key("\u{1b}", code: 53, flags: [])), "Esc closes the palette")
        XCTAssertNil(f.model.palette)
        XCTAssertTrue(press("\\", 42, .command))
        XCTAssertFalse(f.model.sidebarPreferenceVisible, "Cmd-\\ toggles the sidebar")
        // Alt-← outside the editor is not a menu item: the monitor handles it
        wc.window!.makeFirstResponder(nil)
        XCTAssertNil(wc.handleKey(key("", code: 123, flags: .option)))
    }

    func testCloseTabWithForeignKeyWindowClosesThatWindow() async {
        await make(["a.md": "# A"])
        await openTab("a.md")
        let router = MenuRouter()
        router.focusedModel = { self.f.model }
        var closedForeign = 0
        router.keyWindowIsForeign = { true }
        router.closeKeyWindow = { closedForeign += 1 }
        router.route(.closeTab)
        XCTAssertEqual(closedForeign, 1, "Cmd-W closes the Settings window")
        XCTAssertEqual(f.model.editor.tabs.count, 1, "not a workspace tab")
        router.route(.newTab)
        XCTAssertEqual(f.model.editor.tabs.count, 1, "workspace actions don't leak to a window behind")
        router.keyWindowIsForeign = { false }
        router.route(.closeTab)
        XCTAssertTrue(f.model.editor.tabs.isEmpty || f.model.editor.tabs.map { $0.location } == [.launcher])
    }

    func testPaletteOverlayTypingAndEnter() async {
        await make(["alpha.md": "# Alpha", "beta.md": "# Beta"])
        f.model.perform(.search)
        let o = wc.root.paletteOverlay!
        XCTAssertEqual(o.list.data?.heading, "Suggested")
        o.input.stringValue = "bet"
        o.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: o.input))
        refresh()
        XCTAssertEqual(o.list.data?.items.map { $0.title }, ["beta.md"])
        XCTAssertEqual(o.card.frame.height, 1 + 48.5 + (6 + 28.5 + 59 + 6) + 1)
        _ = o.control(o.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await f.settle()
        refresh()
        XCTAssertNil(wc.root.paletteOverlay)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("beta.md"))
    }

    func testFontSizeAndThemeRebuildEditor() async {
        await make(["a.md": "# A\n\ntext"])
        await openTab("a.md")
        XCTAssertEqual(pane?.controller?.theme.baseSize, 16)
        f.model.perform(.fontSizeIncrease)
        refresh()
        XCTAssertEqual(pane?.controller?.theme.baseSize, 17)
        XCTAssertEqual(pane?.controller?.text, "# A\n\ntext")
        f.model.setSetting("appearance.theme", .string("dark"))
        refresh()
        XCTAssertEqual(wc.window?.appearance?.name, .darkAqua)
        XCTAssertEqual(f.model.palette_.mode, .dark)
    }

    func testGoToTodayAndAutoDailyHeading() async {
        let today = AppCommands.todayStamp(Date())
        await make(["j.md": "# Journal\n\n## 2020.01.01\n\nold", "plain.md": "text"])
        await openTab("j.md")
        wc.didActivate()
        XCTAssertEqual(pane?.controller?.text, "# Journal\n\n## 2020.01.01\n\nold\n\n## \(today)\n\n", "auto-inserted in a dated notebook")
        await openTab("plain.md")
        f.model.perform(.goToToday)
        XCTAssertEqual(pane?.controller?.text, "text\n\n## \(today)\n\n")
        XCTAssertEqual(pane?.controller?.state.selection.main.head, ("text\n\n## \(today)\n\n" as NSString).length)
    }

    func testJumpToBottomOnReturn() async {
        await make(["long.md": (0..<200).map { "line \($0)" }.joined(separator: "\n")], config: "editor.jump-to-bottom-after-minutes = 10\n")
        await openTab("long.md")
        wc.uiState.markActivated(0)
        wc.didActivate(nowMs: 20 * 60_000)
        let c = pane!.controller!
        XCTAssertEqual(c.state.selection.main.head, c.state.doc.length)
        XCTAssertGreaterThan(pane!.scrollTop, 1000)
        // caret sits at ~70% of the scroller box
        let caret = c.rect(forPosition: c.state.doc.length, in: pane!)!
        XCTAssertEqual(caret.minY, 900 * 0.7, accuracy: 8.5)
        // back within the threshold: no jump
        c.run { t in t.dispatch(TransactionSpec(selection: .cursor(0))); return true }
        wc.didActivate(nowMs: 21 * 60_000)
        XCTAssertEqual(c.state.selection.main.head, 0)
    }

    func testOutlineRailAndScrollToHeading() async {
        let doc = (1...30).map { "## Section \($0)\n\n" + String(repeating: "para\n\n", count: 10) }.joined()
        await make(["o.md": "# Title\n\n" + doc])
        await openTab("o.md")
        let rail = wc.root.area.rail
        XCTAssertFalse(rail.isHidden)
        XCTAssertEqual(rail.headings.count, 31)
        XCTAssertEqual(rail.activeIndex, 0)
        pane!.scrollToHeading(rail.headings[10])
        wc.root.area.updateRail()
        XCTAssertEqual(rail.activeIndex, 10)
        rail.openPopover()
        XCTAssertNotNil(rail.popover)
        XCTAssertEqual(rail.popover!.frame.width, 260)
        rail.closePopover()
        f.model.setSetting("editor.show-outline", .bool(false))
        refresh()
        XCTAssertTrue(rail.isHidden)
    }

    func testFooterStatsAndContextMenu() async {
        await make(["a.md": "# Head\n\nOne two three.\n\nFour"], config: "statusbar.show-words = true\n")
        await openTab("a.md")
        let footer = wc.root.area.footer
        XCTAssertFalse(footer.isHidden)
        XCTAssertEqual(footer.text, "5words")
        let menu = footer.menu(for: mouse(.rightMouseDown, at: .zero, in: footer))!
        XCTAssertEqual(menu.items.map { "\($0.title):\($0.state == .on)" }, ["Words:true", "Characters:false", "Paragraphs:false"])
        (menu.items[2] as! ClosureMenuItem).fire()
        refresh()
        XCTAssertEqual(footer.text, "5words3paragraphs")
    }

    func testFrontmatterPanelEditsStore() async {
        await make(["f.md": "---\ntitle: T\n---\nbody"])
        await openTab("f.md")
        let panel = pane!.frontmatterPanel!
        XCTAssertFalse(panel.isHidden)
        XCTAssertEqual(panel.rows.entries.map { $0.key }, ["title"])
        XCTAssertEqual(pane!.controller!.topInset, 168 + FrontmatterRows.height(rows: 1), "scroller starts below the 12px border")
        panel.addRow()
        XCTAssertEqual(panel.rows.entries.count, 2)
        let yaml = panel.rows.entries
        XCTAssertEqual(yaml.count, 2)
        _ = panel.rows
        // typing into the new row
        var r = panel.rows
        let change = r.update(1, key: "tags")
        XCTAssertEqual(change, .some("title: T\ntags: \"\""))
        panel.removeRow(1)
        panel.removeRow(0)
        XCTAssertNil(f.model.editor.file(f.p("f.md"))?.frontmatter, "removing the last row deletes the block")
        XCTAssertEqual(TFS.read(f.p("f.md")), "body\n")
    }

    func testTypingThirdDashCreatesFrontmatter() async {
        await make(["n.md": "x"])
        await openTab("n.md")
        let c = pane!.controller!
        c.load("--", selection: .cursor(2))
        _ = c.insertTyped("-")
        refresh()
        XCTAssertEqual(f.model.editor.file(f.p("n.md"))?.frontmatter, "")
        XCTAssertEqual(pane!.frontmatterPanel!.rows.entries.count, 1, "empty frontmatter shows a placeholder row")
    }

    func testSidebarAutoHideOnResize() async {
        await make(["a.md": ""], size: CGSize(width: 1200, height: 800))
        XCTAssertFalse(wc.root.sidebar.isHidden)
        wc.window!.setContentSize(NSSize(width: 800, height: 800))
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        refresh()
        XCTAssertTrue(wc.root.sidebar.isHidden)
        XCTAssertFalse(wc.root.collapsedToggle.isHidden)
        XCTAssertEqual(wc.root.tabs.frame.minX, 132)
        XCTAssertEqual(wc.root.area.frame.minX, 0)
    }

    func testSidebarResizeHandleAndDragRegion() async {
        await make(["a.md": ""], size: CGSize(width: 1200, height: 800))
        let h = wc.root.resizeHandle
        XCTAssertEqual(h.frame, CGRect(x: 236, y: 72, width: 8, height: 728))
        h.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 4, y: 100), in: h))
        h.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 64, y: 100), in: h))
        wc.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(wc.root.sidebar.frame.width, 300, "live width while dragging")
        XCTAssertEqual(f.model.values.appearanceSidebarWidth, 240, "not persisted until release")
        h.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 1004, y: 100), in: h))
        refresh()
        XCTAssertEqual(f.model.values.appearanceSidebarWidth, 420, "clamped to min(420, max(280, 35%))")
        XCTAssertEqual(wc.root.sidebar.frame.width, 420)
        XCTAssertEqual(wc.root.tabs.frame.minX, 432)
        // drag region: top 72px except the sidebar toggle
        let d = wc.root.dragRegion
        XCTAssertTrue(d.hitTest(CGPoint(x: 600, y: 30)) === d)
        XCTAssertNil(d.hitTest(CGPoint(x: 600, y: 90)))
        let t = wc.root.sidebar.toggle.convert(CGPoint(x: 14, y: 14), to: wc.root)
        XCTAssertNil(d.hitTest(t))
        XCTAssertTrue(wc.root.hitTest(CGPoint(x: 600, y: 90)) !== d)
    }

    func testCompactWindow() async {
        f = ShellFixture(files: ["solo.md": "# Solo\n\ntext", "other.md": "# Other"], config: "statusbar.show-words = true\n")
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 900, height: 700), offscreen: true)
        try! f.model.recentFilesStore.record(f.p("other.md"))
        await f.model.editor.openCompactFile(f.p("solo.md"))
        await f.settle()
        refresh()
        XCTAssertTrue(f.model.isCompact)
        XCTAssertFalse(wc.root.compactHeader.isHidden)
        XCTAssertTrue(wc.root.tabs.isHidden)
        XCTAssertTrue(wc.root.sidebar.isHidden)
        XCTAssertTrue(wc.root.area.footer.isHidden, "no footer in compact windows")
        XCTAssertEqual(wc.root.compactHeader.title, "Solo")
        XCTAssertEqual(wc.root.compactHeader.pickerMenu().items.map { $0.title }, ["Recents", "Other"])
        // palette: commands for compact windows, recents searched client-side
        XCTAssertEqual(f.model.paletteCommands().map { $0.title }, ["Create New File", "Open Workspace", "Toggle Dark Mode", "Settings"])
        f.model.perform(.search)
        f.model.setPaletteQuery("oth")
        XCTAssertEqual(f.model.paletteView()!.items.map { $0.title }, ["Other"])
        f.model.runSelectedPaletteItem()
        await f.settle()
        XCTAssertEqual(f.model.editor.tabs.count, 1)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("other.md"))
        // Cmd-W / Cmd-T are no-ops in compact windows
        f.model.perform(.closeTab); f.model.perform(.newTab)
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.file(f.p("other.md"))])
    }

    func testImageDropImportsAndInserts() async {
        await make(["n.md": "text"])
        await openTab("n.md")
        let img = TFS.tempDir("img") + "/My Pic.png"
        TFS.write(img, "PNG")
        let pane = self.pane!
        pane.controller!.run { t in t.dispatch(TransactionSpec(selection: .cursor(4))); return true }
        pane.insertDroppedImages(f.model.importDroppedImages([img, img], into: f.p("n.md")))
        XCTAssertEqual(pane.controller!.text, "text\n![My Pic](<attachments/My Pic.png>)\n![My Pic](<attachments/My Pic-1.png>)\n")
        XCTAssertTrue(TFS.exists(f.p("attachments/My Pic-1.png")))
        XCTAssertEqual(pane.controller!.state.selection.main.head, pane.controller!.state.doc.length)
        XCTAssertEqual(ShellModel.imageDropEdit(snippets: ["a"], lineStart: true), "a\n")
    }

    func testWelcomeWhenNoWorkspace() async {
        f = ShellFixture()
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1000, height: 700), offscreen: true)
        refresh()
        XCTAssertFalse(wc.root.welcome.isHidden)
        XCTAssertTrue(wc.root.tabs.isHidden)
        XCTAssertEqual(f.model.editor.windowTitle(), "Flo State")
    }
}

/// Traffic lights: tao's `set_traffic_light_inset(20, 29)` must survive
/// AppKit's titlebar re-layouts (title changes, resize, key changes).
@MainActor
final class TrafficLightTests: XCTestCase {
    func lightFrames(_ w: NSWindow) -> [CGRect] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { t in
            guard let b = w.standardWindowButton(t), let frameView = w.contentView?.superview else { return nil }
            let r = b.convert(b.bounds, to: frameView)
            // top-left origin in window coordinates
            return CGRect(x: r.minX, y: frameView.bounds.height - r.maxY, width: r.width, height: r.height)
        }
    }

    func testPositionMatchesTauriAndSurvivesRelayout() async {
        let f = ShellFixture(files: ["a.md": "# A"])
        let wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open(file: "a.md")
        wc.flush()
        wc.positionTrafficLights()
        let first = lightFrames(wc.window!)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first[0].minX, 20, accuracy: 0.5, "close button at x=20 like Flo State")
        // vertically centred on the collapsed sidebar toggle's row (web: toggle 14…42, centre 28)
        // legacy Flo State (Tauri 20,29): close-button centre at (27, 27) pt
        XCTAssertEqual(first[0].midX, 27, accuracy: 0.5, "\(first)")
        XCTAssertEqual(first[0].midY, 27, accuracy: 0.5, "\(first)")
        XCTAssertNotNil(wc.window!.toolbar, "unified toolbar kept (system corner radius)")
        XCTAssertEqual(first[1].minX - first[0].minX, first[2].minX - first[1].minX, accuracy: 0.5)
        // title change → AppKit re-lays out the titlebar
        wc.window!.title = "something else entirely"
        wc.window!.contentView?.superview?.layoutSubtreeIfNeeded()
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(lightFrames(wc.window!), first, "stable after a title change")
        wc.window!.setContentSize(NSSize(width: 900, height: 700))
        wc.window!.contentView?.superview?.layoutSubtreeIfNeeded()
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(lightFrames(wc.window!), first, "stable after a resize")
        wc.window!.close()
    }
}

/// Typewriter scrolling (use-center-mode.ts): caret held at 70%, no jumps.
@MainActor
final class TypewriterTests: XCTestCase {
    func testTypingManyLinesAtTheEndScrollsMonotonicallyAndHoldsCaretAt70() async {
        let f = ShellFixture(files: ["long.md": (0..<400).map { "line \($0) with some words in it" }.joined(separator: "\n")],
                             config: "editor.jump-to-bottom-after-minutes = 0\n")
        let wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open(file: "long.md")
        wc.flush()
        wc.root.layoutSubtreeIfNeeded()
        let pane = wc.root.area.activeFilePane!
        let c = pane.controller!
        let end = c.state.doc.length
        c.textView.setSelectedRange(NSRange(location: end, length: 0))
        pane.typewriter(force: true)
        pane.flushTypewriter()
        var last = pane.scrollTop
        XCTAssertGreaterThan(last, 5000)
        var caretYs: [CGFloat] = []
        for i in 0..<40 {
            c.textView.insertText("\nnew line \(i)", replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.main.run(until: Date())   // the recentre runs right after the edit settles
            let top = pane.scrollTop
            XCTAssertGreaterThanOrEqual(top, last, "scroll never goes backwards (line \(i))")
            last = top
            caretYs.append(c.rect(forPosition: c.state.selection.main.head, in: pane)!.minY)
        }
        for y in caretYs { XCTAssertEqual(y, 800 * 0.7, accuracy: 8 + 1, "caret held at 70%") }
        // typing within a line (caret moves but stays on the line) never scrolls
        let before = pane.scrollTop
        for ch in "abcdef" { c.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)); RunLoop.main.run(until: Date()) }
        XCTAssertEqual(pane.scrollTop, before)
        // a click elsewhere (no key event) does not recentre
        c.textView.setSelectedRange(NSRange(location: 10, length: 0))
        RunLoop.main.run(until: Date())
        XCTAssertEqual(pane.scrollTop, before)
        wc.window?.close()
    }
}


/// Sidebar show/hide animates like the web (140ms ease-out) with the editor
/// and tab strip moving in lockstep (no gap where the backdrop shows).
@MainActor
final class SidebarAnimationTests: XCTestCase {
    func testToggleAnimatesWithoutGaps() async {
        let f = ShellFixture(files: ["a.md": "# A"], config: "editor.jump-to-bottom-after-minutes = 0\n")
        let wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        defer { wc.window?.close() }
        var t: CFTimeInterval = 100
        wc.root.now = { t }
        await f.open(file: "a.md")
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
        let root = wc.root
        XCTAssertEqual(root.sidebarClip.frame.width, 240)
        func check(_ label: String) {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.area.frame.minX, root.sidebarClip.frame.maxX, accuracy: 0.001, "\(label): editor meets the sidebar")
            XCTAssertEqual(root.tabBacking.frame.minX, root.area.frame.minX, accuracy: 0.001, label)
            XCTAssertEqual(root.tabBlur.frame, root.tabBacking.frame, label)
        }
        f.model.perform(.toggleSidebar)       // hide
        wc.flush()
        check("start")
        t += 0.07
        check("mid")
        let mid = root.sidebarClip.frame.width
        XCTAssertGreaterThan(mid, 0); XCTAssertLessThan(mid, 240)
        XCTAssertGreaterThan(mid, 240 * 0.3, "ease-out: past the linear midpoint")
        XCTAssertEqual(root.sidebar.frame.width, 240, "panel keeps its width, clipped")
        let tabMid = root.tabs.frame.minX
        XCTAssertTrue(tabMid < 252 && tabMid > 132, "tab strip slides (\(tabMid))")
        t += 0.1
        check("end")
        XCTAssertEqual(root.sidebarClip.frame.width, 0)
        XCTAssertTrue(root.sidebarClip.isHidden)
        XCTAssertEqual(root.tabs.frame.minX, 132)
        XCTAssertNil(root.sidebarAnimation)
        // show again, and the 850px auto-hide animates too
        f.model.perform(.toggleSidebar)
        wc.flush(); check("show start"); t += 0.2; check("show end")
        XCTAssertEqual(root.sidebarClip.frame.width, 240)
        wc.window!.setContentSize(NSSize(width: 800, height: 800))
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        wc.flush(); check("autohide start")
        XCTAssertNotNil(root.sidebarAnimation)
        t += 0.2; check("autohide end")
        XCTAssertEqual(root.sidebarClip.frame.width, 0)
        // narrow: shown by hand (collapsed toggle), pushing the editor, nothing clipped
        XCTAssertFalse(root.collapsedToggle.isHidden)
        root.collapsedToggle.action?()
        wc.flush(); check("narrow show start"); t += 0.2; check("narrow show")
        XCTAssertEqual(root.sidebarClip.frame.width, f.model.sidebarWidth)
        XCTAssertTrue(root.collapsedToggle.isHidden)
        XCTAssertLessThanOrEqual(root.area.frame.maxX, root.bounds.width + 0.001)
        XCTAssertGreaterThan(root.area.frame.width, 300)
        f.model.perform(.toggleSidebar)
        wc.flush(); check("narrow hide start"); t += 0.2; check("narrow hide")
        XCTAssertEqual(root.sidebarClip.frame.width, 0)
    }

    func testBackdropMatchesLegacy() async {
        let f = ShellFixture(files: ["a.md": ""], config: "appearance.theme = dark\n")
        let wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        defer { wc.window?.close() }
        XCTAssertEqual(wc.root.effect.material, .windowBackground, "flat backdrop like the legacy window (active rgb 38)")
        XCTAssertEqual(wc.root.effect.state, .active)
        wc.root.setWindowActive(false)
        XCTAssertFalse(wc.root.inactiveBase.isHidden, "inactive: legacy's darker flat backdrop (rgb 22,22,17)")
        XCTAssertEqual(wc.root.inactiveBase.fillColor, NSColor(srgbRed: 22 / 255, green: 22 / 255, blue: 17 / 255, alpha: 1))
        wc.root.setWindowActive(true)
        XCTAssertTrue(wc.root.inactiveBase.isHidden)
        f.model.setSetting("appearance.theme", .string("light"))
        for active in [true, false] {
            wc.root.setWindowActive(active)
            XCTAssertFalse(wc.root.inactiveBase.isHidden, "light: flat legacy backdrop")
            XCTAssertEqual(wc.root.inactiveBase.fillColor, NSColor(srgbRed: 228 / 255, green: 228 / 255, blue: 228 / 255, alpha: 1))
        }
    }

    func testEaseOutCurve() {
        XCTAssertEqual(ShellRootView.easeOut(0), 0)
        XCTAssertEqual(ShellRootView.easeOut(1), 1)
        XCTAssertEqual(ShellRootView.easeOut(0.5), 0.6836, accuracy: 0.01)
    }

    func testPaletteBlurIsClippedToTheCard() async {
        let f = ShellFixture(files: ["a.md": ""])
        let wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        defer { wc.window?.close() }
        await f.open()
        f.model.perform(.search)
        wc.root.layoutSubtreeIfNeeded()
        let o = wc.root.paletteOverlay!
        o.layoutSubtreeIfNeeded()
        XCTAssertEqual(o.backdrop.frame, o.card.frame, "blur exactly under the card")
        XCTAssertEqual(o.backdrop.layer?.masksToBounds, true)
        XCTAssertEqual(o.card.layer?.masksToBounds, true)
        XCTAssertTrue(o.card.layer?.backgroundFilters?.isEmpty ?? true, "no unclipped filter on the card")
        XCTAssertEqual(o.shadowView.frame, o.card.frame)
        XCTAssertEqual(wc.root.tabBlur.layer?.masksToBounds, true, "tab strip blur clipped to the strip")
    }
}

/// Minimal NSDraggingInfo for driving drop handlers directly.
final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard; draggingLocation = location; draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

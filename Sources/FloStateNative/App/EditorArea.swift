import AppKit
import FloCore
import FloKit

// MARK: - caret / line geometry helpers (public NSTextView API only)

extension EditorController {
    /// Rect of the character position `pos` in `view` coordinates.
    func rect(forPosition pos: Int, in view: NSView) -> CGRect? {
        // TextKit 2 caret geometry after laying out up to the caret's paragraph
        // (firstRect can report pre-layout estimates while typing).
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let len = (textView.string as NSString).length
        let p = max(0, min(pos, len))
        guard let loc = tcm.location(tcm.documentRange.location, offsetBy: p) else { return nil }
        if let frag = tlm.textLayoutFragment(for: loc) {
            tlm.ensureLayout(for: NSTextRange(location: tcm.documentRange.location, end: frag.rangeInElement.endLocation) ?? tlm.documentRange)
        } else {
            tlm.ensureLayout(for: NSTextRange(location: tcm.documentRange.location, end: loc) ?? tlm.documentRange)
        }
        var rect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, r, _, _ in
            rect = r
            return false
        }
        guard var r = rect else { return nil }
        let o = textView.textContainerOrigin
        r.origin.x += o.x
        r.origin.y += o.y
        return view.convert(r, from: textView)
    }

    /// Top of the layout fragment (line block) holding `pos`, in `view` coordinates.
    func lineTop(forPosition pos: Int, in view: NSView) -> CGFloat? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: max(0, min(pos, (textView.string as NSString).length))) else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: tcm.documentRange.location, end: loc) ?? tlm.documentRange)
        guard let frag = tlm.textLayoutFragment(for: loc) else { return nil }
        let origin = textView.textContainerOrigin
        let y = frag.layoutFragmentFrame.minY + origin.y
        return view.convert(CGPoint(x: 0, y: y), from: textView).y
    }
}

// MARK: - File pane

/// One file tab's editor (`editor-pane.tsx`): scroll container + the
/// FloKit editor, typewriter scrolling, reload on external change.
@MainActor
final class EditorPaneView: FlippedView {
    let path: String
    unowned let model: ShellModel
    private(set) var controller: EditorController?  // read by menu commands
    private var loadedReloadVersion = -1
    private var spinner: NSTextField?
    private var suppressUpdates = false
    var onScroll: (() -> Void)?
    private(set) var frontmatterPanel: FrontmatterPanelView?

    init(path: String, model: ShellModel) {
        self.path = path
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sync with the store: create the editor once the file is loaded, reload
    /// it after an external change (`reloadVersion` bump).
    func sync() {
        guard let f = model.editor.file(path) else { return }
        if f.isLoading {
            if spinner == nil {
                let s = NSTextField(labelWithString: "⠋")
                s.font = UIFonts.ui(model.values)
                s.textColor = model.palette_.textMuted
                spinner = s
                addSubview(s)
                needsLayout = true
            }
            return
        }
        spinner?.removeFromSuperview()
        spinner = nil
        if controller == nil {
            makeController(text: f.content, caret: f.content == "# " ? 2 : min(f.cursorPos, f.content.utf16.count))
            loadedReloadVersion = f.reloadVersion
        } else if f.reloadVersion != loadedReloadVersion, let c = controller {
            frontmatterPanel?.syncFromStore()
            loadedReloadVersion = f.reloadVersion
            let caret = clampCaret(c.state.selection.main.head, length: f.content.utf16.count)
            suppressUpdates = true
            c.load(f.content, selection: .cursor(caret))
            suppressUpdates = false
        }
        frontmatterPanel?.syncFromStore()
    }

    private func makeController(text: String, caret: Int) {
        let c = EditorController(theme: EditorTheme.from(settings: model.values, mode: model.mode))
        c.documentPath = path
        c.workspaceRoot = model.root
        c.scrollView.automaticallyAdjustsContentInsets = false
        if ShellSnapshot.active { c.scrollView.hasVerticalScroller = false }
        c.scrollView.contentInsets = NSEdgeInsets()
        c.scrollView.frame = scrollBox
        c.textView.topChromeHeight = Metrics.chromeDragHeight   // tabs / drag strip: arrow cursor there
        addSubview(c.scrollView)
        c.layoutColumn()
        suppressUpdates = true
        c.load(text, selection: .cursor(caret))
        suppressUpdates = false
        c.layoutColumn()
        c.onDocChanged = { [weak self] state in
            guard let self = self, !self.suppressUpdates else { return }
            self.model.editor.updateContent(self.path, state.doc.string)
            self.model.editor.updateCursorPos(self.path, state.selection.main.head)
            self.typewriter(force: false)
        }
        c.onSelectionChanged = { [weak self] state in
            guard let self = self, !self.suppressUpdates else { return }
            self.model.editor.updateCursorPos(self.path, state.selection.main.head)
            // center mode reacts to keyup (caret moved by keys), not to clicks
            let t = NSApp?.currentEvent?.type
            if t == .keyDown || t == .keyUp { self.typewriter(force: false) }
        }
        // Editor features (find card, wiki autocomplete, paste): app styling and hooks.
        c.features.chrome = EditorChrome(tokens: ThemeTokens(settings: model.values, mode: model.mode),
                                         uiFont: { [values = model.values] size, weight in UIFonts.ui(values, size: size, weight: weight) })
        c.features.wikiCompletions = { [weak self] q, limit in self?.model.index?.fuzzySearch(q, limit: limit) ?? [] }
        c.features.frontmatterPaste = { [weak self] fm in
            guard let self = self, let f = self.model.editor.file(self.path), f.frontmatter == nil else { return false }
            self.model.editor.updateFrontmatter(self.path, fm)
            self.frontmatterPanel?.syncFromStore()
            return true
        }
        if let area = superview as? EditorAreaView {
            c.features.findOverlay = area.findOverlay
            c.features.findOverlayHost = area
        }
        c.onLinkClick = { [weak self] link in
            guard let self = self else { return }
            switch link {
            case .href(let h): self.model.perform(link: self.model.linkAction(href: h, from: self.path))
            case .wiki(let w): self.model.perform(link: self.model.wikiLinkAction(w, from: self.path))
            }
        }
        // Typing the third `-` on line 1 creates empty frontmatter.
        c.session.env.createFrontmatter = { [weak self] in
            guard let self = self, let f = self.model.editor.file(self.path), f.frontmatter == nil else { return false }
            self.model.editor.updateFrontmatter(self.path, "")
            return true
        }
        // File drops go to the window (images → attachments, notes/folders → open),
        // not into the text as paths; text drags keep working.
        c.textView.unregisterDraggedTypes()
        c.textView.registerForDraggedTypes([.string])
        let panel = FrontmatterPanelView(model: model, path: path)
        panel.onHeightChange = { [weak self] in self?.layoutFrontmatter() }
        panel.focusEditor = { [weak c] in c?.textView.window?.makeFirstResponder(c?.textView) }
        c.textView.addSubview(panel)
        frontmatterPanel = panel
        c.scrollView.contentView.postsBoundsChangedNotifications = true
        var lastY = c.scrollView.contentView.bounds.origin.y
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: c.scrollView.contentView, queue: .main) { [weak self, weak c] _ in
            MainActor.assumeIsolated {
                self?.onScroll?()
                // Diagnostics for unexplained scroll jumps (not caused by the wheel/trackpad).
                if let c = c {
                    let y = c.scrollView.contentView.bounds.origin.y
                    let ev = NSApp.currentEvent?.type
                    if abs(y - lastY) > 150, ev != .scrollWheel, ev != .leftMouseDragged {
                        ScrollJumpLog.record(from: lastY, to: y, controller: c)
                    }
                    lastY = y
                }
            }
        }
        controller = c
        applyColumnLayout()
    }

    func applyColumnLayout() {
        guard let c = controller else { return }
        c.scrollView.frame = scrollBox
        c.layoutColumn()
        layoutFrontmatter()
        // `padding-bottom: 40vh` is FloTextView.bottomPadding (set by layoutColumn)
        clampScroll()
        c.scrollView.suppressScrollPocket()
    }

    /// Keep the clip view inside the document (AppKit can leave it at a
    /// negative origin after the text view resizes).
    func clampScroll() {
        guard let c = controller else { return }
        let clip = c.scrollView.contentView
        if clip.bounds.origin.y < 0 { clip.scroll(to: CGPoint(x: 0, y: 0)); c.scrollView.reflectScrolledClipView(clip) }
    }

    /// Frontmatter panel: `pt-[9rem]` below the 12px border, centred column;
    /// the editor text starts `pb-6` below it.
    func layoutFrontmatter() {
        guard let c = controller, let panel = frontmatterPanel else { return }
        let w = c.scrollView.contentSize.width
        let sidePad = min(64, max(24, 0.04 * (window?.frame.width ?? w)))
        let colW = max(100, min(734, w - 36 - 2 * sidePad))
        let h = panel.panelHeight
        panel.isHidden = h == 0
        panel.frame = CGRect(x: (w - colW) / 2, y: 144, width: colW, height: h)
        // the scroller sits inside the 12px borders: 144 (pt-[9rem]) + 24 (pb-6)
        if c.topInset != 168 + h {
            c.topInset = 168 + h
            c.layoutColumn()
        }
    }

    /// Settings changed (font size, theme, …): rebuild the editor keeping text + caret + scroll.
    func rebuildTheme() {
        guard let old = controller else { return }
        let text = old.text, sel = old.state.selection
        let scrollY = old.scrollView.contentView.bounds.origin.y
        old.scrollView.removeFromSuperview()
        controller = nil
        makeController(text: text, caret: 0)
        guard let c = controller else { return }
        suppressUpdates = true
        c.load(text, selection: sel)
        suppressUpdates = false
        c.layoutColumn()
        c.scrollView.contentView.scroll(to: CGPoint(x: 0, y: scrollY))
        c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
    }

    override func layout() {
        super.layout()
        applyColumnLayout()
        spinner?.sizeToFit()
        if let s = spinner { s.frame.origin = CGPoint(x: (bounds.width - s.frame.width) / 2, y: (bounds.height - s.frame.height) / 2) }
    }

    /// The scroll container box (inside the 12px top/bottom borders).
    /// The scroller's padding box: `border-top/bottom: 12px solid transparent`
    /// clip the scrolled text 12px from the pane's top and bottom edges.
    var scrollBox: CGRect { CGRect(x: 0, y: 12, width: bounds.width, height: max(0, bounds.height - 24)) }

    /// `recenterCaret` (use-center-mode.ts): after input, or a key that moved
    /// the caret, scroll so the caret sits at 70% of the scroller's height
    /// (its bounding rect, borders included), with an 8px deadzone. Runs
    /// synchronously on the final layout, so it never races the text view's
    /// own scroll-to-caret (which is a no-op once the caret is at 70%).
    private var lastCaret: Int?
    private var pendingRecenter: Bool?   // nil = none, value = force

    /// Request a recentre. It runs once the text view has finished the edit
    /// (its own scroll-to-caret included), right before the next draw — so it
    /// never fights NSTextView and measures the final layout.
    func typewriter(force: Bool) {
        guard model.typewriterScrolling || force, controller != nil, window != nil else { return }
        pendingRecenter = (pendingRecenter ?? false) || force
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flushTypewriter() } }
    }

    override func viewWillDraw() {
        flushTypewriter()
        super.viewWillDraw()
    }

    func flushTypewriter() {
        guard let force = pendingRecenter else { return }
        pendingRecenter = nil
        guard let c = controller else { return }
        let head = c.state.selection.main.head
        let moved = head != lastCaret
        lastCaret = head
        guard force || moved else { return }
        guard let caret = c.rect(forPosition: head, in: self) else { return }
        let delta = caret.minY - bounds.height * 0.7
        if abs(delta) < 8 { return }
        scrollBy(delta)
    }

    func scrollBy(_ delta: CGFloat) {
        guard let c = controller else { return }
        let clip = c.scrollView.contentView
        // the text view's frame can lag the layout while typing at the end
        if let tlm = c.textView.textLayoutManager {
            let used = tlm.usageBoundsForTextContainer.maxY + c.textView.textContainerOrigin.y
            if c.textView.frame.height < used { c.textView.setFrameSize(NSSize(width: c.textView.frame.width, height: used)) }  // pads itself
        }
        let docH = c.scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, docH - clip.bounds.height)
        let y = max(0, min(maxY, clip.bounds.origin.y + delta))
        clip.scroll(to: CGPoint(x: 0, y: y))
        c.scrollView.reflectScrolledClipView(clip)
    }

    var scrollTop: CGFloat { controller?.scrollView.contentView.bounds.origin.y ?? 0 }

    /// Jump to bottom on return: caret to the end, then recentre.
    func jumpToEnd() {
        guard let c = controller else { return }
        let end = c.state.doc.length
        c.run { t in t.dispatch(TransactionSpec(selection: .cursor(end))); return true }
        c.textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        typewriter(force: true)
        flushTypewriter()
    }

    /// Scroll so the heading line lands 24px below the scroller top.
    func scrollToHeading(_ h: DocumentHeading) {
        guard let c = controller, let top = c.lineTop(forPosition: h.pos, in: self) else { return }
        scrollBy(top - 24)
    }

    /// Scroll to the heading with GFM slug `slug` (duplicates -2, -3…); false if missing.
    @discardableResult
    func scrollToSlug(_ slug: String) -> Bool {
        guard let c = controller else { return false }
        let hs = DocumentHeadings.parse(c.text, maxDepth: DocumentHeadings.fullDepth)
        guard let h = DocumentHeadings.slugIndex(hs)[slug] ?? DocumentHeadings.slugIndex(hs)[slug.lowercased()] else { return false }
        scrollToHeading(h)
        return true
    }

    /// `computeActive`: last heading whose top is at or above scroller top + 28.
    func activeHeadingIndex(_ headings: [DocumentHeading]) -> Int? {
        guard !headings.isEmpty, let c = controller else { return nil }
        var active: Int? = nil
        for (i, h) in headings.enumerated() {
            guard let y = c.lineTop(forPosition: min(h.pos, c.state.doc.length), in: self) else { break }
            if y > 28 { break }
            active = i
        }
        return active ?? 0
    }

    // MARK: editor commands (menus)

    func goToToday() {
        guard let c = controller else { return }
        c.run(AppCommands.goToDailyNote)
        typewriter(force: true)
        flushTypewriter()
    }

    /// Insert dropped image references at the caret.
    func insertDroppedImages(_ snippets: [String]) {
        guard let c = controller, !snippets.isEmpty else { return }
        let cursor = c.state.selection.main.head
        let line = c.state.doc.lineAt(cursor)
        let insert = ShellModel.imageDropEdit(snippets: snippets, lineStart: cursor == line.from)
        c.run { t in
            t.dispatch(TransactionSpec(changes: [Change(from: cursor, insert: insert)], selection: .cursor(cursor + insert.utf16.count)))
            return true
        }
        window?.makeFirstResponder(c.textView)
    }

    /// `ensureTodayHeading` through the controller so the text view stays in sync.
    func autoInsertDaily() {
        guard let c = controller, let edit = DailyNote.ensureTodayHeading(c.text) else { return }
        let sel = c.state.selection
        c.run { t in
            t.dispatch(TransactionSpec(changes: [Change(from: edit.at, insert: edit.text)], selection: sel, userEvent: "input.daily-heading"))
            return true
        }
    }
}

// MARK: - Launcher ("New tab")

final class LauncherView: FlippedView {
    unowned let model: ShellModel
    private var buttons: [(String, String, CGRect, () -> Void)] = []
    private var hovered: Int? { didSet { needsDisplay = true } }
    init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private var labelStyle: TextStyle { TextStyle(font: UIFonts.ui(model.values), color: model.palette_.textSecondary) }
    /// `<kbd>`: preflight gives it the mono stack; 11px, tracking 0.2em.
    private var kbdStyle: TextStyle { TextStyle(font: FontStack.font(model.values.fontsMono, size: 11), color: model.palette_.textIconMuted, kern: 11 * 0.2) }

    func items() -> [(String, String, () -> Void)] {
        [("Create new note", "⌘N", { [weak model] in model?.palette = PaletteState(intent: .createFile) }),
         ("Search", "⌘O", { [weak model] in model?.palette = PaletteState(intent: .search) })]
    }

    /// Button rects: a centred column, gap-3, each label + gap-1.5 + kbd.
    func buttonRects() -> [CGRect] {
        let its = items()
        let widths = its.map { labelStyle.width($0.0) + 6 + kbdStyle.width($0.1) }
        let total = CGFloat(its.count) * 19.5 + CGFloat(its.count - 1) * 12
        var y = (bounds.height - total) / 2
        return widths.map { w in defer { y += 19.5 + 12 }; return CGRect(x: (bounds.width - w) / 2, y: y, width: w, height: 19.5) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = model.palette_
        for (i, (item, r)) in zip(items(), buttonRects()).enumerated() {
            var ls = labelStyle
            if hovered == i { ls.color = p.textPrimary }
            ls.draw(item.0, x: r.minX, lineTop: r.minY, lineHeight: 19.5, in: ctx)
            // kbd: 11px, its own 16.5 line box centred in the 19.5 row
            kbdStyle.draw(item.1, x: r.minX + ls.width(item.0) + 6, lineTop: r.minY + 1.5, lineHeight: 16.5, in: ctx)
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = buttonRects().firstIndex { $0.contains(p) }
    }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = buttonRects().firstIndex(where: { $0.contains(p) }) { items()[i].2() }
    }

    func dump() -> [[String: Any]] {
        zip(items(), buttonRects()).map { item, r in
            ["text": item.0 + item.1, "rect": convertToRootRect(r).dumpArray]
        }
    }
}

extension NSView {
    func convertToRootRect(_ r: CGRect) -> CGRect {
        guard let root = window?.contentView else { return r }
        let c = convert(r, to: root)
        return root.isFlipped ? c : CGRect(x: c.minX, y: root.bounds.height - c.maxY, width: c.width, height: c.height)
    }
}

// MARK: - Status bar (document-footer.tsx)

enum FooterMetrics {
    struct Metric: Equatable { var value: Int; var label: String }

    /// Visible metrics in order (words, characters, paragraphs).
    static func visible(_ stats: DocumentStats, _ v: SettingsValues) -> [Metric] {
        var out: [Metric] = []
        if v.statusbarShowWords { out.append(Metric(value: stats.words, label: "words")) }
        if v.statusbarShowCharacters { out.append(Metric(value: stats.characters, label: "characters")) }
        if v.statusbarShowParagraphs { out.append(Metric(value: stats.paragraphs, label: "paragraphs")) }
        return out
    }

    /// `toLocaleString()` (en-US grouping).
    static func format(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

final class StatusBarView: FlippedView {
    unowned let model: ShellModel
    var metrics: [FooterMetrics.Metric] = [] { didSet { needsDisplay = true } }
    init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private var style: TextStyle { TextStyle(font: UIFonts.ui(model.values), color: model.palette_.textMuted) }
    var text: String { metrics.map { FooterMetrics.format($0.value) + $0.label }.joined() }

    /// x positions: right-aligned, px-8 (px-6 below 768px), gap-5, value gap-1.5 label.
    func layoutItems() -> [(String, CGFloat)] {
        let s = style
        let pad: CGFloat = (window?.contentView?.bounds.width ?? bounds.width) >= 768 ? 32 : 24
        var x = bounds.width - pad
        var out: [(String, CGFloat)] = []
        for m in metrics.reversed() {
            let lw = s.width(m.label)
            x -= lw
            out.insert((m.label, x), at: 0)
            let v = FooterMetrics.format(m.value)
            x -= 6 + s.width(v)
            out.insert((v, x), at: 0)
            x -= 20
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lh: CGFloat = 13 * 1.15
        for (s, x) in layoutItems() { style.draw(s, x: x, lineTop: (bounds.height - lh) / 2, lineHeight: lh, in: ctx) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { ShellMenus.footerMenu(model: model) }
}

// MARK: - Outline rail (section-rail.tsx)

enum RailGeometry {
    static let inactiveWidth: CGFloat = 10, activeWidth: CGFloat = 20, tickGap: CGFloat = 6, edgeInset: CGFloat = 12
    static let popoverWidth: CGFloat = 260

    /// Tick rects in the editor-area coordinate space (width `w`, height `h`).
    static func ticks(count: Int, active: Int?, areaWidth w: CGFloat, areaHeight h: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let stack = CGFloat(count) + CGFloat(count - 1) * tickGap
        let right = w - Metrics.scrollbarGutter - edgeInset
        let top = h / 2 - stack / 2
        return (0..<count).map { i in
            let tw = i == active ? activeWidth : inactiveWidth
            return CGRect(x: right - 2 - tw, y: top + CGFloat(i) * (1 + tickGap), width: tw, height: 1)
        }
    }

    /// The hover zone (34px wide, stack tall, vertically centred).
    static func zone(count: Int, areaWidth w: CGFloat, areaHeight h: CGFloat) -> CGRect {
        let stack = CGFloat(count) + CGFloat(max(0, count - 1)) * tickGap
        return CGRect(x: w - Metrics.scrollbarGutter - edgeInset - activeWidth - 2, y: h / 2 - stack / 2, width: edgeInset + activeWidth + 2, height: stack)
    }
}

final class OutlineRailView: FlippedView {
    unowned let model: ShellModel
    var headings: [DocumentHeading] = [] { didSet { needsDisplay = true } }
    var activeIndex: Int? { didSet { if oldValue != activeIndex { needsDisplay = true; popover?.needsDisplay = true } } }
    var onSelect: ((DocumentHeading) -> Void)?
    private(set) var popover: OutlinePopoverView?
    init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var tickRects: [CGRect] { RailGeometry.ticks(count: headings.count, active: activeIndex, areaWidth: bounds.width, areaHeight: bounds.height) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let p = popover, p.frame.contains(local) { return p.hitTest(convert(local, to: p.superview)) ?? p }
        return RailGeometry.zone(count: headings.count, areaWidth: bounds.width, areaHeight: bounds.height).contains(local) && popover == nil ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard popover == nil else { return }
        let c = model.palette_.textPrimary
        // ScrollFade: a 70vh window centred on the rail, 48px fades at both ends.
        let vh = window?.contentView?.bounds.height ?? bounds.height
        let top = bounds.height / 2 - vh * 0.35, bottom = bounds.height / 2 + vh * 0.35
        for (i, r) in tickRects.enumerated() {
            let y = r.midY
            guard y >= top, y <= bottom else { continue }
            let fade = min(1, (y - top) / 48) * min(1, (bottom - y) / 48)
            c.withAlphaComponent((i == activeIndex ? 1 : 0.35) * fade).setFill()
            r.fill()
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let z = RailGeometry.zone(count: headings.count, areaWidth: bounds.width, areaHeight: bounds.height)
        if !headings.isEmpty { addTrackingArea(NSTrackingArea(rect: z, options: [.mouseEnteredAndExited, .activeAlways], owner: self)) }
    }
    override func mouseEntered(with event: NSEvent) { openPopover() }
    override func mouseExited(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let pop = popover, pop.frame.contains(p) { return }
        closePopover()
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tickRects.firstIndex(where: { $0.insetBy(dx: 0, dy: -3).contains(p) }) { onSelect?(headings[i]) }
    }

    func openPopover() {
        guard popover == nil, !headings.isEmpty else { return }
        let pop = OutlinePopoverView(rail: self)
        popover = pop
        addSubview(pop)
        pop.layoutFor(bounds)
        needsDisplay = true
    }

    func closePopover() {
        popover?.removeFromSuperview()
        popover = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, popover != nil { closePopover(); return }
        super.keyDown(with: event)
    }

    func headingMenu(_ h: DocumentHeading) -> NSMenu {
        ShellMenus.menu([ClosureMenuItem("Copy heading link") { [weak model] in model?.copyToPasteboard(DocumentHeadings.headingLink(h)) }])
    }

    func dump() -> [[String: Any]] {
        tickRects.enumerated().map { i, r in
            ["rect": convertToRootRect(r).dumpArray, "title": headings[i].text, "active": i == activeIndex]
        }
    }
}

/// The outline popover: 260px card, rows 13px/1.5, gap 4, indent by level.
final class OutlinePopoverView: FlippedView {
    unowned let rail: OutlineRailView
    let scroll = NSScrollView()
    let list = FlippedView()
    private var hovered: Int? { didSet { list.needsDisplay = true } }

    init(rail: OutlineRailView) {
        self.rail = rail
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = false
        scroll.documentView = list
        addSubview(scroll)
        let drawer = ListDrawer(owner: self)
        list.addSubview(drawer)
        self.drawer = drawer
    }
    required init?(coder: NSCoder) { fatalError() }
    private var drawer: ListDrawer!

    var rowStyle: TextStyle { TextStyle(font: UIFonts.ui(rail.model.values), color: rail.model.palette_.textMuted, kern: -0.13) }
    var indent: CGFloat { CGFloat(rail.model.values.editorOutlineIndentPerLevel) }

    func layoutFor(_ area: CGRect) {
        let rowsH = CGFloat(rail.headings.count) * 19.5 + CGFloat(max(0, rail.headings.count - 1)) * 4
        let maxH = (window?.contentView?.bounds.height ?? area.height) * 0.7
        let contentH = rowsH + 24
        let h = min(maxH, contentH)
        frame = CGRect(x: area.width - Metrics.scrollbarGutter - RailGeometry.edgeInset - RailGeometry.popoverWidth - 4,
                       y: area.height / 2 - h / 2, width: RailGeometry.popoverWidth, height: h)
        scroll.frame = bounds
        list.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentH)
        drawer.frame = list.bounds
        // open scrolled so the active row is centred
        if let a = rail.activeIndex {
            let rowY = 12 + CGFloat(a) * 23.5
            let target = max(0, min(contentH - h, rowY - h / 2 + 19.5 / 2))
            scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = rail.model.palette_
        p.surfaceCard.setFill(); bounds.fill()
        p.cardUnderlay.setFill(); bounds.fill(using: .sourceOver)
        p.lineSubtler.setStroke()
        let path = roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5), 15.5)
        path.lineWidth = 1
        path.stroke()
    }

    func rowIndex(at p: CGPoint) -> Int? {
        let y = p.y - 12
        guard y >= 0 else { return nil }
        let i = Int(y / 23.5)
        return i < rail.headings.count && y - CGFloat(i) * 23.5 <= 19.5 ? i : nil
    }

    final class ListDrawer: FlippedView {
        unowned let owner: OutlinePopoverView
        init(owner: OutlinePopoverView) { self.owner = owner; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let p = owner.rail.model.palette_
            for (i, h) in owner.rail.headings.enumerated() {
                var s = owner.rowStyle
                if i == owner.rail.activeIndex { s.color = p.accent } else if i == owner.hovered { s.color = p.textPrimary }
                let x = 16 + CGFloat(max(0, h.level - 2)) * owner.indent
                s.draw(h.text, x: x, lineTop: 12 + CGFloat(i) * 23.5, lineHeight: 19.5, maxWidth: bounds.width - 16 - x, in: ctx)
            }
        }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseMoved(with event: NSEvent) { owner.hovered = owner.rowIndex(at: convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) {
            owner.hovered = nil
            let rail = owner.rail
            let p = rail.convert(event.locationInWindow, from: nil)
            if !RailGeometry.zone(count: rail.headings.count, areaWidth: rail.bounds.width, areaHeight: rail.bounds.height).contains(p)
                && !owner.frame.contains(p) { rail.closePopover() }
        }
        override func mouseUp(with event: NSEvent) {
            if let i = owner.rowIndex(at: convert(event.locationInWindow, from: nil)) { owner.rail.onSelect?(owner.rail.headings[i]) }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let i = owner.rowIndex(at: convert(event.locationInWindow, from: nil)) else { return nil }
            return owner.rail.headingMenu(owner.rail.headings[i])
        }
    }
}


/// Appends unexplained scroll jumps to ~/Library/Logs/Flo State/scroll.log
/// (y before/after, doc height, caret, event, call stack) to debug live-only bugs.
@MainActor
enum ScrollJumpLog {
    static func record(from: CGFloat, to: CGFloat, controller c: EditorController) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Flo State")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scroll.log")
        let head = c.state.selection.main.head
        let caret = c.rect(forPosition: head, in: c.textView).map { "\($0)" } ?? "nil"
        let usage = c.textView.textLayoutManager?.usageBoundsForTextContainer ?? .zero
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(25).joined(separator: "\n    ")
        let line = """
        \(Date()) jump \(Int(from)) -> \(Int(to)) docH=\(Int(c.textView.frame.height)) usage=\(usage) clipH=\(Int(c.scrollView.contentView.bounds.height)) head=\(head)/\(c.state.doc.length) caret=\(caret) event=\(String(describing: NSApp.currentEvent?.type))
            \(stack)

        """
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

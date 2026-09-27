import AppKit
import FloCore
import FloKit

/// Web-view keyboard shortcuts (`use-keyboard-shortcuts.ts`) → actions.
enum ShellKeys {
    struct Key: Equatable {
        var keyCode: UInt16
        var chars: String
        var command = false, shift = false, option = false, control = false
    }

    static func key(_ e: NSEvent) -> Key {
        let f = e.modifierFlags
        return Key(keyCode: e.keyCode, chars: e.charactersIgnoringModifiers ?? "", command: f.contains(.command),
                   shift: f.contains(.shift), option: f.contains(.option), control: f.contains(.control))
    }

    /// `editorFocused` = an editable element (editor / text field) has focus.
    static func action(_ k: Key, editorFocused: Bool, compact: Bool) -> ShellAction? {
        let mod = k.command || k.control
        // Cmd+Shift+[ / ]
        if mod && k.shift && [33, 30].contains(k.keyCode) {
            return compact ? nil : (k.keyCode == 33 ? .previousTab : .nextTab)
        }
        // Cmd+Alt+Up/Down
        if mod && k.option && !k.shift && (k.keyCode == 126 || k.keyCode == 125) {
            return compact ? nil : .stepFile(k.keyCode == 126 ? -1 : 1)
        }
        // Alt+Left/Right outside editable targets
        if k.option && !k.shift && !k.command && !k.control && k.keyCode == 123 && !editorFocused { return .back }
        if k.option && !k.shift && !k.command && !k.control && k.keyCode == 124 && !editorFocused { return .forward }
        // Cmd+O
        if mod && !k.shift && !k.option && k.keyCode == 31 { return .openFileSearch }
        // Cmd+.
        if mod && !k.shift && !k.option && k.keyCode == 47 { return .toggleSidebar }
        // Ctrl+Tab / Ctrl+Shift+Tab
        if k.control && k.keyCode == 48 { return compact ? nil : (k.shift ? .previousTab : .nextTab) }
        // Cmd+1…9
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if mod && !k.shift && !k.option, let n = digits[k.keyCode] { return compact ? nil : .selectTab(n) }
        return nil
    }
}

/// Last activation time for jump-to-bottom (the web app's localStorage key).
struct UIStateStore {
    let url: URL
    func lastActivatedAt() -> Double {
        guard let d = try? Data(contentsOf: url), let j = try? JSON.parse(data: d) else { return 0 }
        return j["last_activated_at"]?.doubleValue ?? 0
    }
    func markActivated(_ ms: Double) {
        try? Data(JSON.prettyString(.object([("last_activated_at", .double(ms))])).utf8).write(to: url)
    }
}

/// `anchor-warning-banner.tsx`: click to dismiss.
final class AnchorBannerView: FlippedView {
    unowned let model: ShellModel
    init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    var style: TextStyle { TextStyle(font: UIFonts.ui(model.values), color: model.palette_.textSecondary, kern: -0.13) }
    func size(maxWidth: CGFloat) -> CGSize {
        CGSize(width: min(maxWidth, style.width(model.anchorWarning ?? "") + 24), height: 19.5 + 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let m = model.anchorWarning else { return }
        let p = model.palette_
        let path = roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5), 7.5)
        p.surfaceCard.setFill(); path.fill()
        p.lineSubtler.setStroke(); path.lineWidth = 1; path.stroke()
        style.draw(m, x: 12, lineTop: 8, lineHeight: 19.5, maxWidth: bounds.width - 24, in: ctx)
    }
    override func mouseUp(with event: NSEvent) { model.anchorWarning = nil }
}

/// Editor area: one pane per kept-alive tab (+ launcher), footer, outline rail.
@MainActor
final class EditorAreaView: FlippedView {
    unowned let model: ShellModel
    private(set) var panes: [String: NSView] = [:]
    let footer: StatusBarView
    let rail: OutlineRailView
    let anchorBanner: AnchorBannerView
    private var headingsCache: (path: String, content: String, headings: [DocumentHeading])?
    /// The find/replace card (`EditorSearchOverlay`), shared by the panes.
    let findOverlay = FindOverlayView()

    init(model: ShellModel) {
        self.model = model
        footer = StatusBarView(model: model)
        rail = OutlineRailView(model: model)
        anchorBanner = AnchorBannerView(model: model)
        super.init(frame: .zero)
        addSubview(footer)
        addSubview(rail)
        addSubview(anchorBanner)
        rail.onSelect = { [weak self] h in self?.activeFilePane?.scrollToHeading(h); self?.updateRail() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        model.palette_.bg.setFill()
        bounds.fill(using: .sourceOver)
    }

    var activeTab: Tab? { model.editor.activeTab }
    var activePane: NSView? { activeTab.flatMap { panes[$0.id] } }
    var activeFilePane: EditorPaneView? { activePane as? EditorPaneView }

    /// Tabs changed: create/remove panes, show the active one.
    func reloadTabs() {
        let tabs = model.editor.tabs
        let activeId = model.editor.activeTabId
        for (id, v) in panes {
            let tab = tabs.first { $0.id == id }
            var stale = tab == nil
            if let t = tab {
                if let fp = v as? EditorPaneView { stale = t.location != .file(fp.path) }
                else if v is LauncherView { stale = !t.location.isLauncher || id != activeId }
            }
            if stale { v.removeFromSuperview(); panes[id] = nil }
        }
        for t in tabs where panes[t.id] == nil && (t.location.keepAlive || t.id == activeId) {
            let v: NSView
            switch t.location {
            case let .file(p):
                let pane = EditorPaneView(path: p, model: model)
                pane.onScroll = { [weak self] in self?.updateRail() }
                v = pane
            case .settings: v = LauncherView(model: model) // never shown: settings tabs are purged
            case .launcher: v = LauncherView(model: model)
            }
            panes[t.id] = v
            addSubview(v, positioned: .below, relativeTo: footer)
        }
        for (id, v) in panes { v.isHidden = id != activeId }
        for v in panes.values { (v as? EditorPaneView)?.sync() }
        // one find card per editor area; it closes when its pane goes inactive
        for (id, v) in panes {
            guard let c = (v as? EditorPaneView)?.controller else { continue }
            c.features.findOverlay = findOverlay
            c.features.findOverlayHost = self
            if id != activeId { c.features.closeFind() }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateChrome()
    }

    /// Content changed (typing, reload): panes, footer, rail.
    func reloadContent() {
        for v in panes.values { (v as? EditorPaneView)?.sync() }
        updateChrome()
    }

    func updateChrome() {
        if let path = activeTab?.location.primaryPath, let f = model.editor.file(path), !f.isLoading {
            footer.metrics = FooterMetrics.visible(f.stats, model.values)
        } else {
            footer.metrics = []
        }
        footer.isHidden = footer.metrics.isEmpty || model.isCompact
        updateRail()
    }

    func headings(for path: String) -> [DocumentHeading] {
        guard let f = model.editor.file(path) else { return [] }
        if let c = headingsCache, c.path == path, c.content == f.content { return c.headings }
        let h = DocumentHeadings.forOutline(f.content)
        headingsCache = (path, f.content, h)
        return h
    }

    func updateRail() {
        guard model.values.editorShowOutline, let pane = activeFilePane, model.editor.file(pane.path)?.isLoading == false else {
            rail.isHidden = true
            rail.headings = []
            return
        }
        let hs = headings(for: pane.path)
        rail.isHidden = hs.isEmpty
        if rail.headings != hs { rail.headings = hs; rail.updateTrackingAreas() }
        rail.activeIndex = pane.activeHeadingIndex(hs)
    }

    override func layout() {
        super.layout()
        for v in panes.values { v.frame = bounds }
        footer.frame = CGRect(x: 0, y: bounds.height - Metrics.footerHeight, width: bounds.width, height: Metrics.footerHeight)
        rail.frame = bounds
        if let pop = rail.popover { pop.layoutFor(bounds) }
        anchorBanner.isHidden = model.anchorWarning == nil
        let bs = anchorBanner.size(maxWidth: bounds.width * 0.9)
        anchorBanner.frame = CGRect(x: (bounds.width - bs.width) / 2, y: 24, width: bs.width, height: bs.height)
        anchorBanner.needsDisplay = true
    }

    func rebuildEditorThemes() {
        for v in panes.values { (v as? EditorPaneView)?.rebuildTheme() }
        for v in panes.values { v.needsDisplay = true }
    }
}

/// `data-tauri-drag-region`: the top 72px move the window; double-click zooms.
final class DragRegionView: NSView {
    var passThrough: () -> [CGRect] = { [] }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        return passThrough().contains { $0.contains(p) } ? nil : self
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        window?.performDrag(with: event)
    }
}

/// Sidebar resize handle: 8px hit area centred on the sidebar edge; a 2px
/// #2a6fd6 line on hover/drag; clamp 220…min(420, max(280, 35% viewport)).
final class SidebarResizeHandle: FlippedView {
    unowned let model: ShellModel
    var onDrag: ((CGFloat?) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragStart: (x: CGFloat, width: CGFloat)?
    init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { if dragStart == nil { hovering = false } }
    override func mouseDown(with event: NSEvent) {
        dragStart = (event.locationInWindow.x, model.sidebarWidth)
        hovering = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let d = dragStart else { return }
        let w = Metrics.clampSidebarWidth(Double(d.width + event.locationInWindow.x - d.x), viewport: model.windowWidth)
        onDrag?(w)
    }
    override func mouseUp(with event: NSEvent) {
        guard let d = dragStart else { return }
        dragStart = nil
        let w = Metrics.clampSidebarWidth(Double(d.width + event.locationInWindow.x - d.x), viewport: model.windowWidth)
        onDrag?(nil)
        if w != model.sidebarWidth { model.setSetting("appearance.sidebar-width", .number(Double(w))) }
        hovering = false
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering || dragStart != nil else { return }
        NSColor(srgbRed: 0x2a / 255.0, green: 0x6f / 255.0, blue: 0xd6 / 255.0, alpha: 1).setFill()
        CGRect(x: 4, y: 0, width: 2, height: bounds.height).fill()
    }
}

/// The window's root content view: background, sidebar, editor area, tab
/// chrome, collapsed toggle, palette overlay (`app-layout.tsx`).
@MainActor
final class ShellRootView: FlippedView {
    unowned let model: ShellModel
    let effect = NSVisualEffectView()
    /// The sidebar column: its width animates (web: `width 140ms ease-out`,
    /// overflow hidden) while the panel inside keeps its full width.
    let sidebarClip = FlippedView()
    /// Legacy's inactive-window backdrop (dark): flat rgb(22,22,17).
    let inactiveBase = FlippedView()
    let sidebar: SidebarView
    let area: EditorAreaView
    let tabBacking = FlippedView()
    /// `backdrop-filter: blur(24px)` under the tab strip's `--bg` backing.
    /// A pure Gaussian backdrop blur, clipped to the strip (an
    /// NSVisualEffectView material tints the strip lighter than the web's,
    /// and an unclipped blur bleeds over the editor).
    let tabBlur = FlippedView()
    let collapsedToggle = IconButton(icon: .sidebarLeft)
    let tabs: TabStripView
    let welcome: WelcomeView
    let dragRegion = DragRegionView()
    let compactHeader: CompactHeaderView
    let resizeHandle: SidebarResizeHandle
    /// Live width while dragging the handle (not yet persisted).
    var draftSidebarWidth: CGFloat?
    private(set) var paletteOverlay: PaletteOverlayView?
    /// Snapshot mode: paint an opaque white base (what a headless browser composites onto).
    var opaqueBase = false

    init(model: ShellModel) {
        self.model = model
        sidebar = SidebarView(model: model)
        area = EditorAreaView(model: model)
        tabs = TabStripView(model: model)
        welcome = WelcomeView(model: model)
        resizeHandle = SidebarResizeHandle(model: model)
        compactHeader = CompactHeaderView(model: model)
        super.init(frame: .zero)
        // Measured against the legacy window (same settings, dark): its backdrop
        // under the translucent --bg reads as rgb(38,38,38) active and
        // rgb(22,22,22) inactive, flat (no blur texture). `.windowBackground`
        // (active) reproduces the active value exactly; the inactive value is a
        // flat layer shown while the window isn't key (`inactiveBase`).
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        ShellRootView.applyVibrancyOverrides(effect)
        addSubview(effect)
        addSubview(inactiveBase)
        inactiveBase.isHidden = true
        sidebarClip.wantsLayer = true
        sidebarClip.layer?.masksToBounds = true
        sidebarClip.addSubview(sidebar)
        addSubview(sidebarClip)
        addSubview(area)
        applyBackdropBlur(tabBlur, radius: 24)
        addSubview(tabBlur)
        addSubview(tabBacking)
        addSubview(dragRegion)
        addSubview(resizeHandle)
        addSubview(collapsedToggle)
        addSubview(tabs)
        dragRegion.passThrough = { [unowned self] in
            var r: [CGRect] = []
            if !self.sidebar.isHidden { r.append(self.sidebar.toggle.convert(self.sidebar.toggle.bounds, to: self)) }
            if !self.collapsedToggle.isHidden { r.append(self.collapsedToggle.frame) }
            return r
        }
        resizeHandle.onDrag = { [unowned self] w in self.draftSidebarWidth = w; self.needsLayout = true }
        addSubview(welcome)
        welcome.onAddFolder = { [weak model] in model?.perform(.openWorkspacePanel) }
        welcome.onStartFromScratch = { [weak model] in model?.startFromScratch() }
        welcome.onOpenFile = { [weak model] in
            let p = NSOpenPanel()
            p.canChooseFiles = true
            p.canChooseDirectories = false
            guard p.runModal() == .OK, let url = p.url, let m = model else { return }
            m.openPickedFile(url.path)
        }
        registerForDraggedTypes([.fileURL])
        collapsedToggle.action = { [weak model] in model?.toggleSidebar() }
        collapsedToggle.toolTipText = "Show sidebar"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Headless Chrome composites the transparent page onto white (light)
        // or a #404040 canvas (dark); mirror that for parity captures.
        if opaqueBase { (model.mode == .dark ? NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1) : NSColor.white).setFill(); bounds.fill() }
    }

    var compact: Bool { model.root == nil }

    /// Diagnostics: `defaults write app.flostate.native FloVibrancy <hud|under|window|sidebar|menu|none>`
    /// and `FloVibrancyState <active|inactive|follow>` (used to match the legacy window's backdrop).
    static func applyVibrancyOverrides(_ v: NSVisualEffectView) {
        let d = UserDefaults.standard
        switch d.string(forKey: "FloVibrancy") {
        case "under": v.material = .underWindowBackground
        case "window": v.material = .windowBackground
        case "sidebar": v.material = .sidebar
        case "menu": v.material = .menu
        case "none": v.isHidden = true
        default: break
        }
        switch d.string(forKey: "FloVibrancyState") {
        case "active": v.state = .active
        case "inactive": v.state = .inactive
        default: break
        }
    }


    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        effect.frame = bounds
        inactiveBase.frame = bounds
        // key state decides the backdrop (legacy darkens when inactive)
        setWindowActive(window?.isKeyWindow ?? false)
        effect.isHidden = opaqueBase || UserDefaults.standard.string(forKey: "FloVibrancy") == "none"
        let showSidebar = model.sidebarVisible
        let S = draftSidebarWidth ?? model.sidebarWidth
        // 140ms ease-out between column widths (toggle, 850px auto-hide);
        // every frame below derives from the one interpolated width, so the
        // sidebar, editor and tab chrome move together with no gap.
        let target = showSidebar ? S : 0
        let targetLeft = showSidebar ? S + 12 : Metrics.collapsedTabLeft
        let (vw, left) = columnGeometry(target: target, targetLeft: targetLeft, dragging: draftSidebarWidth != nil)
        sidebarClip.isHidden = vw <= 0
        sidebarClip.frame = CGRect(x: 0, y: 0, width: vw, height: H)
        sidebar.isHidden = vw <= 0
        sidebar.frame = CGRect(x: 0, y: 0, width: max(vw, showSidebar ? S : (sidebarAnimation?.fromWidth ?? vw)), height: H)
        let areaX = vw
        area.frame = CGRect(x: areaX, y: 0, width: W - areaX, height: H)
        tabBacking.frame = CGRect(x: areaX, y: 0, width: W - areaX, height: Metrics.tabBackingHeight)
        tabBlur.frame = tabBacking.frame
        tabBacking.fillColor = model.palette_.bg
        collapsedToggle.isHidden = showSidebar || compact
        collapsedToggle.frame = CGRect(x: 92, y: 12 + (Metrics.chromeControlHeight - 28) / 2, width: 28, height: 28)
        dragRegion.frame = CGRect(x: 0, y: 0, width: W, height: Metrics.chromeDragHeight)
        resizeHandle.isHidden = !showSidebar || sidebarAnimation != nil
        resizeHandle.frame = CGRect(x: S - 4, y: Metrics.chromeDragHeight, width: 8, height: max(0, H - Metrics.chromeDragHeight))
        tabs.isHidden = compact
        tabs.frame = CGRect(x: left, y: 0, width: max(0, W - 12 - left), height: Metrics.chromeRowHeight)
        paletteOverlay?.frame = bounds
        compactHeader.isHidden = !model.isCompact
        compactHeader.frame = CGRect(x: 0, y: 0, width: W, height: Metrics.chromeRowHeight)
        compactHeader.needsDisplay = true
        let showWelcome = model.root == nil && model.editor.tabs.isEmpty
        welcome.isHidden = !showWelcome
        welcome.frame = bounds
        area.isHidden = showWelcome
        tabBacking.isHidden = showWelcome
        tabBlur.isHidden = showWelcome || opaqueBase
        welcome.needsDisplay = true
    }

    // MARK: sidebar animation (app-layout.tsx: width/left 140ms ease-out)

    struct SidebarAnimation {
        var start: CFTimeInterval
        var fromWidth: CGFloat, toWidth: CGFloat
        var fromLeft: CGFloat, toLeft: CGFloat
    }
    static let sidebarAnimationDuration: CFTimeInterval = 0.14
    var animationsEnabled = true
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }
    private(set) var sidebarAnimation: SidebarAnimation?
    private var appliedWidth: CGFloat?
    private var appliedLeft: CGFloat?
    private var animationTimer: Timer?

    /// CSS `ease-out` = cubic-bezier(0, 0, 0.58, 1).
    static func easeOut(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // solve bezier x(t) = x for t (P1=(0,0), P2=(0.58,1))
        func bx(_ t: Double) -> Double { 3 * (1 - t) * t * t * 0.58 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * t * t * 1 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 { t = (lo + hi) / 2; if bx(t) < x { lo = t } else { hi = t } }
        return by(t)
    }

    private func columnGeometry(target: CGFloat, targetLeft: CGFloat, dragging: Bool) -> (CGFloat, CGFloat) {
        let canAnimate = animationsEnabled && !opaqueBase && !dragging && window != nil
        if let w = appliedWidth, let l = appliedLeft, w != target, canAnimate, sidebarAnimation?.toWidth != target {
            // start (or retarget) from where the column is right now
            sidebarAnimation = SidebarAnimation(start: now(), fromWidth: w, toWidth: target, fromLeft: l, toLeft: targetLeft)
            startAnimationTimer()
        } else if !canAnimate {
            sidebarAnimation = nil
        }
        var w = target, l = targetLeft
        if let a = sidebarAnimation {
            let p = min(1, (now() - a.start) / ShellRootView.sidebarAnimationDuration)
            let e = CGFloat(ShellRootView.easeOut(p))
            w = a.fromWidth + (a.toWidth - a.fromWidth) * e
            l = a.fromLeft + (a.toLeft - a.fromLeft) * e
            if p >= 1 { sidebarAnimation = nil; w = target; l = targetLeft; stopAnimationTimer() }
        }
        appliedWidth = w
        appliedLeft = l
        return (w, l)
    }

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        animationTimer = t
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: Finder drops

    private func droppedPaths(_ info: NSDraggingInfo) -> [String] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).map { $0.path }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPaths(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedPaths(sender)
        let images = paths.filter { WorkspaceFS.isImagePath($0) }
        let others = paths.filter { !WorkspaceFS.isImagePath($0) }
        if !images.isEmpty, let pane = area.activeFilePane {
            pane.insertDroppedImages(model.importDroppedImages(images, into: pane.path))
        }
        if !others.isEmpty { model.openDroppedPaths(others) }
        return !paths.isEmpty
    }

    /// Window key state: legacy darkens its backdrop when inactive (dark mode).
    /// The legacy window's backdrop under the translucent `--bg`, measured on
    /// the real window (flat, no blur texture): dark active rgb(38,38,38) —
    /// what `.windowBackground` renders —, dark inactive (22,22,17), light
    /// (228,228,228) active and inactive.
    static func legacyBackdrop(dark: Bool, active: Bool) -> NSColor? {
        if dark && active { return nil }   // the material itself
        if dark { return NSColor(srgbRed: 22 / 255, green: 22 / 255, blue: 17 / 255, alpha: 1) }
        return NSColor(srgbRed: 228 / 255, green: 228 / 255, blue: 228 / 255, alpha: 1)
    }

    func setWindowActive(_ active: Bool) {
        let c = ShellRootView.legacyBackdrop(dark: model.mode == .dark, active: active)
        inactiveBase.fillColor = c
        inactiveBase.isHidden = c == nil || opaqueBase
    }

    func applyPalette() {
        let p = model.palette_
        collapsedToggle.color = p.fgBase
        collapsedToggle.hoverBg = p.surfaceSubtle
        collapsedToggle.needsDisplay = true
        tabBacking.fillColor = p.bg
        area.needsDisplay = true
        sidebar.needsDisplay = true
    }

    func syncPalette() {
        if model.palette != nil {
            if paletteOverlay == nil {
                let o = PaletteOverlayView(model: model)
                paletteOverlay = o
                addSubview(o)
                o.frame = bounds
                o.reload(resetField: true)
                o.focus()
            } else {
                paletteOverlay?.reload(resetField: false)
            }
        } else if let o = paletteOverlay {
            o.removeFromSuperview()
            paletteOverlay = nil
            if let pane = area.activeFilePane, let c = pane.controller { window?.makeFirstResponder(c.textView) }
        }
    }

    /// JSON dump of chrome frames (same shape as oracle/shell_dump.js).
    func dump() -> [String: Any] {
        var out: [String: Any] = ["window": [0, 0, Double(bounds.width), Double(bounds.height)]]
        let showSidebar = model.sidebarVisible
        out["sidebarVisible"] = showSidebar
        if showSidebar {
            for (k, v) in sidebar.dump() { out[k] = v }
        } else {
            out["sidebarToggle"] = collapsedToggle.frameInRoot().dumpArray
        }
        out["tabs"] = tabs.dump()
        out["newTabButton"] = tabs.plus.frameInRoot().dumpArray
        if !area.footer.isHidden {
            out["footer"] = ["rect": area.footer.frameInRoot().dumpArray, "text": area.footer.text]
        } else {
            out["footer"] = NSNull()
        }
        out["railTicks"] = area.rail.isHidden ? [] : area.rail.dump()
        if let p = paletteOverlay?.dump() { out["palette"] = p }
        if let l = area.activePane as? LauncherView { out["launcher"] = l.dump() }
        if let pane = area.activeFilePane, let c = pane.controller {
            let pos = c.state.doc.lines >= 3 ? c.state.doc.line(3).from : 0
            if let top = c.lineTop(forPosition: pos, in: self) { out["editorProbe"] = [0, (Double(top) * 100).rounded() / 100] }
        }
        if let fm = area.activeFilePane?.frontmatterPanel, !fm.isHidden {
            out["frontmatter"] = [
                "rows": fm.rows.entries.indices.map { i -> [String: Any] in
                    ["rect": fm.convertToRootRect(fm.rowRect(i)).dumpArray, "key": fm.rows.entries[i].key, "value": fm.rows.entries[i].value]
                },
                "add": fm.convertToRootRect(fm.addRect).dumpArray,
            ]
        } else {
            out["frontmatter"] = NSNull()
        }
        out["title"] = model.editor.windowTitle()
        return out
    }
}

/// Window that reports every layout pass (AppKit re-lays out the titlebar,
/// and with it the traffic lights, on title/key/size changes).
final class ShellNSWindow: NSWindow {
    var afterLayout: (() -> Void)?
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        afterLayout?()
    }
    override var title: String {
        didSet { afterLayout?() }
    }
}

/// One workspace (or compact) window.
@MainActor
final class ShellWindowController: NSWindowController, NSWindowDelegate {
    let model: ShellModel
    let root: ShellRootView
    private var keyMonitor: Any?
    private var refreshScheduled: Set<String> = []
    let uiState: UIStateStore
    var onClose: ((ShellWindowController) -> Void)?

    init(model: ShellModel, frame: NSRect = NSRect(x: 0, y: 0, width: 1200, height: 800), offscreen: Bool = false) {
        self.model = model
        root = ShellRootView(model: model)
        uiState = UIStateStore(url: model.dataDir.baseURL.appendingPathComponent("ui_state.json"))
        let w = ShellNSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isOpaque = false
        w.backgroundColor = .clear
        w.minSize = NSSize(width: 400, height: 500)
        w.isReleasedWhenClosed = false
        w.contentView = root
        w.tabbingMode = .disallowed
        // An (empty) unified toolbar gives the window the system's large,
        // continuous-curvature corner radius used by Finder & co.
        let tb = NSToolbar(identifier: "FloStateWindow")
        tb.allowsUserCustomization = false
        tb.displayMode = .iconOnly
        w.toolbar = tb
        w.toolbarStyle = .unified
        super.init(window: w)
        w.delegate = self
        w.afterLayout = { [weak self] in self?.positionTrafficLights() }
        model.windowWidth = frame.width
        wire()
        applyTheme()
        if !offscreen {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                // nil = handled (swallow). `self?.handleKey(e) ?? e` turned every nil back into
                // the event, so AppKit dispatched menu shortcuts a second time (Cmd-\ toggled twice).
                MainActor.assumeIsolated { guard let self = self else { return e }; return self.handleKey(e) }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        model.observers.append { [weak self] change in self?.changed(change) }
        model.requestWindowClose = { [weak self] in self?.window?.performClose(nil) }
        model.editorCommand = { [weak self] req in self?.runEditorCommand(req) }
        model.scrollToAnchor = { [weak self] slug in self?.root.area.activeFilePane?.scrollToSlug(slug) ?? false }
        model.alert = { [weak self] msg in
            let a = NSAlert()
            a.messageText = msg
            if let w = self?.window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
        }
        model.confirm = { msg in
            let a = NSAlert()
            a.messageText = msg
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            return a.runModal() == .alertFirstButtonReturn
        }
        model.pickFolder = {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.allowsMultipleSelection = false
            p.prompt = "Open"
            return p.runModal() == .OK ? p.url?.path : nil
        }
    }

    // MARK: change routing

    private func changed(_ c: ShellModel.Change) {
        switch c {
        case .palette:
            root.syncPalette()
        case .editorFont:
            root.area.rebuildEditorThemes()
        case .theme:
            applyTheme()
        default:
            schedule(c)
        }
    }

    /// Coalesce UI refreshes to one per runloop turn.
    private func schedule(_ c: ShellModel.Change) {
        let key = "\(c)"
        if refreshScheduled.isEmpty {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        }
        refreshScheduled.insert(key)
    }

    /// Switching tabs puts the caret in the new tab's editor. Waits for the
    /// file to load (no controller yet), and leaves an inline rename or the
    /// palette alone.
    private var focusedTabId: String?
    private func focusEditorOnTabSwitch() {
        guard let tab = root.area.activeTab else { focusedTabId = nil; return }
        guard "\(tab.id)" != focusedTabId, let c = root.area.activeFilePane?.controller else { return }
        focusedTabId = "\(tab.id)"
        guard root.paletteOverlay == nil, let w = window else { return }
        if let t = w.firstResponder as? NSText, t.isFieldEditor { return }
        w.makeFirstResponder(c.textView)
    }

    func flush() {
        let s = refreshScheduled
        refreshScheduled = []
        if s.isEmpty { return }
        if s.contains("layout") { root.area.needsLayout = true }
        if s.contains("tabs") || s.contains("settings") || s.contains("layout") {
            root.area.reloadTabs()
            root.tabs.reload()
            root.sidebar.reload()
            root.applyPalette()
            root.needsLayout = true
        } else {
            if s.contains("content") {
                root.area.reloadContent()
                root.tabs.reload()
                root.compactHeader.needsDisplay = true
            }
            if s.contains("sidebar") || s.contains("content") { root.sidebar.reload() }
        }
        if let r = model.pendingReveal, model.editor.activeFilePath == r.path,
           let pane = root.area.activeFilePane, pane.controller != nil {
            model.pendingReveal = nil
            pane.reveal(offset: r.offset, length: r.length)
        }
        if let (path, slug) = model.pendingAnchor, model.editor.activeFilePath == path,
           let pane = root.area.activeFilePane, pane.controller != nil {
            model.pendingAnchor = nil
            if !pane.scrollToSlug(slug) { model.anchorWarning = "Heading \"#\(slug)\" not found in this document" }
        }
        focusEditorOnTabSwitch()
        window?.title = model.editor.windowTitle()
        positionTrafficLights()   // AppKit re-lays out the titlebar on title changes
        if root.paletteOverlay != nil { root.paletteOverlay?.reload(resetField: false) }
    }

    func applyTheme() {
        let dark = model.mode == .dark
        window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        root.applyPalette()
        root.setWindowActive(window?.isKeyWindow ?? false)
        root.area.rebuildEditorThemes()
        schedule(.settings)
    }

    // MARK: keyboard

    func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        let fr = window?.firstResponder
        let editorFocused = fr is NSTextView || fr is NSTextField
        if e.keyCode == 53, model.palette != nil { model.palette = nil; return nil }
        if e.keyCode == 53, !model.selectedPaths.isEmpty { model.selectedPaths = []; return nil }
        if e.keyCode == 53, root.area.rail.popover != nil { root.area.rail.closePopover(); return nil }
        let k = ShellKeys.key(e)
        if MainMenu.menuWins(keyCode: k.keyCode, command: k.command, shift: k.shift, option: k.option, control: k.control),
           NSApp?.mainMenu?.performKeyEquivalent(with: e) == true {
            return nil
        }
        // Everything else that is a menu item goes through NSApp's normal
        // key-equivalent path (editor keymap first, then the menu, which
        // flashes its title). Only Alt-←/→ outside the editor are not menu
        // items (as menu keys they'd steal the editor's word motion).
        if let a = ShellKeys.action(k, editorFocused: editorFocused, compact: model.root == nil), a == .back || a == .forward {
            model.perform(a)
            return nil
        }
        return e
    }

    // MARK: editor commands

    private func runEditorCommand(_ r: ShellModel.EditorCommandRequest) {
        guard let pane = root.area.activeFilePane else { return }
        switch r {
        case .goToToday: pane.goToToday()
        case .autoInsertDaily: pane.autoInsertDaily()
        case .collapseAll: _ = pane.controller?.collapseAllHeadings()
        case .expandAll: _ = pane.controller?.expandAllHeadings()
        }
    }

    // MARK: activation (jump to bottom + daily heading)

    /// `useJumpToBottomOnReturn.onFocus`.
    func didActivate(nowMs: Double = Date().timeIntervalSince1970 * 1000) {
        let away = nowMs - uiState.lastActivatedAt()
        if !model.readOnly { uiState.markActivated(nowMs) }
        model.maybeAutoInsertDaily()
        if DailyNote.shouldJumpToBottom(awayMs: away, minutes: model.values.editorJumpToBottomAfterMinutes) {
            root.area.activeFilePane?.jumpToEnd()
        }
        root.area.updateRail()
    }

    func windowDidBecomeKey(_ notification: Notification) { root.setWindowActive(true); root.needsLayout = true; didActivate(); positionTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { root.setWindowActive(false); root.needsLayout = true; positionTrafficLights() }

    func windowDidResize(_ notification: Notification) {
        if let w = window { model.windowWidth = w.frame.width }
        positionTrafficLights()
        root.needsLayout = true
    }

    func windowWillClose(_ notification: Notification) {
        model.windowWillClose()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        onClose?(self)
    }

    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }

    /// Secondary windows: a random spot in the work area of the screen under the cursor.
    static func randomFrame(size: CGSize, mouse: CGPoint = NSEvent.mouseLocation, screens: [NSScreen] = NSScreen.screens) -> CGRect? {
        guard let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? screens.first else { return nil }
        let area = screen.visibleFrame
        let w = min(size.width, area.width), h = min(size.height, area.height)
        let x = area.minX + CGFloat.random(in: 0...max(0, area.width - w))
        let y = area.minY + CGFloat.random(in: 0...max(0, area.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// tao's `set_traffic_light_inset(20, 29)`.
    private var trafficObservers: [NSObjectProtocol] = []
    private var positioningLights = false
    private var trafficSpacing: CGFloat?
    private var trafficReapplyQueued = false

    /// tao's `set_traffic_light_inset(20, 29)`. AppKit resets the buttons and
    /// their container whenever it re-lays out the titlebar (title changes,
    /// resize, key state), so every one of those views is observed and the
    /// inset re-applied synchronously.
    func positionTrafficLights(x: CGFloat = 20, y: CGFloat = 29) {
        if positioningLights { queueTrafficReapply(); return }
        guard let w = window, let close = w.standardWindowButton(.closeButton),
              let mini = w.standardWindowButton(.miniaturizeButton), let zoom = w.standardWindowButton(.zoomButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        positioningLights = true
        defer { positioningLights = false }
        if trafficObservers.isEmpty {
            for v in [close, mini, zoom, titlebar, container] {
                v.postsFrameChangedNotifications = true
                trafficObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.positionTrafficLights()
                        self?.queueTrafficReapply()   // AppKit may still be mid-layout
                    }
                })
            }
        }
        // tao grows the titlebar container to button height + y and keeps the
        // buttons' bottom offset (9) — i.e. the close button's top sits at
        // y - 9 = 20 from the window top. With the unified toolbar the container
        // is already taller, so pin that absolute position instead of resizing.
        let bh = close.frame.height
        let minH = bh + y
        var r = container.frame
        if r.size.height < minH {
            r.size.height = minH
            r.origin.y = w.frame.height - minH
            container.frame = r
        } else if r.origin.y != w.frame.height - r.size.height {
            r.origin.y = w.frame.height - r.size.height
            container.frame = r
        }
        if trafficSpacing == nil { trafficSpacing = mini.frame.origin.x - close.frame.origin.x }
        let space = trafficSpacing!
        let topInset = y - 9   // 20: close button top, from the window top
        guard let frameView = w.contentView?.superview else { return }
        for (i, b) in [close, mini, zoom].enumerated() {
            // desired top-left in window space → the button's superview space
            let inFrame = CGPoint(x: x + CGFloat(i) * space,
                                  y: frameView.isFlipped ? topInset : frameView.bounds.height - topInset - bh)
            var target = titlebar.convert(inFrame, from: frameView)
            if titlebar.isFlipped != frameView.isFlipped { target.y -= bh }
            target = CGPoint(x: target.x.rounded(), y: target.y.rounded())
            if b.frame.origin != target { b.setFrameOrigin(target) }
        }
    }

    /// One coalesced re-application on the next runloop turn.
    private func queueTrafficReapply() {
        guard !trafficReapplyQueued else { return }
        trafficReapplyQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.trafficReapplyQueued = false; self?.positionTrafficLights() }
        }
    }

    func showAndFocus(secondary: Bool = false) {
        guard let w = window else { return }
        if secondary, let frame = ShellWindowController.randomFrame(size: w.frame.size) { w.setFrame(frame, display: false) } else { w.center() }
        w.makeKeyAndOrderFront(nil)
        positionTrafficLights()
    }
}

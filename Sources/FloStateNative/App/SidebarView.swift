import AppKit
import FloCore

/// Drop-target rules (`tree-move.ts`).
enum TreeMove {
    /// Folder → into it; file → its parent; empty space → root.
    static func resolveDropDir(_ target: DirEntry?, root: String) -> String {
        guard let t = target else { return root }
        return t.isDir ? t.path : LinkPaths.getParentDir(t.path)
    }

    static func canMoveInto(_ source: String, isDir: Bool, destDir: String) -> Bool {
        if LinkPaths.getParentDir(source) == destDir { return false }
        if isDir && (destDir == source || destDir.hasPrefix(source + "/")) { return false }
        return true
    }

    /// First/last visible row paths of the destination "container".
    static func resolveDropRange(_ rows: [(path: String, depth: Int)], destDir: String, root: String) -> (String, String)? {
        guard !rows.isEmpty else { return nil }
        if destDir == root { return (rows[0].path, rows[rows.count - 1].path) }
        guard let start = rows.firstIndex(where: { $0.path == destDir }) else { return nil }
        let base = rows[start].depth
        var end = start
        for i in (start + 1)..<rows.count { if rows[i].depth > base { end = i } else { break } }
        return (rows[start].path, rows[end].path)
    }
}

/// What the sidebar lists, top to bottom (Pinned, Recents, tree).
enum SidebarItem: Equatable {
    enum Section: String { case pinned = "Pinned", recents = "Recents", tree = "Tree" }
    case header(Section, collapsed: Bool)
    case row(DirEntry, depth: Int, section: Section)
    case showMore(Section)
    case gap(CGFloat)
    case empty(String)
}

/// Pure sidebar layout: item list → y offsets inside the scroll document
/// (py-2, gap-4 between blocks, gap-1 under headers, gap-px between rows).
@MainActor
enum SidebarLayout {
    struct Placed: Equatable { var item: SidebarItem; var y: CGFloat; var height: CGFloat }

    static func items(model: ShellModel) -> [SidebarItem] {
        var blocks: [[SidebarItem]] = []
        let pinned = model.pinnedSection()
        if !pinned.files.isEmpty {
            let collapsed = model.collapsedSections.contains("Pinned")
            var b: [SidebarItem] = [.header(.pinned, collapsed: collapsed)]
            if !collapsed {
                b += pinned.files.map { .row($0, depth: 0, section: .pinned) }
                if pinned.hasMore { b.append(.showMore(.pinned)) }
            }
            blocks.append(b)
        }
        let recents = model.recentsSection()
        if !recents.files.isEmpty {
            let collapsed = model.collapsedSections.contains("Recents")
            var b: [SidebarItem] = [.header(.recents, collapsed: collapsed)]
            if !collapsed {
                b += recents.files.map { .row($0, depth: 0, section: .recents) }
                if recents.hasMore { b.append(.showMore(.recents)) }
            }
            blocks.append(b)
        }
        let flat = model.flatTree()
        blocks.append(flat.isEmpty ? [.empty(L("No files"))] : flat.map { .row($0.entry, depth: $0.depth, section: .tree) })
        var out: [SidebarItem] = []
        for (i, b) in blocks.enumerated() {
            if i > 0 { out.append(.gap(16)) }
            out += b
        }
        return out
    }

    static func place(_ items: [SidebarItem]) -> (placed: [Placed], height: CGFloat) {
        var y: CGFloat = 8
        var out: [Placed] = []
        var prev: SidebarItem?
        for item in items {
            switch item {
            case .gap(let g): y += g; prev = item; continue
            case .header:
                out.append(Placed(item: item, y: y, height: 20)); y += 20
            case .row, .showMore:
                if let p = prev {
                    if case .header = p { y += 4 } else if case .gap = p {} else { y += 1 }
                }
                out.append(Placed(item: item, y: y, height: 32)); y += 32
            case .empty:
                out.append(Placed(item: item, y: y, height: 19.5)); y += 19.5
            }
            prev = item
        }
        return (out, y + 8)
    }
}

// MARK: - Views

/// 28×28 icon button (sidebar toggle): icon opacity .6 → 1 and a subtle
/// background on hover.
final class IconButton: FlippedView {
    var icon: Icon
    var iconSize: CGFloat = 18
    var color: NSColor = .labelColor
    var hoverBg: NSColor = .clear
    var action: (() -> Void)?
    var toolTipText: String? { didSet { toolTip = toolTipText } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(icon: Icon) { self.icon = icon; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Track the click here like NSButton: in the title-bar strip AppKit never
    /// delivers the mouse-up to the view (it treats the press as a possible window drag).
    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        var inside = true
        w.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: NSEvent.foreverDuration, mode: .eventTracking) { e, stop in
            guard let e = e else { stop.pointee = true; return }
            inside = bounds.contains(convert(e.locationInWindow, from: nil))
            hovering = inside
            if e.type == .leftMouseUp { stop.pointee = true }
        }
        if inside { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if hovering { hoverBg.setFill(); roundedPath(bounds, 6).fill() }
        let r = CGRect(x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        icon.draw(in: r, color: color.withAlphaComponent(color.alphaComponent * (hovering ? 1 : 0.6)), ctx: ctx)
    }
}

/// One sidebar row (file/folder/show-more/workspace switcher).
final class SidebarRowView: FlippedView {
    /// An SF Symbol tinted like the custom `Icon`s, fitted in `rect`.
    static func drawSymbol(_ name: String, in rect: CGRect, color: NSColor) {
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return }
        let size = sym.size
        let r = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        let tinted = NSImage(size: size, flipped: false) { b in sym.draw(in: b); color.set(); b.fill(using: .sourceAtop); return true }
        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    enum Kind { case entry(DirEntry, SidebarItem.Section), showMore(SidebarItem.Section), switcher }
    let kind: Kind
    var depth: Int = 0
    var label: String = ""
    var isActive = false { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isExpanded = false
    var isDragging = false { didSet { needsDisplay = true } }
    var palette: ShellPalette!
    var font: NSFont = .systemFont(ofSize: 13)
    weak var sidebar: SidebarView?
    private(set) var hovering = false { didSet { needsDisplay = true } }
    var renameField: NSTextField?

    init(kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var entry: DirEntry? { if case let .entry(e, _) = kind { return e }; return nil }
    var paddingLeft: CGFloat { depth == 0 ? 10 : CGFloat(depth) * 12 + 6 }
    var labelX: CGFloat { paddingLeft + 20 + 6 }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if sidebar?.dragState == nil { hovering = true } }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// A freshly built row under a still pointer starts hovered (no enter event
    /// arrives), so an expanded/collapsed folder keeps showing its chevron.
    func refreshHover() {
        guard let w = window, sidebar?.dragState == nil else { return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        hovering = bounds.contains(p)
    }

    override func mouseDown(with event: NSEvent) { sidebar?.rowMouseDown(self, event) }
    override func mouseDragged(with event: NSEvent) { sidebar?.rowMouseDragged(self, event) }
    override func mouseUp(with event: NSEvent) { sidebar?.rowMouseUp(self, event) }
    override func menu(for event: NSEvent) -> NSMenu? { sidebar?.contextMenu(for: self) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let p = palette else { return }
        let fg = p.fgBase
        var bg: NSColor?
        switch kind {
        case .entry:
            if isSelected { bg = p.surfaceSelected } else if isActive || hovering { bg = p.surfaceSubtle }
        case .showMore, .switcher:
            if hovering { bg = p.surfaceSubtle }
        }
        if let bg = bg, renameField == nil || isActive { bg.setFill(); roundedPath(bounds, 8).fill() }
        ctx.saveGState()
        if isDragging { ctx.setAlpha(0.4) }
        let iconRect = CGRect(x: paddingLeft + 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let highlighted = isActive || isSelected || hovering
        switch kind {
        case let .entry(e, _):
            if e.isDir {
                if hovering {
                    Icon.chevronRight.draw(in: iconRect, color: fg, ctx: ctx, rotation: isExpanded ? .pi / 2 : 0)
                } else {
                    (isExpanded ? Icon.folderOpen : Icon.folderClosed).draw(in: iconRect, color: fg.withAlphaComponent(0.6), ctx: ctx)
                }
            } else if let kind = WorkspaceFS.viewerKind(e.path) {
                // PDFs / images: a distinct glyph, so they don't read as notes
                Self.drawSymbol(kind == .pdf ? "doc.richtext" : "photo", in: iconRect, color: fg.withAlphaComponent(hovering ? 1 : 0.6))
            } else {
                Icon.file.draw(in: iconRect, color: fg.withAlphaComponent(hovering ? 1 : 0.6), ctx: ctx)
            }
            if renameField == nil {
                TextStyle(font: font, color: fg.withAlphaComponent(highlighted ? 1 : 0.6))
                    .draw(label, x: labelX, lineTop: (bounds.height - 13 * 1.15) / 2, lineHeight: 13 * 1.15,
                          maxWidth: bounds.width - labelX - 8, in: ctx)
            }
        case .showMore:
            Icon.ellipsis.draw(in: iconRect, color: fg.withAlphaComponent(hovering ? 1 : 0.6), ctx: ctx)
            TextStyle(font: font, color: fg.withAlphaComponent(hovering ? 1 : 0.6))
                .draw(L("Show More"), x: labelX, lineTop: (bounds.height - 13 * 1.15) / 2, lineHeight: 13 * 1.15, in: ctx)
        case .switcher:
            let c = hovering ? fg : p.textMuted
            Icon.switcher.draw(in: iconRect, color: c, ctx: ctx)
            TextStyle(font: font, color: c)
                .draw(label, x: labelX, lineTop: (bounds.height - 13 * 1.15) / 2, lineHeight: 13 * 1.15,
                      maxWidth: bounds.width - labelX - 8, in: ctx)
        }
        ctx.restoreGState()
    }
}

/// Section header ("Pinned" / "Recents" + chevron).
final class SectionHeaderView: FlippedView {
    let section: SidebarItem.Section
    var collapsed = false
    var palette: ShellPalette!
    var font: NSFont = .systemFont(ofSize: 12, weight: .medium)
    var onToggle: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    init(section: SidebarItem.Section) { self.section = section; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { onToggle?() }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let p = palette else { return }
        ctx.saveGState()
        ctx.setAlpha(hovering ? 1 : 0.6)
        let style = TextStyle(font: font, color: p.textMuted)
        let title = L(section.rawValue)
        let w = style.width(title)
        style.draw(title, x: 12, lineTop: 0, lineHeight: 20, in: ctx)
        Icon.sectionChevron.draw(in: CGRect(x: 12 + w + 4, y: 4, width: 12, height: 12), color: p.textMuted, ctx: ctx,
                                 rotation: collapsed ? 0 : .pi / 2)
        ctx.restoreGState()
    }
}

/// The floating sidebar panel (`sidebar/index.tsx`).
final class SidebarView: FlippedView, NSTextFieldDelegate {
    let model: ShellModel   // strong: AppKit can still lay a view out after its window controller (the other owner) is gone
    let toggle = IconButton(icon: .sidebarLeft)
    let scroll = NSScrollView()
    let document = FlippedView()
    let switcher = SidebarRowView(kind: .switcher)
    let searchButton = SearchFieldButton()
    private(set) var rows: [SidebarRowView] = []
    private(set) var headers: [SectionHeaderView] = []
    private var emptyLabel: NSTextField?
    var palette: ShellPalette { model.palette_ }

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(toggle)
        toggle.action = { [weak model] in model?.toggleSidebar() }
        toggle.toolTipText = L("Hide sidebar")
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = false
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        addSubview(searchButton)
        searchButton.action = { [weak model] in model?.perform(.search) }
        switcher.sidebar = self
        addSubview(switcher)
    }
    required init?(coder: NSCoder) { fatalError() }

    var panelRect: CGRect { CGRect(x: 8, y: 8, width: max(0, bounds.width - 12), height: max(0, bounds.height - 16)) }

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        p.bg.setFill(); bounds.fill(using: .sourceOver)
        let r = panelRect.insetBy(dx: 0.5, dy: 0.5)
        let path = continuousRoundedPath(r, Metrics.sidebarRadius - 0.5)
        // WebKit's 8-bit layer compositing lands ~0.7 level above CoreGraphics in dark
        // (measured: legacy panel 27 active / 24 inactive; light already matches at 241)
        p.sidebarFloatBg.withAlphaComponent(p.sidebarFloatBg.alphaComponent + (p.mode == .dark ? 0.003 : 0)).setFill(); path.fill()
        p.sidebarFloatBorder.setStroke(); path.lineWidth = 1; path.stroke()
    }

    override func layout() {
        super.layout()
        let inner = panelRect.insetBy(dx: 1, dy: 1)
        toggle.frame = CGRect(x: inner.maxX - 12 - 28, y: inner.minY + (Metrics.chromeRowHeight - 28) / 2, width: 28, height: 28)
        var top = inner.minY + Metrics.chromeRowHeight
        let x = inner.minX + 12, w = inner.width - 24
        if model.values.appearanceSidebarShowSearch {
            searchButton.isHidden = false
            searchButton.frame = CGRect(x: x, y: top + 12, width: w, height: 32)
            top += Metrics.chromeRowHeight
        } else {
            searchButton.isHidden = true
        }
        let bottomRow = inner.maxY - 12 - 32
        switcher.frame = CGRect(x: x, y: bottomRow, width: w, height: 32)
        scroll.frame = CGRect(x: x, y: top, width: w, height: max(0, bottomRow - 12 - top))
        layoutDocument()
    }

    private var placed: [SidebarLayout.Placed] = []

    /// Rebuild row views from the model.
    func reload() {
        let p = palette
        let font = UIFonts.ui(model.values)
        toggle.color = p.fgBase
        toggle.hoverBg = p.surfaceSubtle
        switcher.palette = p
        switcher.font = font
        switcher.label = model.workspaceName
        switcher.needsDisplay = true
        searchButton.palette = p
        searchButton.font = font
        searchButton.needsDisplay = true
        let items = SidebarLayout.items(model: model)
        let (pl, _) = SidebarLayout.place(items)
        placed = pl
        rows.forEach { $0.removeFromSuperview() }
        headers.forEach { $0.removeFromSuperview() }
        emptyLabel?.removeFromSuperview()
        rows = []; headers = []
        let active = model.editor.activeFilePath
        for item in pl {
            switch item.item {
            case let .header(section, collapsed):
                let h = SectionHeaderView(section: section)
                h.collapsed = collapsed
                h.palette = p
                h.font = UIFonts.ui(model.values, size: 12, weight: .medium)
                h.onToggle = { [weak self] in
                    guard let m = self?.model else { return }
                    if m.collapsedSections.contains(section.rawValue) { m.collapsedSections.remove(section.rawValue) } else { m.collapsedSections.insert(section.rawValue) }
                    m.notify(.sidebar)
                }
                headers.append(h)
                document.addSubview(h)
            case let .row(entry, depth, section):
                let r = SidebarRowView(kind: .entry(entry, section))
                r.depth = depth
                r.label = model.label(for: entry)
                r.palette = p
                r.font = font
                r.sidebar = self
                r.isActive = !entry.isDir && entry.path == active
                r.isSelected = section == .tree && model.selectedPaths.contains(entry.path)
                r.isExpanded = entry.isDir && model.isExpanded(entry.path)
                if section == .tree, model.renamingPath == entry.path { attachRenameField(r, entry) }
                rows.append(r)
                document.addSubview(r)
            case let .showMore(section):
                let r = SidebarRowView(kind: .showMore(section))
                r.palette = p
                r.font = font
                r.sidebar = self
                rows.append(r)
                document.addSubview(r)
            case let .empty(text):
                let l = NSTextField(labelWithString: text)
                l.font = font
                l.textColor = p.textMuted
                emptyLabel = l
                document.addSubview(l)
            case .gap: break
            }
        }
        needsLayout = true
        needsDisplay = true
        if let target = model.revealTarget {
            model.revealTarget = nil
            layoutSubtreeIfNeeded()
            if let row = rows.first(where: { $0.entry?.path == target }) { document.scrollToVisible(row.frame) }
        }
        rows.forEach { $0.refreshHover() }
        DispatchQueue.main.async { [weak self] in self?.rows.forEach { $0.refreshHover() } }
    }

    private func layoutDocument() {
        let w = scroll.frame.width
        var hi = 0, ri = 0
        var height: CGFloat = 16
        for item in placed {
            switch item.item {
            case .header:
                guard hi < headers.count else { continue }
                headers[hi].frame = CGRect(x: 0, y: item.y, width: w, height: 20); hi += 1
            case .row, .showMore:
                guard ri < rows.count else { continue }
                rows[ri].frame = CGRect(x: 0, y: item.y, width: w, height: 32)
                if let f = rows[ri].renameField {
                    let x = rows[ri].labelX
                    f.frame = CGRect(x: x, y: 7, width: w - x - 8, height: 18)
                }
                ri += 1
            case .empty:
                emptyLabel?.frame = CGRect(x: 8, y: item.y, width: w - 8, height: 19.5)
            case .gap: break
            }
            height = max(height, item.y + item.height + 8)
        }
        document.frame = CGRect(x: 0, y: 0, width: w, height: max(height, scroll.contentSize.height))
        // Rows are rebuilt on every expand/collapse: a row under the pointer must
        // come up hovered in the same frame (else the folder icon flashes in place
        // of the chevron until the next mouse move).
        rows.forEach { $0.refreshHover() }
    }

    // MARK: rename

    private func attachRenameField(_ row: SidebarRowView, _ entry: DirEntry) {
        let f = RenameField()
        f.stringValue = entry.isDir ? entry.name : LinkPaths.getFileStem(entry.name)
        f.font = UIFonts.ui(model.values)
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        f.delegate = self
        f.entry = entry
        row.renameField = f
        row.addSubview(f)
        DispatchQueue.main.async { [weak f] in
            guard let f = f, let w = f.window else { return }
            w.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
    }

    private var renameCommitted = false

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let f = control as? RenameField, let e = f.entry else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            renameCommitted = true
            model.submitRename(e, f.stringValue)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            renameCommitted = true
            model.renamingPath = nil
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? RenameField, let e = f.entry else { return }
        if renameCommitted { renameCommitted = false; return }
        model.submitRename(e, f.stringValue)
    }

    // MARK: pointer handling (selection + drag-to-move)

    struct DragState { var entries: [DirEntry]; var start: CGPoint; var active: Bool; var dest: String? }
    var dragState: DragState?

    func rowMouseDown(_ row: SidebarRowView, _ event: NSEvent) {
        switch row.kind {
        case .switcher:
            showWorkspaceMenu(from: row)
        case .showMore:
            break
        case let .entry(e, section):
            guard section == .tree else { return }
            let mods = event.modifierFlags
            let m: ShellModel.Modifier = mods.contains(.shift) ? .shift : (mods.contains(.command) || mods.contains(.control) ? .command : .none)
            let dragged = model.pressRow(e, modifier: m)
            if m == .none {
                dragState = DragState(entries: dragged, start: event.locationInWindow, active: false, dest: nil)
            } else {
                dragState = nil
            }
        }
    }

    func rowMouseDragged(_ row: SidebarRowView, _ event: NSEvent) {
        guard var d = dragState else { return }
        let p = event.locationInWindow
        if !d.active {
            let dx = p.x - d.start.x, dy = p.y - d.start.y
            if dx * dx + dy * dy < 16 { return }
            d.active = true
            for r in rows where d.entries.contains(where: { $0.path == r.entry?.path }) { r.isDragging = true }
            NSCursor.closedHand.push()
        }
        // target row under pointer
        let local = document.convert(p, from: nil)
        let target = rows.first { $0.frame.contains(local) && { if case .entry(_, .tree) = $0.kind { return true }; return false }($0) }?.entry
        if let root = model.root { d.dest = TreeMove.resolveDropDir(target, root: root) }
        // auto-scroll within 28px of the edges
        let inScroll = scroll.convert(p, from: nil)
        if inScroll.y < 28 { document.scroll(CGPoint(x: 0, y: max(0, scroll.documentVisibleRect.minY - 8))) }
        else if inScroll.y > scroll.frame.height - 28 { document.scroll(CGPoint(x: 0, y: scroll.documentVisibleRect.minY + 8)) }
        dragState = d
    }

    func rowMouseUp(_ row: SidebarRowView, _ event: NSEvent) {
        defer { dragState = nil }
        if let d = dragState, d.active {
            NSCursor.pop()
            rows.forEach { $0.isDragging = false }
            if let dest = d.dest {
                var failures: [String] = []
                for e in d.entries where TreeMove.canMoveInto(e.path, isDir: e.isDir, destDir: dest) {
                    switch model.moveEntry(e, into: dest) {
                    case let .exists(p): failures.append(L("\"%@\" already exists.", LinkPaths.getFileName(p)))
                    case let .failed(msg): failures.append(msg)
                    default: break
                    }
                }
                model.selectedPaths = []
                if !failures.isEmpty { model.alert(L("Failed to move:") + "\n" + failures.joined(separator: "\n")) }
            }
            return
        }
        guard row.bounds.contains(row.convert(event.locationInWindow, from: nil)) else { return }
        switch row.kind {
        case let .showMore(section):
            if section == .pinned { model.pinnedVisibleCount += 6 } else { model.recentVisibleCount += 4 }
            model.notify(.sidebar)
        case let .entry(e, section):
            if section == .tree {
                let mods = event.modifierFlags
                if mods.contains(.shift) || mods.contains(.command) || mods.contains(.control) { return }
                model.clickTreeRow(e)
            } else {
                // Pinned/Recents: navigate in place (openFile).
                Task { await model.editor.openFile(e.path) }
            }
        case .switcher: break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !model.selectedPaths.isEmpty { model.selectedPaths = []; return }
        super.keyDown(with: event)
    }

    // MARK: menus

    func contextMenu(for row: SidebarRowView) -> NSMenu? {
        guard case let .entry(e, section) = row.kind else { return nil }
        if section == .tree, model.selectedPaths.count >= 2, model.selectedPaths.contains(e.path) {
            return ShellMenus.bulkMenu(model: model, paths: model.flatTree().map { $0.entry.path }.filter { model.selectedPaths.contains($0) })
        }
        if section == .tree { model.selectedPaths = [] }
        return e.isDir ? ShellMenus.folderMenu(model: model, entry: e) : ShellMenus.fileMenu(model: model, entry: e, inlineRename: section == .tree)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ShellMenus.sidebarSurfaceMenu(model: model)
    }

    func showWorkspaceMenu(from row: SidebarRowView) {
        let menu = ShellMenus.workspaceMenu(model: model)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: row)
    }

    // MARK: dump

    func dump() -> [String: Any] {
        var out: [String: Any] = [:]
        out["sidebarPanel"] = convertToRoot(panelRect).dumpArray
        out["sidebarToggle"] = toggle.frameInRoot().dumpArray
        out["workspaceSwitcher"] = ["rect": switcher.frameInRoot().dumpArray, "label": switcher.label]
        out["sections"] = headers.map { ["label": $0.section.rawValue, "rect": $0.frameInRoot().dumpArray] }
        let visible = scroll.convert(scroll.bounds, to: nil)
        out["rows"] = rows.compactMap { r -> [String: Any]? in
            let f = r.frameInRoot()
            let win = r.convert(r.bounds, to: nil)
            guard win.intersects(visible) else { return nil }
            var label = r.label
            var dir = false
            if case let .entry(e, _) = r.kind { dir = e.isDir } else if case .showMore = r.kind { label = "Show More" }
            return ["label": label, "rect": f.dumpArray, "labelX": (Double(f.minX + r.labelX) * 100).rounded() / 100,
                    "active": r.isActive, "dir": dir, "path": r.entry?.path ?? ""]
        }
        return out
    }

    private func convertToRoot(_ r: CGRect) -> CGRect {
        guard let root = window?.contentView else { return r }
        let c = convert(r, to: root)
        return root.isFlipped ? c : CGRect(x: c.minX, y: root.bounds.height - c.maxY, width: c.width, height: c.height)
    }
}

final class RenameField: NSTextField {
    var entry: DirEntry?
}

/// Optional sidebar "Search" field-button (`appearance.sidebar-show-search`).
final class SearchFieldButton: FlippedView {
    var palette: ShellPalette?
    var font: NSFont = .systemFont(ofSize: 13)
    var action: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { action?() }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let p = palette else { return }
        p.surfaceInput.setFill(); roundedPath(bounds, 8).fill()
        let c = hovering ? p.fgBase : p.textMuted
        Icon.search.draw(in: CGRect(x: 10, y: 8, width: 16, height: 16), color: c, ctx: ctx)
        TextStyle(font: font, color: c).draw(L("Search"), x: 34, lineTop: 6.25, lineHeight: 19.5, in: ctx)
    }
}

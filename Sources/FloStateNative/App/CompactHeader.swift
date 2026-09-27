import AppKit
import FloCore

/// Compact (standalone file) window chrome (`compact-file-layout.tsx`):
/// back/forward beside the traffic lights and a centred file-picker trigger
/// listing global recent files. The web's morphing card animation is replaced
/// by a native menu.
@MainActor
final class CompactHeaderView: FlippedView {
    let model: ShellModel   // strong: AppKit can still lay a view out after its window controller (the other owner) is gone
    private var hover: Int? { didSet { needsDisplay = true } }
    var openFile: (String) -> Void = { _ in }

    init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        guard let p = model.editor.activeFilePath else { return L("Choose file") }
        let t = model.editor.file(p)?.title ?? ""
        return t.isEmpty ? LinkPaths.getFileName(p) : t
    }

    var font: NSFont { UIFonts.ui(model.values) }

    /// 0 = back, 1 = forward (28×32 at x 92/120, y 12), 2 = picker trigger (centred, ≤240).
    func rects() -> [CGRect] {
        let tw = min(240, TextStyle(font: font, color: .black).width(title) + 24 + 6 + 12)
        return [CGRect(x: 92, y: 12, width: 28, height: 32), CGRect(x: 122, y: 12, width: 28, height: 32),
                CGRect(x: (bounds.width - tw) / 2, y: 12, width: tw, height: 32)]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = model.palette_
        let r = rects()
        for (i, glyph) in ["←", "→"].enumerated() {
            let enabled = i == 0 ? model.editor.canNavigateBack : model.editor.canNavigateForward
            if enabled && hover == i { p.surfaceSubtle.setFill(); roundedPath(r[i], 8).fill() }
            ctx.saveGState()
            if !enabled { ctx.setAlpha(0.3) }
            let s = TextStyle(font: UIFonts.ui(model.values, size: 16), color: enabled && hover == i ? p.textSecondary : p.textIconMuted)
            s.draw(glyph, x: r[i].midX - s.width(glyph) / 2, lineTop: r[i].minY + 4, lineHeight: 24, in: ctx)
            ctx.restoreGState()
        }
        let t = r[2]
        if hover == 2 { p.surfaceSubtle.setFill(); roundedPath(t, 8).fill() }
        TextStyle(font: font, color: p.fgBase).draw(title, x: t.minX + 12, lineTop: t.minY + (32 - 19.5) / 2, lineHeight: 19.5, maxWidth: t.width - 12 - 12 - 18, in: ctx)
        Icon.sectionChevron.draw(in: CGRect(x: t.maxX - 12 - 12, y: t.midY - 6, width: 12, height: 12), color: p.textIconMuted, ctx: ctx, rotation: .pi / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return rects().contains { $0.contains(p) } ? self : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = rects().firstIndex { $0.contains(p) }
    }
    override func mouseExited(with event: NSEvent) { hover = nil }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rects().firstIndex(where: { $0.contains(p) }) else { return }
        switch i {
        case 0: model.perform(.back)
        case 1: model.perform(.forward)
        default: pickerMenu().popUp(positioning: nil, at: CGPoint(x: rects()[2].minX, y: rects()[2].maxY + 8), in: self)
        }
    }

    /// Recents list (excluding the active file), "Recents" header.
    func pickerMenu() -> NSMenu {
        let items = model.recentFilesStore.list(limit: 30, extensions: model.settings.supportedExtensions)
            .filter { $0.path != model.editor.activeFilePath }
        var menuItems: [NSMenuItem] = [NSMenuItem.sectionHeader(title: L("Recents"))]
        if items.isEmpty {
            let none = NSMenuItem(title: L("No other recent files."), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menuItems.append(none)
        }
        for f in items {
            let label = (f.title?.isEmpty == false ? f.title! : LinkPaths.getFileStem(f.name))
            menuItems.append(ClosureMenuItem(label) { [weak self] in self?.openFile(f.path) })
        }
        return ShellMenus.menu(menuItems)
    }
}

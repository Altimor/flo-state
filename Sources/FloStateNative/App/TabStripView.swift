import AppKit
import FloCore

/// Tab strip geometry (`editor-tabs.tsx`): tabs 32px tall, px-3.5, max 180,
/// gap-1; "+" (36px, ml-1) after the strip.
enum TabGeometry {
    static let height: CGFloat = 32
    static let maxWidth: CGFloat = 180
    static let padding: CGFloat = 14

    static func width(titleWidth: CGFloat, hasError: Bool) -> CGFloat {
        min(maxWidth, titleWidth + padding * 2 + (hasError ? 12 : 0))
    }

    /// x offsets of tabs (from the strip origin) and of the "+" button.
    static func layout(widths: [CGFloat]) -> (tabs: [CGFloat], plus: CGFloat) {
        var x: CGFloat = 0
        var xs: [CGFloat] = []
        for (i, w) in widths.enumerated() {
            xs.append(x)
            x += w + (i < widths.count - 1 ? 4 : 0)
        }
        return (xs, x + 4)
    }
}

final class TabButtonView: FlippedView {
    let tab: Tab
    let model: ShellModel   // strong: AppKit can still lay a view out after its window controller (the other owner) is gone
    var title = ""
    var isActive = false
    var isLoading = false
    var saveError: String?
    var font: NSFont = .systemFont(ofSize: 13)
    private(set) var hovering = false { didSet { needsDisplay = true } }
    private var closeHover = false { didSet { needsDisplay = true } }

    init(tab: Tab, model: ShellModel) { self.tab = tab; self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; closeHover = false }
    override func mouseMoved(with event: NSEvent) { closeHover = closeRect.contains(convert(event.locationInWindow, from: nil)) }

    var closeRect: CGRect { CGRect(x: bounds.width - 4 - 20, y: (bounds.height - 20) / 2, width: 20, height: 20) }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if hovering && closeRect.contains(p) { model.editor.closeTab(tab.id) } else { model.editor.setActiveTab(tab.id) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { ShellMenus.tabMenu(model: model, tab: tab) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = model.palette_
        if isActive || hovering { p.tabActiveBg.setFill(); roundedPath(bounds, 8).fill() }
        var x = TabGeometry.padding
        if saveError != nil {
            NSColor(srgbRed: 1, green: 0x5f / 255.0, blue: 0x57 / 255.0, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
            x += 12
        }
        let color = (isActive || hovering) ? p.textSecondary : p.textMuted
        let lh: CGFloat = 13 * 1.15
        let maxW = bounds.width - x - TabGeometry.padding
        ctx.saveGState()
        if isLoading { ctx.setAlpha(0.6) }
        if hovering {
            // label fades out under the × (mask: black → transparent over the last 32→8px)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            TextStyle(font: font, color: color).draw(title, x: x, lineTop: (bounds.height - lh) / 2, lineHeight: lh, maxWidth: maxW, in: ctx)
            let labelRight = x + maxW
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
                ctx.setBlendMode(.destinationIn)
                ctx.clip(to: CGRect(x: labelRight - 32, y: 0, width: bounds.width, height: bounds.height))
                ctx.drawLinearGradient(g, start: CGPoint(x: labelRight - 32, y: 0), end: CGPoint(x: labelRight - 8, y: 0), options: [.drawsAfterEndLocation])
            }
            ctx.endTransparencyLayer()
        } else {
            TextStyle(font: font, color: color).draw(title, x: x, lineTop: (bounds.height - lh) / 2, lineHeight: lh, maxWidth: maxW, in: ctx)
        }
        ctx.restoreGState()
        if hovering {
            TextStyle(font: font, color: closeHover ? p.textSecondary : p.textIconMuted)
                .draw("×", x: closeRect.midX - TextStyle(font: font, color: .black).width("×") / 2, lineTop: closeRect.minY + (20 - 13) / 2, lineHeight: 13, in: ctx)
        }
    }
}

final class PlusButtonView: FlippedView {
    let model: ShellModel   // strong: AppKit can still lay a view out after its window controller (the other owner) is gone
    private var hovering = false { didSet { needsDisplay = true } }
    init(model: ShellModel) { self.model = model; super.init(frame: .zero); toolTip = L("New tab") }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { model.editor.openNewTab() } }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = model.palette_
        if hovering { p.surfaceSubtle.setFill(); roundedPath(bounds, 8).fill() }
        let s = TextStyle(font: UIFonts.ui(model.values, size: 16), color: hovering ? p.textSecondary : p.textIconMuted)
        s.draw("+", x: (bounds.width - s.width("+")) / 2, lineTop: (bounds.height - 24) / 2, lineHeight: 24, in: ctx)
    }
}

/// The tab bar (horizontal scroll strip + "+").
final class TabStripView: FlippedView {
    let model: ShellModel   // strong: AppKit can still lay a view out after its window controller (the other owner) is gone
    let scroll = NSScrollView()
    let strip = FlippedView()
    let plus: PlusButtonView
    private(set) var buttons: [TabButtonView] = []

    init(model: ShellModel) {
        self.model = model
        plus = PlusButtonView(model: model)
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.documentView = strip
        addSubview(scroll)
        addSubview(plus)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Tabs pass clicks through to the window drag region when empty space is hit.
    override var mouseDownCanMoveWindow: Bool { true }

    func reload() {
        buttons.forEach { $0.removeFromSuperview() }
        let font = UIFonts.ui(model.values)
        buttons = model.editor.tabs.map { tab in
            let b = TabButtonView(tab: tab, model: model)
            b.title = model.editor.tabTitle(tab)
            b.isActive = tab.id == model.editor.activeTabId
            if let path = tab.location.primaryPath, let f = model.editor.file(path) {
                b.isLoading = f.isLoading
                b.saveError = f.saveError
            }
            b.font = font
            strip.addSubview(b)
            return b
        }
        needsLayout = true
        plus.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let style = TextStyle(font: UIFonts.ui(model.values), color: .black)
        let widths = buttons.map { TabGeometry.width(titleWidth: style.width($0.title), hasError: $0.saveError != nil) }
        let (xs, plusX) = TabGeometry.layout(widths: widths)
        let stripW = widths.isEmpty ? 0 : plusX - 4
        let avail = max(0, bounds.width - 40)
        let visibleW = min(stripW, avail)
        scroll.frame = CGRect(x: 0, y: 12, width: visibleW, height: 32)
        scroll.suppressScrollPocket()
        strip.frame = CGRect(x: 0, y: 0, width: stripW, height: 32)
        for (i, b) in buttons.enumerated() { b.frame = CGRect(x: xs[i], y: 0, width: widths[i], height: 32) }
        plus.frame = CGRect(x: (widths.isEmpty ? 0 : visibleW + 4), y: 12, width: 36, height: 32)
        // keep the active tab in view
        if let a = buttons.first(where: { $0.isActive }) { strip.scrollToVisible(a.frame) }
    }

    func dump() -> [[String: Any]] {
        buttons.map { ["title": $0.title, "rect": $0.frameInRoot().dumpArray, "active": $0.isActive] }
    }
}

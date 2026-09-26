import AppKit
import FloCore

/// Palette geometry (App.css `[cmdk-*]`).
enum PaletteGeometry {
    static let inputHeight: CGFloat = 48.5
    static let listPadding: CGFloat = 6
    static let headingHeight: CGFloat = 28.5
    static let maxListHeight: CGFloat = 320

    static func dialogRect(window: CGSize) -> CGRect {
        let w = min(560, window.width * 0.9)
        return CGRect(x: (window.width - w) / 2, y: window.height * 0.16, width: w, height: 0)
    }

    static func itemHeight(_ item: PaletteItem) -> CGFloat { item.subtitle == nil ? 39.5 : 59 }

    /// Item y offsets inside the list content (before scrolling) + content height.
    static func layout(_ view: ShellModel.PaletteView) -> (heading: CGFloat?, items: [CGFloat], empty: CGFloat?, content: CGFloat) {
        var y = listPadding
        var heading: CGFloat?, empty: CGFloat?
        if view.empty != nil { empty = y; y += 35.5 }
        if view.heading != nil { heading = y; y += headingHeight }
        var ys: [CGFloat] = []
        for it in view.items { ys.append(y); y += itemHeight(it) }
        return (heading, ys, empty, y + listPadding)
    }
}

final class PaletteInputField: NSTextField {
    var onKey: ((Selector) -> Bool)?
}

/// Full-window overlay: click outside closes; the card holds input + list.
final class PaletteOverlayView: FlippedView, NSTextFieldDelegate {
    unowned let model: ShellModel
    let card = PaletteCardView()
    let shadowView = PaletteShadowView()
    /// Live blur behind the card (CSS backdrop-filter: blur(16px)).
    let backdrop = NSVisualEffectView()
    let input = PaletteInputField()
    let scroll = NSScrollView()
    let list = PaletteListView()

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true
        backdrop.isHidden = ShellSnapshot.active
        addSubview(shadowView)
        addSubview(backdrop)
        addSubview(card)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.cell?.usesSingleLineMode = true
        input.cell?.lineBreakMode = .byTruncatingTail
        card.addSubview(input)
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = false
        scroll.documentView = list
        card.addSubview(scroll)
        list.overlay = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { model.palette = nil }
    }

    var view: ShellModel.PaletteView? { model.paletteView() }

    func reload(resetField: Bool) {
        guard let v = view, let p = model.palette else { return }
        let pal = model.palette_
        card.palette = pal
        let font = UIFonts.ui(model.values)
        input.font = font
        input.textColor = pal.textSecondary
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: pal.textMuted, .kern: -0.26]
        input.placeholderAttributedString = NSAttributedString(string: v.placeholder, attributes: attrs)
        if resetField || (input.currentEditor() == nil && input.stringValue != p.query) { input.stringValue = p.query }
        list.palette = pal
        list.font = font
        list.data = v
        list.selected = p.selected
        needsLayout = true
        list.needsDisplay = true
        card.needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let v = view else { return }
        let base = PaletteGeometry.dialogRect(window: bounds.size)
        let l = PaletteGeometry.layout(v)
        let listH = min(PaletteGeometry.maxListHeight, l.content)
        card.frame = CGRect(x: base.minX, y: base.minY, width: base.width, height: 1 + PaletteGeometry.inputHeight + listH + 1)
        backdrop.frame = card.frame
        shadowView.frame = card.frame
        input.frame = CGRect(x: 1 + 16, y: 1 + 14 + 0.25, width: base.width - 2 - 32, height: 20)
        scroll.frame = CGRect(x: 1, y: 1 + PaletteGeometry.inputHeight, width: base.width - 2, height: listH)
        list.frame = CGRect(x: 0, y: 0, width: base.width - 2, height: l.content)
        list.layoutInfo = l
        if let sel = list.selected, sel < l.items.count {
            let y = l.items[sel], h = PaletteGeometry.itemHeight(v.items[sel])
            let vis = scroll.documentVisibleRect
            if y < vis.minY || y + h > vis.maxY { list.scroll(CGPoint(x: 0, y: y + h > vis.maxY ? y + h - vis.height + 6 : max(0, y - 6))) }
        }
    }

    func focus() {
        window?.makeFirstResponder(input)
        input.currentEditor()?.selectedRange = NSRange(location: (input.stringValue as NSString).length, length: 0)
    }

    func controlTextDidChange(_ obj: Notification) {
        model.setPaletteQuery(input.stringValue)
        list.scroll(.zero)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): model.movePaletteSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): model.movePaletteSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): model.runSelectedPaletteItem(); return true
        case #selector(NSResponder.cancelOperation(_:)): model.palette = nil; return true
        default: return false
        }
    }

    func dump() -> [String: Any]? {
        guard let v = view, let p = model.palette else { return nil }
        let l = PaletteGeometry.layout(v)
        var out: [String: Any] = [
            "rect": card.frameInRoot().dumpArray,
            "input": card.convertToRootRect(CGRect(x: 1, y: 1, width: card.bounds.width - 2, height: PaletteGeometry.inputHeight)).dumpArray,
            "placeholder": v.placeholder,
            "heading": v.heading as Any? ?? NSNull(),
            "empty": v.empty as Any? ?? NSNull(),
        ]
        out["items"] = v.items.enumerated().map { i, it -> [String: Any] in
            let r = list.convertToRootRect(CGRect(x: 6, y: l.items[i], width: list.bounds.width - 12, height: PaletteGeometry.itemHeight(it)))
            return ["text": it.title + (it.subtitle ?? ""), "rect": r.dumpArray, "selected": i == p.selected]
        }
        return out
    }
}

final class PaletteCardView: FlippedView {
    var palette: ShellPalette?
    override func draw(_ dirtyRect: NSRect) {
        guard let p = palette else { return }
        let path = roundedPath(bounds, 16)
        p.surfaceCard.setFill(); path.fill()
        p.cardUnderlay.setFill(); path.fill()
        p.lineSubtler.setFill()
        CGRect(x: 1, y: 1 + PaletteGeometry.inputHeight - 1, width: bounds.width - 2, height: 1).fill()
        let border = roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5), 15.5)
        border.lineWidth = 1
        p.lineSubtler.setStroke(); border.stroke()
    }
    override func viewDidMoveToSuperview() {
        // The blur is the (clipped) NSVisualEffectView behind the card and the
        // shadow a separate view below it: a backdrop filter on an unclipped
        // layer spreads blur over the whole editor.
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }
    override var wantsUpdateLayer: Bool { false }
}

/// `box-shadow: 0 15px 35px rgba(0,0,0,.15)` under the palette card.
final class PaletteShadowView: FlippedView {
    override func viewDidMoveToSuperview() {
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 17.5
        layer?.shadowOffset = CGSize(width: 0, height: -15)
        layer?.masksToBounds = false
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PaletteListView: FlippedView {
    weak var overlay: PaletteOverlayView?
    var palette: ShellPalette?
    var font: NSFont = .systemFont(ofSize: 13)
    var data: ShellModel.PaletteView?
    var selected: Int?
    var layoutInfo: (heading: CGFloat?, items: [CGFloat], empty: CGFloat?, content: CGFloat)?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let p = palette, let v = data, let l = layoutInfo else { return }
        if let e = v.empty, let y = l.empty {
            TextStyle(font: font, color: p.textMuted).draw(e, x: 6 + 12, lineTop: y + 8, lineHeight: 19.5, in: ctx)
        }
        if let h = v.heading, let y = l.heading {
            TextStyle(font: NSFont(descriptor: font.fontDescriptor, size: 11) ?? font, color: p.textMuted)
                .draw(h, x: 6 + 10, lineTop: y + 6, lineHeight: 16.5, in: ctx)
        }
        let kern: CGFloat = -0.26
        for (i, it) in v.items.enumerated() {
            let r = CGRect(x: 6, y: l.items[i], width: bounds.width - 12, height: PaletteGeometry.itemHeight(it))
            if i == selected { p.surfaceSubtle.setFill(); roundedPath(r, 10).fill() }
            let maxW = r.width - 24
            TextStyle(font: font, color: p.textSecondary, kern: kern).draw(it.title, x: r.minX + 12, lineTop: r.minY + 10, lineHeight: 19.5, maxWidth: maxW, in: ctx)
            if let sub = it.subtitle {
                let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                let hl = it.highlights.map { (NSRange(location: $0, length: 1), p.accent, NSFont.systemFont(ofSize: 13, weight: .semibold) as NSFont) }
                _ = bold
                TextStyle(font: font, color: p.textMuted, kern: kern).draw(sub, x: r.minX + 12, lineTop: r.minY + 29.5, lineHeight: 19.5, maxWidth: maxW, in: ctx, highlights: hl)
            }
        }
    }

    private func index(at p: CGPoint) -> Int? {
        guard let v = data, let l = layoutInfo else { return nil }
        return v.items.indices.first { p.y >= l.items[$0] && p.y < l.items[$0] + PaletteGeometry.itemHeight(v.items[$0]) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard let o = overlay, let i = index(at: convert(event.locationInWindow, from: nil)), var st = o.model.palette, st.selected != i else { return }
        st.selected = i
        o.model.palette = st
    }
    override func mouseUp(with event: NSEvent) {
        guard let o = overlay, let v = data, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        o.model.runPaletteItem(v.items[i])
    }
}

import AppKit
import FloCore

/// Resizing rendered images. Hover an image: a corner handle appears; drag it to
/// preview a new width, release to write `|N` into the alt text (`![alt|420](src)`,
/// the width syntax the renderer already reads). Right-click offers preset sizes.
/// Everything goes through a normal transaction, so it's undoable and stays plain markdown.

/// Where an image was last drawn (text-view coordinates) and its source range.
struct ImageHit: Equatable {
    var rect: CGRect
    var from: Int
    var to: Int
}

extension EditorController {
    /// Called by the layout fragment each time it draws an image widget.
    /// `rect` is in text-container coordinates.
    func noteImageDrawn(_ rect: CGRect, widget: Widget) {
        let o = textView.textContainerOrigin
        imageRects[widget.from] = ImageHit(rect: rect.offsetBy(dx: o.x, dy: o.y), from: widget.from, to: widget.to)
    }

    /// The `![alt](src)` source of an image widget. With the caret on the image's line the
    /// widget is a zero-length marker right after the source (the markdown stays visible),
    /// so look back on that line for the `![` that ends there.
    func imageSourceRange(from: Int, to: Int) -> (Int, Int)? {
        if to > from { return (from, to) }
        guard from > 0, from <= state.doc.length else { return nil }
        let line = state.doc.lineAt(from)
        let before = state.doc.slice(line.from, from) as NSString
        guard before.hasSuffix(")") else { return nil }
        let start = before.range(of: "![", options: .backwards)
        guard start.location != NSNotFound else { return nil }
        return (line.from + start.location, from)
    }

    /// The image under a view point, if its widget is still in the current plan.
    func image(at point: NSPoint, slop: CGFloat = 0) -> ImageHit? {
        guard let plan = currentPlan else { return nil }
        for hit in imageRects.values where hit.rect.insetBy(dx: -slop, dy: -slop).contains(point) {
            let live = plan.widgets.contains { w in
                if case .image = w.kind { return w.from == hit.from && w.to == hit.to }
                return false
            }
            if live { return hit }
        }
        return nil
    }

    /// `|N` at the end of the alt text (same pattern as the planner's).
    static let altWidthRE = try! NSRegularExpression(pattern: #"\|\s*(\d{1,5})\s*$"#)

    /// Largest width an image can take in the column.
    var imageMaxWidth: CGFloat { max(40, applier.columnWidth - 6) }

    /// Rewrite the image's alt text with `|width` (nil = remove it: natural size).
    public func setImageWidth(from widgetFrom: Int, to widgetTo: Int, width: Int?) {
        guard let (from, to) = imageSourceRange(from: widgetFrom, to: widgetTo), from >= 0, to <= state.doc.length, to > from else { return }
        let source = state.doc.slice(from, to) as NSString
        guard source.hasPrefix("![") else { return }
        let close = source.range(of: "](")
        guard close.location != NSNotFound else { return }
        var alt = source.substring(with: NSRange(location: 2, length: close.location - 2))
        let ns = alt as NSString
        if let m = EditorController.altWidthRE.firstMatch(in: alt, range: NSRange(location: 0, length: ns.length)) {
            alt = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
        }
        let newAlt = width.map { "\(alt)|\($0)" } ?? alt
        let altFrom = from + 2, altTo = from + close.location
        run { t in
            t.dispatch(TransactionSpec(changes: [Change(from: altFrom, to: altTo, insert: newAlt)], userEvent: "input.resize-image", scrollIntoView: false))
            return true
        }
    }

    /// Right-click presets, as fractions of the column width.
    func imageSizeMenuItems(for hit: ImageHit) -> [NSMenuItem] {
        let maxW = imageMaxWidth
        let presets: [(String, Int?)] = [("Small", Int((maxW * 0.25).rounded())), ("Medium", Int((maxW * 0.5).rounded())),
                                         ("Large", Int((maxW * 0.75).rounded())), ("Full Width", Int(maxW.rounded())), ("Original Size", nil)]
        return presets.map { title, w in
            ImageMenuItem(title: "Image Size: \(title)") { [weak self] in self?.setImageWidth(from: hit.from, to: hit.to, width: w) }
        }
    }
}

final class ImageMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Hover chrome over an image: a thin outline and a corner handle. Only the handle
/// takes clicks; everything else falls through to the text view.
final class ImageResizeOverlay: NSView {
    weak var controller: EditorController?
    private(set) var hit: ImageHit?
    private var previewWidth: CGFloat?
    static let handle: CGFloat = 12
    override var isFlipped: Bool { true }

    func show(_ h: ImageHit?) {
        guard previewWidth == nil else { return }   // dragging: keep the current image
        hit = h
        isHidden = h == nil
        if let h = h {
            frame = h.rect.insetBy(dx: -Self.handle, dy: -Self.handle)
            base = CGRect(x: Self.handle, y: Self.handle, width: h.rect.width, height: h.rect.height)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The image, in overlay coordinates (stays put while the overlay grows during a drag).
    private var base: CGRect = .zero
    private var imageRect: CGRect { base }
    private var handleRect: CGRect {
        let r = imageRect, w = previewWidth ?? r.width, s = Self.handle
        return CGRect(x: r.minX + w - s / 2 - 2, y: r.minY + r.height * (w / max(1, r.width)) - s / 2 - 2, width: s, height: s)
    }

    /// Whether a text-view point is on the handle (the text view keeps the resize cursor there).
    func handleContains(_ textViewPoint: NSPoint) -> Bool {
        guard !isHidden else { return false }
        return handleRect.insetBy(dx: -4, dy: -4).contains(convert(textViewPoint, from: superview))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        return handleRect.insetBy(dx: -4, dy: -4).contains(p) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(handleRect.insetBy(dx: -4, dy: -4), cursor: NSCursor.resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hit != nil else { return }
        let r = imageRect
        let w = previewWidth ?? r.width
        let shown = CGRect(x: r.minX, y: r.minY, width: w, height: r.height * (w / max(1, r.width)))
        let accent = controller?.theme.accent ?? .controlAccentColor
        let outline = NSBezierPath(rect: shown.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        if previewWidth != nil { outline.setLineDash([4, 3], count: 2, phase: 0) }
        accent.withAlphaComponent(previewWidth != nil ? 0.9 : 0.55).setStroke()
        outline.stroke()
        let h = NSBezierPath(roundedRect: handleRect, xRadius: 3, yRadius: 3)
        NSColor.white.setFill(); h.fill()
        accent.setStroke(); h.lineWidth = 1.5; h.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let h = hit, let c = controller, let w = window else { return }
        let startX = event.locationInWindow.x, startW = h.rect.width
        let maxW = c.imageMaxWidth
        previewWidth = startW
        // widen the overlay so the preview can grow up to the column width
        frame = CGRect(x: frame.minX, y: frame.minY, width: maxW + 2 * Self.handle + 8,
                       height: h.rect.height * (maxW / max(1, startW)) + 2 * Self.handle + 8)
        w.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { e, stop in
            guard let e = e else { stop.pointee = true; return }
            previewWidth = min(maxW, max(40, startW + e.locationInWindow.x - startX))
            needsDisplay = true
            if e.type == .leftMouseUp { stop.pointee = true }
        }
        let final = previewWidth ?? startW
        previewWidth = nil
        if abs(final - startW) >= 2 {
            c.setImageWidth(from: h.from, to: h.to, width: Int(final.rounded()))
        }
        show(nil)
    }
}

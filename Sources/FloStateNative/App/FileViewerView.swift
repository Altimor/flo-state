import AppKit
import FloCore
import PDFKit

/// A tab for a file that isn't a note: PDFs in PDFKit's viewer (scroll, zoom, search, select text) with a
/// small floating toolbar (zoom out / % / zoom in, fit width, page n / N with previous / next), and
/// images fitted to the pane, pinch/⌘-scroll zoomable. ⌘+ / ⌘− / ⌘0 (View menu) zoom the PDF when its tab
/// is active (ShellModel routes them here). Read-only: nothing here writes the file.
@MainActor
final class FileViewerView: NSView {
    let path: String
    let kind: WorkspaceFS.ViewerKind
    private(set) var pdfView: PDFView?
    private var imageScroll: NSScrollView?
    private(set) var imageView: NSImageView?
    private var fitted = false
    private(set) var toolbar: PDFToolbar?

    init(path: String, kind: WorkspaceFS.ViewerKind, background: NSColor, palette: ShellPalette? = nil, font: NSFont? = nil) {
        self.path = path
        self.kind = kind
        super.init(frame: .zero)
        let url = URL(fileURLWithPath: path)
        switch kind {
        case .pdf:
            let v = PDFView()
            v.displayMode = .singlePageContinuous
            v.displaysPageBreaks = true
            v.backgroundColor = background
            v.document = PDFDocument(url: url)
            addSubview(v)
            pdfView = v
            let bar = PDFToolbar(palette: palette, font: font ?? .systemFont(ofSize: 12))
            bar.onZoomOut = { [weak self] in self?.zoom(-1) }
            bar.onZoomIn = { [weak self] in self?.zoom(1) }
            bar.onFit = { [weak self] in self?.toggleFit() }
            bar.onPrevious = { [weak self] in self?.pdfView?.goToPreviousPage(nil) }
            bar.onNext = { [weak self] in self?.pdfView?.goToNextPage(nil) }
            addSubview(bar)
            toolbar = bar
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewDocumentChanged] {
                NotificationCenter.default.addObserver(forName: name, object: v, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateToolbar() }
                }
            }
        case .image:
            let s = NSScrollView()
            s.drawsBackground = false
            s.hasVerticalScroller = true
            s.hasHorizontalScroller = true
            s.autohidesScrollers = true
            s.allowsMagnification = true
            s.minMagnification = 0.05
            s.maxMagnification = 16
            s.contentView = CenteringClipView()
            let iv = NSImageView()
            iv.imageScaling = .scaleAxesIndependently
            iv.animates = true
            if let img = NSImage(contentsOf: url) {
                iv.image = img
                iv.frame = CGRect(origin: .zero, size: Self.pixelSize(url) ?? img.size)
            }
            s.documentView = iv
            addSubview(s)
            imageScroll = s
            imageView = iv
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Bitmap images at their pixel size (a 2x screenshot shows 1:1, like the editor's image widgets).
    private static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    override func layout() {
        super.layout()
        if let v = pdfView {
            v.frame = bounds
            // first fit: page width fills the pane up to a readable 900pt, centred (autoScales blows a portrait
            // page up to the full width of a wide pane); after that the user's zoom sticks
            if !fitted, bounds.width > 0, let page = v.document?.page(at: 0) {
                fitted = true
                if let f = fitScale() {
                    v.autoScales = false
                    v.scaleFactor = f
                    v.go(to: page)
                }
            }
            if let bar = toolbar {
                let size = bar.fittingSize
                bar.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - size.height - 14,
                                   width: size.width, height: size.height)
                updateToolbar()
            }
            return
        }
        guard let s = imageScroll, let iv = imageView else { return }
        s.frame = bounds
        // fit once (never upscale past 100%); after that the user's zoom sticks
        if !fitted, bounds.width > 0, iv.frame.width > 0 {
            fitted = true
            let fit = min(1, (bounds.width - 32) / iv.frame.width, (bounds.height - 32) / iv.frame.height)
            s.magnification = max(s.minMagnification, fit)
        }
    }
}

extension FileViewerView {
    /// Fit width: the page width fills the pane, up to a readable 900pt.
    func fitScale() -> CGFloat? {
        guard let v = pdfView, let page = v.currentPage ?? v.document?.page(at: 0), bounds.width > 0 else { return nil }
        let w = page.bounds(for: v.displayBox).width
        guard w > 0 else { return nil }
        return max(v.minScaleFactor, min((bounds.width - 48) / w, 900 / w))
    }

    /// ⌘+ (1) / ⌘− (-1) / ⌘0 (0: actual size), and the toolbar's − / +.
    func zoom(_ step: Int) {
        guard let v = pdfView else { return }
        v.autoScales = false
        switch step {
        case 0: v.scaleFactor = 1
        case let s where s > 0: if v.canZoomIn { v.zoomIn(nil) }
        default: if v.canZoomOut { v.zoomOut(nil) }
        }
        updateToolbar()
    }

    /// The fit button: fit width, or actual size when already fitted.
    func toggleFit() {
        guard let v = pdfView, let f = fitScale() else { return }
        v.autoScales = false
        v.scaleFactor = abs(v.scaleFactor - f) < 0.01 ? 1 : f
        updateToolbar()
    }

    func updateToolbar() {
        guard let v = pdfView, let bar = toolbar else { return }
        let count = v.document?.pageCount ?? 0
        let index = v.currentPage.flatMap { v.document?.index(for: $0) } ?? 0
        let fitted = fitScale().map { abs(v.scaleFactor - $0) < 0.01 } ?? false
        bar.update(zoom: Int((v.scaleFactor * 100).rounded()), page: count == 0 ? 0 : index + 1, of: count,
                   fitted: fitted, canPrevious: v.canGoToPreviousPage, canNext: v.canGoToNextPage)
    }
}

/// The PDF tab's floating toolbar: − 100% + | Fit | ‹ 3 / 12 ›.
@MainActor
final class PDFToolbar: NSView {
    var onZoomOut: (() -> Void)?, onZoomIn: (() -> Void)?, onFit: (() -> Void)?, onPrevious: (() -> Void)?, onNext: (() -> Void)?
    private let palette: ShellPalette?
    private let font: NSFont
    private let stack = NSStackView()
    private(set) var zoomLabel: NSButton!
    private(set) var pageLabel: NSTextField!
    private(set) var fitButton: NSButton!
    private var previous: NSButton!, next: NSButton!

    init(palette: ShellPalette?, font: NSFont) {
        self.palette = palette
        self.font = font
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let out = button("−", L("Zoom Out")) { [weak self] in self?.onZoomOut?() }
        zoomLabel = button("100%", L("Fit Width")) { [weak self] in self?.onFit?() }
        zoomLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let inn = button("+", L("Zoom In")) { [weak self] in self?.onZoomIn?() }
        fitButton = button(L("Fit"), L("Fit Width")) { [weak self] in self?.onFit?() }
        previous = button("‹", L("Previous Page")) { [weak self] in self?.onPrevious?() }
        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = font.withSize(12)
        pageLabel.alignment = .center
        pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        next = button("›", L("Next Page")) { [weak self] in self?.onNext?() }
        for v in [out, zoomLabel!, inn, separator(), fitButton!, separator(), previous!, pageLabel!, next!] as [NSView] { stack.addArrangedSubview(v) }
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private final class Target: NSObject {
        let run: () -> Void
        init(_ r: @escaping () -> Void) { run = r }
        @objc func fire() { run() }
    }
    private var targets: [Target] = []

    private func button(_ title: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let t = Target(action)
        targets.append(t)
        let b = NSButton(title: title, target: t, action: #selector(Target.fire))
        b.isBordered = false
        b.font = font.withSize(title.count == 1 ? 15 : 12)
        b.toolTip = tip
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        return b
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    private func applyColors() {
        let bg = palette?.surfaceCard ?? NSColor.windowBackgroundColor
        layer?.backgroundColor = bg.withAlphaComponent(0.92).cgColor
        layer?.borderColor = (palette?.lineSubtler ?? .separatorColor).cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        let fg = palette?.fgBase ?? .labelColor
        for case let b as NSButton in stack.arrangedSubviews {
            b.contentTintColor = fg
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [.font: b.font ?? font, .foregroundColor: fg])
        }
        pageLabel.textColor = palette?.textMuted ?? .secondaryLabelColor
    }

    func update(zoom: Int, page: Int, of count: Int, fitted: Bool, canPrevious: Bool, canNext: Bool) {
        let fg = palette?.fgBase ?? .labelColor
        func title(_ b: NSButton, _ s: String) {
            b.title = s
            b.attributedTitle = NSAttributedString(string: s, attributes: [.font: b.font ?? font, .foregroundColor: fg])
        }
        title(zoomLabel, "\(zoom)%")
        title(fitButton, fitted ? L("Actual Size") : L("Fit"))
        fitButton.toolTip = fitted ? L("Actual Size") : L("Fit Width")
        pageLabel.stringValue = count == 0 ? "" : "\(page) / \(count)"
        previous.isEnabled = canPrevious
        next.isEnabled = canNext
        previous.alphaValue = canPrevious ? 1 : 0.35
        next.alphaValue = canNext ? 1 : 0.35
    }
}

/// Keeps a smaller-than-viewport document centred instead of pinned to the top-left.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

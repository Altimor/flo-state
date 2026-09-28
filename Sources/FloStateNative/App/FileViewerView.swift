import AppKit
import FloCore
import PDFKit

/// A tab for a file that isn't a note: PDFs in PDFKit's viewer (scroll, zoom, search, select text) and
/// images fitted to the pane, pinch/⌘-scroll zoomable. Read-only: nothing here writes the file.
@MainActor
final class FileViewerView: NSView {
    let path: String
    let kind: WorkspaceFS.ViewerKind
    private(set) var pdfView: PDFView?
    private var imageScroll: NSScrollView?
    private(set) var imageView: NSImageView?
    private var fitted = false

    init(path: String, kind: WorkspaceFS.ViewerKind, background: NSColor) {
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
                let w = page.bounds(for: v.displayBox).width
                if w > 0 {
                    v.autoScales = false
                    v.scaleFactor = max(v.minScaleFactor, min((bounds.width - 48) / w, 900 / w))
                    v.go(to: page)
                }
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

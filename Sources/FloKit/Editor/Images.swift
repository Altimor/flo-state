import AppKit
import FloCore
import ImageIO

/// A resolved image: CSS treats bitmap pixels as CSS px, so sizes are in
/// pixels (not NSImage points, which follow DPI metadata).
final class LoadedImage {
    let url: URL
    let pixelSize: CGSize
    /// Set for PDFs: drawn as a one-page card (first page + page count + Quick Look).
    let pdfPageCount: Int?
    private var _image: NSImage?
    init(url: URL, pixelSize: CGSize, pdfPageCount: Int? = nil) { self.url = url; self.pixelSize = pixelSize; self.pdfPageCount = pdfPageCount }
    var isPDF: Bool { pdfPageCount != nil }
    var image: NSImage? {
        if _image == nil { _image = NSImage(contentsOf: url) }
        return _image
    }
}

/// Resolves markdown image sources and `![[embeds]]` against the open note,
/// with a per-path cache (fold/image.ts + image-src-resolver.ts +
/// wiki-link-extension.ts resolveEmbed).
final class ImageStore {
    var documentPath: String?
    var workspaceRoot: String?
    private var cache: [String: LoadedImage?] = [:]

    func invalidate() { cache.removeAll() }

    func load(absolutePath: String) -> LoadedImage? {
        if let hit = cache[absolutePath] { return hit }
        var result: LoadedImage? = nil
        let url = URL(fileURLWithPath: absolutePath)
        if url.pathExtension.lowercased() == "pdf" {
            // first page, sized in points (= CSS px); NSImage draws that page as vectors
            if let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0, let page = doc.page(at: 1) {
                var box = page.getBoxRect(.cropBox)
                if page.rotationAngle % 180 != 0 { box.size = CGSize(width: box.height, height: box.width) }
                if box.width > 0, box.height > 0 {
                    result = LoadedImage(url: url, pixelSize: box.size, pdfPageCount: doc.numberOfPages)
                }
            }
            cache[absolutePath] = result
            return result
        }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            // EXIF orientations 5-8 swap the axes (browsers honour image-orientation)
            if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
            result = LoadedImage(url: url, pixelSize: CGSize(width: w, height: h))
        } else if let img = NSImage(contentsOf: url), img.size.width > 0 {
            // SVG and friends: intrinsic size in CSS px = points
            result = LoadedImage(url: url, pixelSize: img.size)
        }
        cache[absolutePath] = result
        return result
    }

    /// `![alt](src)`
    func resolve(markdownSource src: String) -> LoadedImage? {
        guard let doc = documentPath else { return nil }
        if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("data:") { return nil }
        let path = LinkPaths.resolveImagePath(src, markdownDir: LinkPaths.getParentDir(doc))
        return load(absolutePath: path)
    }

    /// `![[target]]`
    func resolve(embed target: String) -> LoadedImage? {
        let fm = FileManager.default
        let path = WikiLinkResolver.resolveImage(target, workspaceRoot: workspaceRoot, currentFilePath: documentPath,
                                                 fileExists: { fm.fileExists(atPath: $0) },
                                                 findFileByName: { root, name in Self.find(name, under: root) })
        return path.flatMap { load(absolutePath: $0) }
    }

    private static func find(_ name: String, under root: String) -> String? {
        guard let e = FileManager.default.enumerator(atPath: root) else { return nil }
        while let rel = e.nextObject() as? String {
            let last = (rel as NSString).lastPathComponent
            if last.hasPrefix(".") { e.skipDescendants(); continue }
            if last == name { return (root as NSString).appendingPathComponent(rel) }
        }
        return nil
    }
}

extension WidgetBox {
    /// CSS box of an image widget: `.cm-image img { max-width: 100% }`,
    /// `.cm-image-block { padding-left: 6px }`, width from `|N`.
    static func imageSize(_ img: LoadedImage, explicitWidth: Int?, block: Bool, columnWidth: CGFloat) -> CGSize {
        let maxW = block ? columnWidth - 6 : columnWidth
        // a PDF is a compact page preview by default; `|N` still sets any width
        let natural = img.isPDF ? min(img.pixelSize.width, PDFCard.defaultWidth) : img.pixelSize.width
        let w = min(explicitWidth.map { CGFloat($0) } ?? natural, maxW)
        return CGSize(width: w, height: w * img.pixelSize.height / img.pixelSize.width)
    }
}

/// Rendered PDFs: the first page on a white card, a page count, and a Quick Look button. The geometry is
/// shared by drawing and hit-testing, so the button's clickable area is always exactly what is drawn.
enum PDFCard {
    static let defaultWidth: CGFloat = 360
    static let buttonHeight: CGFloat = 26
    static let inset: CGFloat = 8
    static var labelFont: NSFont { .systemFont(ofSize: 11.5, weight: .medium) }

    /// The icon-only Quick Look button, bottom-right (hit-tested with the same rect).
    static func quickLookRect(in card: CGRect) -> CGRect {
        CGRect(x: card.maxX - inset - buttonHeight, y: card.maxY - inset - buttonHeight, width: buttonHeight, height: buttonHeight)
    }

    /// `controls`: the page count and Quick Look button, shown while the pointer is over the card.
    static func draw(_ img: NSImage, pages: Int, in rect: CGRect, theme: EditorTheme, controls: Bool) {
        let card = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                 hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        theme.foreground.withAlphaComponent(0.14).setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
        guard controls else { return }

        let ink = NSColor(white: 0.18, alpha: 1)
        let chip = { (r: CGRect) in
            NSGraphicsContext.saveGraphicsState()
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 3
            s.shadowOffset = NSSize(width: 0, height: -0.5)
            s.set()
            NSColor(white: 1, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.1).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2 - 0.5, yRadius: r.height / 2 - 0.5).stroke()
        }
        // page count, bottom-left
        if pages > 1 {
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: ink]
            let label = L("%d pages", pages) as NSString
            let size = label.size(withAttributes: attrs)
            let r = CGRect(x: rect.minX + inset, y: rect.maxY - inset - buttonHeight, width: ceil(size.width) + 18, height: buttonHeight)
            if r.maxX < quickLookRect(in: rect).minX - 6 {
                chip(r)
                label.draw(at: CGPoint(x: r.minX + 9, y: r.midY - size.height / 2), withAttributes: attrs)
            }
        }
        // Quick Look, bottom-right: the eye alone
        let q = quickLookRect(in: rect)
        chip(q)
        if let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: L("Quick Look"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let tinted = NSImage(size: eye.size, flipped: false) { r in eye.draw(in: r); ink.set(); r.fill(using: .sourceAtop); return true }
            tinted.draw(in: CGRect(x: q.midX - eye.size.width / 2, y: q.midY - eye.size.height / 2, width: eye.size.width, height: eye.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

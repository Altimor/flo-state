import AppKit
import FloCore
import ImageIO

/// A resolved image: CSS treats bitmap pixels as CSS px, so sizes are in
/// pixels (not NSImage points, which follow DPI metadata).
final class LoadedImage {
    let url: URL
    let pixelSize: CGSize
    private var _image: NSImage?
    init(url: URL, pixelSize: CGSize) { self.url = url; self.pixelSize = pixelSize }
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
        let w = min(explicitWidth.map { CGFloat($0) } ?? img.pixelSize.width, maxW)
        return CGSize(width: w, height: w * img.pixelSize.height / img.pixelSize.width)
    }
}

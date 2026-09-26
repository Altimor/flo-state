import AppKit
import UniformTypeIdentifiers
import FloCore

// Paste (use-prosemark-editor.ts paste handler): frontmatter paste, image
// paste, rich HTML → markdown, then CodeMirror's plain-text paste.

/// `MAX_IMAGE_SIZE`.
let maxPasteImageSize = 5 * 1024 * 1024

/// What a paste event carries (a `ClipboardEvent.clipboardData` view of an NSPasteboard).
public struct PastePayload {
    public var plain: String?
    public var html: String?
    /// First image item: data, `File.type` subtype ("png", "jpeg"...), `File.name`.
    public var image: (data: Data, format: String, name: String)?
    public init(plain: String? = nil, html: String? = nil, image: (data: Data, format: String, name: String)? = nil) {
        self.plain = plain; self.html = html; self.image = image
    }

    /// Read a pasteboard the way WebKit exposes it to a paste event.
    public static func read(_ pb: NSPasteboard) -> PastePayload {
        var p = PastePayload()
        p.plain = pb.string(forType: .string)
        p.html = pb.string(forType: .html)
        // Files (Finder copy): an image file is an image item named like the file.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for u in urls {
                guard let t = UTType(filenameExtension: u.pathExtension), t.conforms(to: .image),
                      let mime = t.preferredMIMEType, let data = try? Data(contentsOf: u) else { continue }
                p.image = (data, String(mime.split(separator: "/").last ?? "png"), u.lastPathComponent)
                return p
            }
            if !urls.isEmpty { return p }
        }
        // In-memory image data (screenshots, "Copy Image"). WebKit doesn't
        // expose images alongside web content (HTML/RTF from a text copy).
        let hasWebContent = pb.types?.contains(where: { $0 == .html || $0 == .rtf || $0 == .rtfd }) == true
        if !hasWebContent {
            if let d = pb.data(forType: .png) { p.image = (d, "png", "image.png") }
            else if let d = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { p.image = (d, "jpeg", "image.jpeg") }
            else if let d = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: d),
                    let png = rep.representation(using: .png, properties: [:]) {
                // WebKit hands TIFF clipboard images to the page as PNG
                p.image = (png, "png", "image.png")
            }
        }
        return p
    }
}

extension EditorFeatures {
    /// Paste from a pasteboard. `plain` = "Paste as plain text". Always handles.
    @discardableResult
    func paste(_ pb: NSPasteboard, plain: Bool) -> Bool {
        if plain { performMenuAction("paste-plain", pasteboard: pb); return true }
        paste(PastePayload.read(pb))
        return true
    }

    /// The paste handler chain.
    public func paste(_ p: PastePayload) {
        if pasteFrontmatter(p) { return }
        if let img = p.image { pasteImage(img.data, format: img.format, name: img.name); return }
        if pasteRichText(p) { return }
        pastePlain(p.plain ?? "")
    }

    /// `handleFrontmatterPaste`.
    func pasteFrontmatter(_ p: PastePayload) -> Bool {
        guard let text = p.plain, !text.isEmpty else { return false }
        let parsed = Frontmatter.parse(text)
        guard let fm = parsed.frontmatter else { return false }
        guard let hook = frontmatterPaste, hook(fm) else { return false }
        let body = parsed.body
        if !body.isEmpty { editor.run { t in t.dispatch(t.state.replaceSelection(body)); return true } }
        return true
    }

    /// `handleImagePaste`: save under `attachments/`, insert `![name](dest)`, caret after.
    func pasteImage(_ data: Data, format: String, name: String) {
        guard data.count <= maxPasteImageSize, let doc = editor.documentPath else { return }
        guard let saved = try? WorkspaceFS.saveClipboardImage(markdownFilePath: doc, data: data, format: format.isEmpty ? "png" : format) else { return }
        let md = "![\(name)](\(LinkPaths.formatMarkdownDestination(saved.relativePath)))"
        editor.run { t in
            let cursor = t.state.selection.main.head
            t.dispatch(TransactionSpec(changes: [Change(from: cursor, insert: md)], selection: .cursor(cursor + md.utf16.count)))
            return true
        }
        editor.reloadImages()
    }

    /// `handleRichTextPaste`.
    func pasteRichText(_ p: PastePayload) -> Bool {
        guard let html = p.html, !html.isEmpty, HTMLToMarkdown.isWorthConverting(html) else { return false }
        let md = HTMLToMarkdown.convert(html)
        if md.isEmpty { return false }
        if md == (p.plain ?? "") { return false }
        editor.run { t in t.dispatch(t.state.replaceSelection(md)); return true }
        return true
    }

    /// CodeMirror's own paste (`doPaste`): line separators normalized; one line
    /// per range when the line count matches a multi-range selection.
    func pastePlain(_ raw: String) {
        if raw.isEmpty { return }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        editor.run { t in
            let st = t.state
            let lines = text.components(separatedBy: "\n")
            var spec: TransactionSpec
            if st.selection.ranges.count > 1 && lines.count == st.selection.ranges.count {
                var i = 0
                spec = st.changeByRange { r in
                    let line = lines[i]; i += 1
                    return ([Change(from: r.from, to: r.to, insert: line)], .cursor(r.from + line.utf16.count))
                }
            } else {
                spec = st.replaceSelection(text)
            }
            spec.userEvent = "input.paste"
            spec.scrollIntoView = true
            t.dispatch(spec)
            return true
        }
    }
}

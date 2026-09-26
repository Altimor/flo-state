import AppKit
import FloCore

/// Offscreen rendering of the editor for automated visual/geometry parity
/// checks. Never orders a window on screen.
public enum Snapshot {
    public struct Result {
        public var png: Data
        /// Per UTF-16 position: [x, y, w, h] in window coordinates (top-left origin),
        /// or nil when the char isn't laid out.
        public var chars: [[Double]?]
        public var lineTops: [Double]
    }

    @MainActor
    public static func render(text: String, caret: Int, width: CGFloat = 1400, height: CGFloat = 900,
                              theme: EditorTheme = EditorTheme(), documentPath: String? = nil) -> Result {
        _ = NSApplication.shared
        MermaidOverlay.enabled = false   // captures draw the static canvas
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = theme.background
        let controller = EditorController(theme: theme)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = theme.background.cgColor
        window.contentView = content
        controller.scrollView.frame = content.bounds
        content.addSubview(controller.scrollView)
        controller.layoutColumn()
        controller.documentPath = documentPath
        controller.load(text, selection: .cursor(caret))
        controller.layoutColumn()
        controller.waitForAsyncWidgets()
        let tlm = controller.textView.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        controller.textView.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        controller.textView.needsDisplay = true
        content.display()

        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:]) ?? Data()

        // geometry
        let units = text.utf16.count
        var chars = [[Double]?](repeating: nil, count: units)
        var lineTops: [Double] = []
        let origin = controller.textView.textContainerOrigin
        let tcm = tlm.textContentManager!
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { frag in
            let fragStart = tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.location)
            lineTops.append(Double(frag.layoutFragmentFrame.minY + origin.y))
            for lf in frag.textLineFragments {
                let r = lf.characterRange
                for i in r.location..<(r.location + r.length) {
                    let pos = fragStart + i
                    guard pos < units else { continue }
                    let x0 = lf.locationForCharacter(at: i).x, x1 = lf.locationForCharacter(at: i + 1).x
                    let x = frag.layoutFragmentFrame.minX + lf.typographicBounds.minX + x0 + origin.x
                    let y = frag.layoutFragmentFrame.minY + lf.typographicBounds.minY + origin.y
                    chars[pos] = [Double(x), Double(y), Double(x1 - x0), Double(lf.typographicBounds.height)]
                }
            }
            return true
        }
        return Result(png: png, chars: chars, lineTops: lineTops)
    }
}

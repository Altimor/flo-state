import AppKit
import SwiftUI
import FloCore
import FloKit

// Shared chrome styling: theme tokens → NSColor, the UI font, CSS-like text
// metrics, and the fixed metrics of App.css / the Tailwind classes.

extension RGBA {
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Resolved chrome palette for the active mode (`:root` custom properties).
struct ShellPalette {
    let tokens: ThemeTokens
    var mode: ThemeMode { tokens.mode }
    var bg: NSColor { tokens.bg.ns }
    var fgBase: NSColor { tokens.fgBase.ns }
    var textPrimary: NSColor { tokens.textPrimary.ns }
    var textSecondary: NSColor { tokens.textSecondary.ns }
    var textMuted: NSColor { tokens.textMuted.ns }
    var textIconMuted: NSColor { tokens.textIconMuted.ns }
    var accent: NSColor { tokens.accent.ns }
    var sidebarFloatBg: NSColor { tokens.sidebarFloatBg.ns }
    var sidebarFloatBorder: NSColor { tokens.sidebarFloatBorder.ns }
    var surfaceSubtle: NSColor { tokens.surfaceSubtle.ns }
    var surfaceSubtleStrong: NSColor { tokens.surfaceSubtleStrong.ns }
    var surfaceSelected: NSColor { tokens.surfaceSelected.ns }
    var surfaceInput: NSColor { tokens.surfaceInput.ns }
    var surfaceCard: NSColor { tokens.surfaceCard.ns }
    var tabActiveBg: NSColor { tokens.tabActiveBg.ns }
    var lineSubtler: NSColor { tokens.lineSubtler.ns }
    var lineSubtle: NSColor { tokens.lineSubtle.ns }
    var borderColor: NSColor { tokens.borderColor.ns }
    var focusBorder: NSColor { tokens.focusBorder.ns }
    /// `.surface-card::before`: bg-base at 55%.
    var cardUnderlay: NSColor { tokens.bgBase.mixedWithTransparent(0.55).ns }
    var bgBaseOpaque: NSColor { tokens.bgBase.ns }

    init(settings: SettingsValues, mode: ThemeMode) {
        tokens = ThemeTokens(settings: settings, mode: mode)
    }
}

enum Metrics {
    static let chromeControlHeight: CGFloat = 32
    static let chromeControlPadding: CGFloat = 12
    static var chromeRowHeight: CGFloat { chromeControlHeight + chromeControlPadding * 2 }
    static let chromeDragHeight: CGFloat = 72
    static let tabBackingHeight: CGFloat = 52
    static let sidebarInset: CGFloat = 8
    /// Concentric with the window's corner (macOS 26 unified-toolbar windows: ~26pt)
    /// minus the panel's 8pt inset, like Finder's sidebar.
    static let windowCornerRadius: CGFloat = 26
    static let sidebarRadius: CGFloat = windowCornerRadius - 8
    static let narrowWidth: CGFloat = 850
    static let collapsedTabLeft: CGFloat = 132
    static let rowHeight: CGFloat = 32
    static let scrollbarGutter: CGFloat = 18
    static let footerHeight: CGFloat = 44

    /// `clampSidebarWidth`: 220…min(420, max(280, floor(35% viewport))).
    static func maxSidebarWidth(viewport: CGFloat) -> CGFloat {
        max(280, min(420, (viewport * 0.35).rounded(.down)))
    }

    static func clampSidebarWidth(_ w: Double, viewport: CGFloat) -> CGFloat {
        max(220, min(maxSidebarWidth(viewport: viewport), CGFloat(w.rounded())))
    }
}

/// CSS font-family stacks → NSFont.
enum FontStack {
    static func families(_ stack: String) -> [String] {
        var out: [String] = []
        var cur = "", quote: Character? = nil
        for ch in stack {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "," {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }
    }

    static let systemKeywords: Set<String> = ["-apple-system", "system-ui", "ui-sans-serif", "BlinkMacSystemFont", "sans-serif"]

    /// First installed family (or a generic system keyword) wins.
    static func font(_ stack: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        for fam in families(stack) {
            if systemKeywords.contains(fam) { return NSFont.systemFont(ofSize: size, weight: weight) }
            if fam == "ui-monospace" || fam == "monospace" { return NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
            if let members = NSFontManager.shared.availableMembers(ofFontFamily: fam), !members.isEmpty {
                let traits: NSFontTraitMask = weight >= .semibold ? .boldFontMask : []
                let w = weight >= .semibold ? 9 : (weight >= .medium ? 6 : 5)
                if let f = NSFontManager.shared.font(withFamily: fam, traits: traits, weight: w, size: size) { return f }
            }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Editor families for `EditorTheme` (quotes stripped).
    static func editorFamilies(_ stack: String) -> [String] { families(stack) }
}

/// Single-line text drawing with CSS line-box semantics: the glyph run is
/// vertically centred in a `lineHeight` box (half-leading), like Chrome.
struct TextStyle {
    var font: NSFont
    var color: NSColor
    var kern: CGFloat = 0
    var weightOverride: NSFont.Weight? = nil

    func attributed(_ s: String) -> NSAttributedString {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { a[.kern] = kern }
        return NSAttributedString(string: s, attributes: a)
    }

    func width(_ s: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(s))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Baseline offset from the top of a line box of `lineHeight`.
    func baseline(lineHeight: CGFloat) -> CGFloat {
        let asc = font.ascender, desc = -font.descender
        return (lineHeight - (asc + desc)) / 2 + asc
    }

    /// Draw at (x, lineTop) in a flipped context; truncates with "…" to `maxWidth`.
    func draw(_ s: String, x: CGFloat, lineTop: CGFloat, lineHeight: CGFloat, maxWidth: CGFloat? = nil,
              in ctx: CGContext, highlights: [(NSRange, NSColor, NSFont)] = []) {
        let a = NSMutableAttributedString(attributedString: attributed(s))
        for (r, c, f) in highlights where r.location + r.length <= a.length {
            a.addAttributes([.foregroundColor: c, .font: f], range: r)
        }
        var line = CTLineCreateWithAttributedString(a)
        if let mw = maxWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > mw + 0.01 {
            let ell = CTLineCreateWithAttributedString(attributed("…"))
            if let t = CTLineCreateTruncatedLine(line, Double(max(0, mw)), .end, ell) { line = t }
        }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: lineTop + baseline(lineHeight: lineHeight))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

enum UIFonts {
    /// `--ui-font` resolved at 13px (every chrome label).
    static func ui(_ settings: SettingsValues, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
        FontStack.font(settings.fontsUI, size: size, weight: weight)
    }
}

/// Top-left-origin view; the base for every chrome view.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
    /// Only the explicit drag region moves the window (web: `data-tauri-drag-region`).
    override var mouseDownCanMoveWindow: Bool { false }
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if let c = fillColor { c.setFill(); bounds.fill(using: .sourceOver) }
    }
}

extension NSView {
    /// Frame in the window's content view, top-left origin (for dumps/tests).
    func frameInRoot() -> CGRect {
        guard let root = window?.contentView else { return frame }
        let r = convert(bounds, to: root)
        return root.isFlipped ? r : CGRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
    }
}

extension CGRect {
    var dumpArray: [Double] { [minX, minY, width, height].map { (Double($0) * 100).rounded() / 100 } }
}

/// Continuous-curvature ("squircle") rounded rect, as the system draws window corners.
func continuousRoundedPath(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    let cg = SwiftUI.RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r).cgPath
    return NSBezierPath(cgPath: cg)
}

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

extension EditorTheme {
    /// The editor theme the web app's CSS would produce for these settings.
    static func from(settings v: SettingsValues, mode: ThemeMode) -> EditorTheme {
        let t = ThemeTokens(settings: v, mode: mode)
        return EditorTheme(
            baseSize: CGFloat(v.editorFontSize), lineHeight: CGFloat(v.editorLineHeight),
            headingSpaceBefore: CGFloat(v.editorHeadingSpaceBefore), headingSpaceAfter: CGFloat(v.editorHeadingSpaceAfter),
            paragraphSpacing: CGFloat(v.editorParagraphSpacing), bulletSpacing: CGFloat(v.editorBulletSpacing),
            fontFamilies: FontStack.editorFamilies(v.fontsEditor), foreground: t.fgBase.ns, accent: t.accent.ns,
            headingColor: t.headingColor.ns, subheadingColor: NSColor(hex: v.editorSubheadingColor),
            contrast: CGFloat(t.contrast), background: t.bgBase.mixedWithTransparent(t.bgOpacity).ns)
    }
}

extension NSScrollView {
    /// macOS 26 adds a titlebar "scroll pocket" (blur + backdrop) to scroll
    /// views reaching under the titlebar. The web app has its own tab-strip
    /// backing instead, and the backdrop breaks offscreen captures: hide it.
    func suppressScrollPocket() {
        for v in subviews {
            let n = NSStringFromClass(type(of: v))
            if n.contains("Pocket") || n.contains("BackdropView") { v.isHidden = true }
        }
    }
}

import CoreImage

/// CSS `backdrop-filter: blur(r)` for layer-backed views (within-window).
@MainActor func applyBackdropBlur(_ v: NSView, radius: CGFloat) {
    v.wantsLayer = true
    v.layerUsesCoreImageFilters = true
    if let f = CIFilter(name: "CIGaussianBlur") {
        f.setDefaults()
        f.setValue(radius / 2, forKey: kCIInputRadiusKey)
        v.layer?.backgroundFilters = [f]
        // clip: Gaussian output spreads beyond the view otherwise
        v.layer?.masksToBounds = true
    }
}

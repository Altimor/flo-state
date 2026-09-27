import AppKit
import FloCore

/// Concrete fonts, colours and metrics for the editor, resolved the way the
/// web app's CSS resolves them (see prosemark-theme.css, App.css, settings).
public final class EditorTheme {
    public var baseSize: CGFloat
    public var lineHeight: CGFloat          // multiplier
    public var headingSpaceBefore: CGFloat  // px added to the 1rem heading top padding
    public var headingSpaceAfter: CGFloat
    public var paragraphSpacing: CGFloat
    public var bulletSpacing: CGFloat
    public var fontFamilies: [String]
    public var foreground: NSColor
    public var accent: NSColor
    public var headingColor: NSColor
    public var subheadingColor: NSColor
    public var contrast: CGFloat
    public var background: NSColor
    /// Root font size for `rem` units (the web app's html font-size).
    public let rem: CGFloat = 16
    public let maxTextWidth: CGFloat = 734

    public init(baseSize: CGFloat = 18, lineHeight: CGFloat = 1.5, headingSpaceBefore: CGFloat = 0,
                headingSpaceAfter: CGFloat = 8, paragraphSpacing: CGFloat = 0, bulletSpacing: CGFloat = 12,
                fontFamilies: [String] = ["Proxima Nova"], foreground: NSColor = NSColor(hex: "#0D0D0D"),
                accent: NSColor = .controlAccentColor, headingColor: NSColor = NSColor(hex: "#191919"),
                subheadingColor: NSColor = NSColor(hex: "#4A86E8"), contrast: CGFloat = 0.36,
                background: NSColor = NSColor(hex: "#F9F9F9")) {
        self.baseSize = baseSize
        self.lineHeight = lineHeight
        self.headingSpaceBefore = headingSpaceBefore
        self.headingSpaceAfter = headingSpaceAfter
        self.paragraphSpacing = paragraphSpacing
        self.bulletSpacing = bulletSpacing
        self.fontFamilies = fontFamilies
        self.foreground = foreground
        self.accent = accent
        self.headingColor = headingColor
        self.subheadingColor = subheadingColor
        self.contrast = contrast
        self.background = background
    }

    // MARK: colours (App.css tokens)

    public var textColor: NSColor { foreground.withAlphaComponent(0.8) }
    public var primaryColor: NSColor { foreground }
    public var mutedColor: NSColor { foreground.withAlphaComponent(0.54) }
    public var codeBackground: NSColor { foreground.withAlphaComponent(contrast * 0.16) }
    public var blockquoteBar: NSColor { foreground.withAlphaComponent(contrast * 0.58) }
    /// System highlight colour (System Settings → Appearance).
    public var selectionColor: NSColor { .selectedTextBackgroundColor }

    public func color(_ role: ColorRole) -> NSColor {
        switch role {
        case .text, .inherit: return textColor
        case .primary: return primaryColor
        case .muted: return mutedColor
        case .link: return accent
        case .heading1: return headingColor
        case .subheading: return subheadingColor
        case .transparent: return .clear
        case .invalid: return NSColor(oklchL: 0.7593, c: 0.182, h: 28.91)
        case .syntax(let name): return Self.syntaxColors[name] ?? textColor
        }
    }

    static let syntaxColors: [String: NSColor] = [
        "keyword": NSColor(oklchL: 0.7005, c: 0.217, h: 296.83),
        "atom": NSColor(oklchL: 0.6569, c: 0.2, h: 259.93),
        "literal": NSColor(oklchL: 0.7127, c: 0.101, h: 169.93),
        "string": NSColor(oklchL: 0.6853, c: 0.164, h: 25.1),
        "regexp": NSColor(oklchL: 0.7688, c: 0.16, h: 43.42),
        "definitionVariable": NSColor(oklchL: 0.6142, c: 0.158, h: 259.6),
        "localVariable": NSColor(oklchL: 0.7588, c: 0.082, h: 184.11),
        "typeNamespace": NSColor(oklchL: 0.6451, c: 0.083, h: 165.19),
        "className": NSColor(oklchL: 0.7614, c: 0.1, h: 168.52),
        "specialVariable": NSColor(oklchL: 0.6667, c: 0.193, h: 282.06),
        "definitionProperty": NSColor(oklchL: 0.5892, c: 0.132, h: 259.4),
    ]

    // MARK: fonts

    private var fontCache: [String: NSFont] = [:]

    /// CSS font matching: first available family, closest weight (for 600 with
    /// no semibold face the browser picks the next heavier: Bold), italic
    /// synthesised when the family has no italic face.
    public func font(size: CGFloat, weight: Int, mono: Bool) -> NSFont {
        let key = "\(size)|\(weight)|\(mono)"
        if let f = fontCache[key] { return f }
        let f: NSFont
        if mono {
            f = NSFont.monospacedSystemFont(ofSize: size, weight: weight >= 600 ? .semibold : .regular)
        } else {
            f = Self.cssFont(families: fontFamilies, size: size, weight: weight)
        }
        fontCache[key] = f
        return f
    }

    static func cssFont(families: [String], size: CGFloat, weight: Int) -> NSFont {
        for fam in families {
            guard let members = NSFontManager.shared.availableMembers(ofFontFamily: fam), !members.isEmpty else { continue }
            // members: [postscriptName, faceName, weight(0-15), traits]
            let upright = members.filter { (($0[3] as? UInt) ?? 0) & UInt(NSFontTraitMask.italicFontMask.rawValue) == 0 }
            let pool = upright.isEmpty ? members : upright
            let cssOf: ([Any]) -> Int = { m in Self.appkitToCss((m[2] as? Int) ?? 5, face: (m[1] as? String) ?? "") }
            let candidates = pool.map { (cssOf($0), $0[0] as! String) }
            // CSS weight matching algorithm (desired >= 500: prefer heavier)
            let chosen: String?
            let exact = candidates.first { $0.0 == weight }
            if let e = exact { chosen = e.1 } else if weight > 500 {
                chosen = (candidates.filter { $0.0 > weight }.min { $0.0 < $1.0 } ?? candidates.filter { $0.0 < weight }.max { $0.0 < $1.0 })?.1
            } else {
                chosen = (candidates.filter { $0.0 < weight }.max { $0.0 < $1.0 } ?? candidates.filter { $0.0 > weight }.min { $0.0 < $1.0 })?.1
            }
            if let name = chosen, let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size, weight: weight >= 600 ? .semibold : .regular)
    }

    /// NSFontManager weight (0-15) -> CSS weight.
    static func appkitToCss(_ w: Int, face: String) -> Int {
        let f = face.lowercased()
        if f.contains("thin") || f.contains("hairline") { return 100 }
        if f.contains("extralight") || f.contains("ultralight") { return 200 }
        if f.contains("light") { return 300 }
        if f.contains("medium") { return 500 }
        if f.contains("semibold") || f.contains("demibold") { return 600 }
        if f.contains("extrabold") || f.contains("extrabld") || f.contains("ultrabold") || f.contains("heavy") { return 800 }
        if f.contains("black") { return 900 }
        if f.contains("bold") { return 700 }
        switch w {
        case ...3: return 300
        case 4...6: return 400
        case 7: return 500
        case 8: return 600
        case 9...10: return 700
        case 11...12: return 800
        default: return 900
        }
    }

    /// Width of "0" in the body font = CSS `1ch`.
    public lazy var ch: CGFloat = {
        let f = font(size: baseSize, weight: 400, mono: false)
        return ("0" as NSString).size(withAttributes: [.font: f]).width
    }()

    /// WebKit (the app's engine) lays Apple Color Emoji out at a 4/3em
    /// advance, bigger than CoreText's default (~1.22em): the emoji font sized
    /// so its advance matches.
    public func emojiFont(size: CGFloat) -> NSFont {
        let key = "emoji|\(size)"
        if let f = fontCache[key] { return f }
        guard let probe = NSFont(name: "AppleColorEmoji", size: size) else { return font(size: size, weight: 400, mono: false) }
        let adv = ("\u{1F604}" as NSString).size(withAttributes: [.font: probe]).width
        let target = Self.webkitEmojiAdvance(size)
        let f = NSFont(name: "AppleColorEmoji", size: adv > 0 ? size * target / adv : size) ?? probe
        fontCache[key] = f
        return f
    }

    /// WebKit's advance for an emoji at a font size (whole pixels, not linear:
    /// 24px at 18px, 33px at 28.8px), measured in the oracle every 0.1px from 8 to 64.
    static let emojiAdvanceTable: [UInt8] = [12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 20, 20, 20, 20, 20, 20, 20, 21, 21, 21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 23, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 25, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 27, 28, 28, 28, 28, 28, 28, 28, 28, 28, 29, 29, 29, 29, 29, 29, 29, 29, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 31, 31, 31, 31, 31, 31, 31, 31, 32, 32, 32, 32, 32, 32, 32, 32, 32, 33, 33, 33, 33, 33, 33, 33, 33, 33, 34, 34, 34, 34, 34, 34, 34, 34, 34, 35, 35, 35, 35, 35, 35, 35, 35, 35, 36, 36, 36, 36, 36, 36, 36, 36, 36, 37, 37, 37, 37, 37, 37, 37, 37, 37, 38, 38, 38, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 39, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 41, 41, 41, 41, 41, 41, 41, 41, 41, 42, 42, 42, 42, 42, 42, 42, 42, 42, 43, 43, 43, 43, 43, 43, 43, 43, 43, 44, 44, 44, 44, 44, 44, 44, 44, 44, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 46, 46, 46, 46, 46, 46, 46, 46, 46, 46, 46, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47, 47, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 53, 53, 53, 53, 53, 53, 53, 53, 53, 54, 54, 54, 54, 54, 54, 54, 54, 54, 54, 55, 55, 55, 55, 55, 55, 55, 55, 55, 55, 56, 56, 56, 56, 56, 56, 56, 56, 56, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 58, 58, 58, 58, 58, 58, 58, 58, 58, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 60, 60, 60, 60, 60, 60, 60, 60, 60, 61, 61, 61, 61, 61, 61, 61, 61, 61, 61, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 63, 63, 63, 63, 63, 63, 63, 63, 63, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 65, 65, 65, 65, 65, 65, 65, 65, 65, 66, 66, 66, 66, 66, 66, 66, 66, 66, 66, 67, 67, 67, 67, 67, 67, 67, 67, 67, 67, 68, 68, 68, 68, 68, 68, 68, 68, 68, 68, 69, 69, 69]
    static func webkitEmojiAdvance(_ size: CGFloat) -> CGFloat {
        let i = Int(((size - 8) * 10).rounded())
        if i >= 0 && i < emojiAdvanceTable.count { return CGFloat(emojiAdvanceTable[i]) }
        return size * 9 / 8
    }

    /// Grapheme drawn from the emoji font (emoji presentation, or text-default
    /// emoji forced with VS16).
    public static func isEmoji(_ c: Character) -> Bool {
        let sc = c.unicodeScalars
        guard let first = sc.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && sc.contains { $0.value == 0xFE0F }
    }

    public lazy var spaceWidth: CGFloat = {
        (" " as NSString).size(withAttributes: [.font: font(size: baseSize, weight: 400, mono: false)]).width
    }()

    public func hasItalicFace() -> Bool {
        for fam in fontFamilies {
            if let m = NSFontManager.shared.availableMembers(ofFontFamily: fam), !m.isEmpty {
                return m.contains { (($0[3] as? UInt) ?? 0) & UInt(NSFontTraitMask.italicFontMask.rawValue) != 0 }
            }
        }
        return true
    }
}

extension NSColor {
    public convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: CGFloat
        if s.count == 3 {
            r = CGFloat((v >> 8) & 0xF) / 15; g = CGFloat((v >> 4) & 0xF) / 15; b = CGFloat(v & 0xF) / 15
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// CSS oklch() -> sRGB.
    public convenience init(oklchL L: Double, c C: Double, h H: Double) {
        let hr = H * .pi / 180
        let a = C * cos(hr), b = C * sin(hr)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        func gamma(_ x: Double) -> CGFloat {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return CGFloat(min(1, max(0, v)))
        }
        self.init(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                  green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                  blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: 1)
    }
}

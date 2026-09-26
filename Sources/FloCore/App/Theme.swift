import Foundation

public enum ThemeMode: String, CaseIterable { case light, dark }

/// sRGB colour with alpha, components 0...1.
public struct RGBA: Equatable, CustomStringConvertible {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    public static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// Parses `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` (the forms the settings UI writes).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        func byte(_ str: String) -> Double { Double(Int(str, radix: 16) ?? 0) / 255 }
        let chars = Array(s)
        switch chars.count {
        case 3, 4:
            let parts = chars.map { String([$0, $0]) }
            self.init(r: byte(parts[0]), g: byte(parts[1]), b: byte(parts[2]), a: chars.count == 4 ? byte(parts[3]) : 1)
        case 6, 8:
            let parts = stride(from: 0, to: chars.count, by: 2).map { String(chars[$0...$0 + 1]) }
            self.init(r: byte(parts[0]), g: byte(parts[1]), b: byte(parts[2]), a: chars.count == 8 ? byte(parts[3]) : 1)
        default:
            return nil
        }
    }

    /// CSS `color-mix(in srgb, self p, transparent)`: same colour, alpha scaled
    /// by `p` (clamped to 0...1, as CSS clamps the percentage).
    public func mixedWithTransparent(_ p: Double) -> RGBA {
        RGBA(r: r, g: g, b: b, a: a * min(1, max(0, p)))
    }

    public var hexString: String {
        func h(_ v: Double) -> String { String(format: "%02X", Int((min(1, max(0, v)) * 255).rounded())) }
        return "#" + h(r) + h(g) + h(b) + (a < 1 ? h(a) : "")
    }

    public var description: String { hexString }
}

/// The six editable primaries of one theme mode.
public struct ThemePrimaries: Equatable {
    public var accent: String
    public var background: String
    public var foreground: String
    public var headingColor: String
    public var translucent: Double
    public var contrast: Double

    /// Setting keys → values for `theme.{mode}.*` (what applying a preset writes).
    public func settings(for mode: ThemeMode) -> [(String, ConfigValue)] {
        let p = "theme.\(mode.rawValue)."
        return [
            (p + "accent", .string(accent)),
            (p + "background", .string(background)),
            (p + "foreground", .string(foreground)),
            (p + "heading-color", .string(headingColor)),
            (p + "translucent", .number(translucent)),
            (p + "contrast", .number(contrast)),
        ]
    }

    public init(accent: String, background: String, foreground: String, headingColor: String, translucent: Double, contrast: Double) {
        self.accent = accent; self.background = background; self.foreground = foreground
        self.headingColor = headingColor; self.translucent = translucent; self.contrast = contrast
    }

    init?(json: JSONValue) {
        guard let accent = json["accent"]?.stringValue, let bg = json["background"]?.stringValue,
              let fg = json["foreground"]?.stringValue, let heading = json["heading-color"]?.stringValue,
              let translucent = json["translucent"]?.doubleValue, let contrast = json["contrast"]?.doubleValue
        else { return nil }
        self.init(accent: accent, background: bg, foreground: fg, headingColor: heading, translucent: translucent, contrast: contrast)
    }

    /// The primaries currently in effect for `mode`.
    public init(settings: SettingsValues, mode: ThemeMode) {
        self.init(
            accent: settings.themeAccent(mode), background: settings.themeBackground(mode),
            foreground: settings.themeForeground(mode), headingColor: settings.themeHeadingColor(mode),
            translucent: settings.themeTranslucent(mode), contrast: settings.themeContrast(mode))
    }
}

/// A theme preset folder (`shared/themes/<slug>/{light,dark}.json`).
public struct ThemePreset: Equatable {
    public let slug: String
    /// kebab-case slug → Title Case ("warm-paper" → "Warm Paper").
    public let name: String
    public let light: ThemePrimaries
    public let dark: ThemePrimaries

    public func primaries(_ mode: ThemeMode) -> ThemePrimaries { mode == .light ? light : dark }

    public static func displayName(forSlug slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// All bundled presets, sorted by slug (glob order).
    public static let all: [ThemePreset] = {
        guard let dir = FloResources.bundle.url(forResource: "themes", withExtension: nil, subdirectory: "Resources"),
              let slugs = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return slugs.sorted().compactMap { slug in
            func load(_ mode: String) -> ThemePrimaries? {
                let url = dir.appendingPathComponent(slug).appendingPathComponent("\(mode).json")
                guard let data = try? Data(contentsOf: url), let json = try? JSON.parse(data: data) else { return nil }
                return ThemePrimaries(json: json)
            }
            guard let l = load("light"), let d = load("dark") else { return nil }
            return ThemePreset(slug: slug, name: displayName(forSlug: slug), light: l, dark: d)
        }
    }()

    public static func named(_ name: String) -> ThemePreset? { all.first { $0.name == name } }
}

/// Resolved colour tokens for one mode — the native equivalent of the CSS
/// custom properties on `:root` (`App.css` + `theme.ts`).
public struct ThemeTokens: Equatable {
    public let mode: ThemeMode
    public let accent: RGBA
    public let bgBase: RGBA
    public let fgBase: RGBA
    public let headingColor: RGBA
    /// `--bg-opacity` = 1 − (translucent/100)·0.95, translucent clamped to 0…100.
    public let bgOpacity: Double
    /// `--contrast` = 0.2 + (contrast/100)·0.8, contrast clamped to 0…100.
    public let contrast: Double

    public init(primaries: ThemePrimaries, mode: ThemeMode) {
        self.mode = mode
        let fallback = SettingsValues([:])
        accent = RGBA(hex: primaries.accent) ?? RGBA(hex: fallback.themeAccent(mode))!
        bgBase = RGBA(hex: primaries.background) ?? RGBA(hex: fallback.themeBackground(mode))!
        fgBase = RGBA(hex: primaries.foreground) ?? RGBA(hex: fallback.themeForeground(mode))!
        headingColor = RGBA(hex: primaries.headingColor) ?? RGBA(hex: fallback.themeHeadingColor(mode))!
        bgOpacity = ThemeTokens.bgOpacity(translucent: primaries.translucent)
        contrast = ThemeTokens.contrast(slider: primaries.contrast)
    }

    public init(settings: SettingsValues, mode: ThemeMode) {
        self.init(primaries: ThemePrimaries(settings: settings, mode: mode), mode: mode)
    }

    /// `DERIVED_PRIMARIES.translucent` (`Number(v) || 0`: NaN → 0).
    public static func bgOpacity(translucent: Double) -> Double {
        let t = min(100, max(0, translucent.isNaN ? 0 : translucent))
        return 1 - (t / 100) * 0.95
    }

    /// `DERIVED_PRIMARIES.contrast`.
    public static func contrast(slider: Double) -> Double {
        let c = min(100, max(0, slider.isNaN ? 0 : slider))
        return 0.2 + (c / 100) * 0.8
    }

    private func fg(_ factor: Double) -> RGBA { fgBase.mixedWithTransparent(contrast * factor) }

    // Base / text
    public var bg: RGBA { bgBase.mixedWithTransparent(bgOpacity) }
    public var textPrimary: RGBA { fgBase }
    public var textSecondary: RGBA { fgBase.mixedWithTransparent(0.80) }
    public var textMuted: RGBA { fgBase.mixedWithTransparent(0.54) }
    public var textIconMuted: RGBA { fgBase.mixedWithTransparent(0.40) }
    // Lines
    public var borderColor: RGBA { fg(0.24) }
    public var lineSubtle: RGBA { fg(0.24) }
    public var lineSubtler: RGBA { fg(0.15) }
    public var focusBorder: RGBA { fg(0.65) }
    public var sidebarDividerRight: RGBA { lineSubtler }
    // Sidebar
    public var sidebarFloatBg: RGBA { fg(0.07) }
    public var sidebarFloatBorder: RGBA { fg(0.18) }
    // Surfaces
    public var surfacePrimary: RGBA { bgBase }
    /// Light mode drops the card fill (`[data-theme="light"] --surface-card: transparent`).
    public var surfaceCard: RGBA { mode == .light ? .transparent : fg(0.16) }
    public var surfaceSubtle: RGBA { fg(0.18) }
    public var surfaceSubtleStrong: RGBA { fg(0.36) }
    public var surfaceInput: RGBA { fg(mode == .light ? 0.20 : 0.28) }
    public var surfaceSelected: RGBA { fg(0.26) }
    public var surfacePalette: RGBA { bgBase.mixedWithTransparent(0.80) }
    // Items / tabs
    public var itemHoverBg: RGBA { fg(0.16) }
    public var itemActiveBg: RGBA { fg(0.26) }
    public var tabActiveBg: RGBA { fg(mode == .dark ? 0.34 : 0.24) }
    // Code / misc
    public var codeBg: RGBA { fg(0.16) }
    public var kbdBg: RGBA { fg(0.16) }
    public var scrollbarThumb: RGBA { fg(0.58) }
    public var blockquoteBorder: RGBA { fg(0.58) }
    public var linkColor: RGBA { accent }
    public var editorSelectionBg: RGBA { accent.mixedWithTransparent(0.30) }
    public var compactPickerTriggerBgTint: RGBA { fg(0.22) }
    /// Mermaid canvas: `color-mix(in srgb, black calc(var(--contrast) * 24%), transparent)`.
    public var mermaidCanvasBg: RGBA { RGBA(r: 0, g: 0, b: 0).mixedWithTransparent(contrast * 0.24) }
}

public enum ThemeResolver {
    /// `activeMode`: explicit light/dark wins, anything else follows the system.
    public static func activeMode(_ preference: SettingsValues.ThemePreference, systemIsDark: Bool) -> ThemeMode {
        switch preference {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemIsDark ? .dark : .light
        }
    }

    /// Name of the preset whose primaries match the current values for `mode`, if any.
    public static func matchingPreset(_ settings: SettingsValues, mode: ThemeMode) -> ThemePreset? {
        let current = ThemePrimaries(settings: settings, mode: mode)
        return ThemePreset.all.first { preset in
            let p = preset.primaries(mode)
            return p.accent.lowercased() == current.accent.lowercased()
                && p.background.lowercased() == current.background.lowercased()
                && p.foreground.lowercased() == current.foreground.lowercased()
                && p.headingColor.lowercased() == current.headingColor.lowercased()
                && p.translucent == current.translucent && p.contrast == current.contrast
        }
    }
}

import Foundation

public enum SettingsScope: String { case global, workspace }

public enum SettingsError: Error, Equatable {
    case noWorkspaceConfigPath
    case io(String)
}

/// Three-layer settings: schema defaults → global (`{appData}/config`) →
/// workspace (`{root}/.writer/config`). Port of `config.rs::Settings`.
public final class AppSettings {
    public private(set) var defaults: [String: ConfigValue]
    public private(set) var global: [String: ConfigValue]
    public private(set) var workspace: [String: ConfigValue] = [:]
    public private(set) var globalRaw: String
    public private(set) var workspaceRaw: String = ""
    public let globalPath: URL
    public private(set) var workspacePath: URL?

    /// `Settings::new`: loads `{configDir}/config`, then runs the two one-time
    /// migrations (legacy `preferences.json` theme, per-mode font keys).
    public init(globalConfigDir: URL) {
        defaults = SettingsSchema.defaults
        globalPath = globalConfigDir.appendingPathComponent("config")
        if FileManager.default.fileExists(atPath: globalPath.path) {
            let raw = (try? String(contentsOf: globalPath, encoding: .utf8)) ?? ""
            globalRaw = raw
            global = ConfigFile.parse(raw)
        } else {
            globalRaw = ""
            global = [:]
        }
        migrateFromPreferences(globalConfigDir)
        migrateThemeFonts()
    }

    // MARK: Migrations

    private func migrateThemeFonts() {
        let slots: [(String, String, String)] = [
            ("fonts.ui", "theme.light.ui-font", "theme.dark.ui-font"),
            ("fonts.editor", "theme.light.editor-font", "theme.dark.editor-font"),
            ("fonts.mono", "theme.light.mono-font", "theme.dark.mono-font"),
        ]
        for (newKey, lightKey, darkKey) in slots {
            guard let value = global[lightKey] ?? global[darkKey] else { continue }
            if global[newKey] == nil {
                do { try setGlobal(newKey, value) } catch { continue }
            }
            for oldKey in [lightKey, darkKey] where global[oldKey] != nil {
                try? resetGlobal(oldKey)
            }
        }
    }

    private func migrateFromPreferences(_ appDataDir: URL) {
        let prefs = appDataDir.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: prefs.path) else { return }
        if global["appearance.theme"] != nil {
            try? FileManager.default.removeItem(at: prefs)
            return
        }
        if let data = try? Data(contentsOf: prefs), let json = try? JSON.parse(data: data),
           let theme = json["theme"]?.stringValue {
            try? setGlobal("appearance.theme", .string(theme))
        }
        try? FileManager.default.removeItem(at: prefs)
    }

    // MARK: Workspace layer

    public func loadWorkspace(root: URL) {
        let path = root.appendingPathComponent(".writer").appendingPathComponent("config")
        if FileManager.default.fileExists(atPath: path.path) {
            let raw = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            workspace = ConfigFile.parse(raw)
            workspaceRaw = raw
        } else {
            workspace = [:]
            workspaceRaw = ""
        }
        workspacePath = path
    }

    public func clearWorkspace() {
        workspace = [:]
        workspaceRaw = ""
        workspacePath = nil
    }

    // MARK: Reads

    /// Merged value: workspace → global → default.
    public func get(_ key: String) -> ConfigValue? {
        workspace[key] ?? global[key] ?? defaults[key]
    }

    public func merged() -> [String: ConfigValue] {
        var result = defaults
        for (k, v) in global { result[k] = v }
        for (k, v) in workspace { result[k] = v }
        return result
    }

    // MARK: Writes

    public func set(_ key: String, _ value: ConfigValue, scope: SettingsScope) throws {
        switch scope {
        case .global: try setGlobal(key, value)
        case .workspace: try setWorkspace(key, value)
        }
    }

    public func reset(_ key: String, scope: SettingsScope) throws {
        switch scope {
        case .global: try resetGlobal(key)
        case .workspace: try resetWorkspace(key)
        }
    }

    public func setGlobal(_ key: String, _ value: ConfigValue) throws {
        global[key] = value
        var current = ConfigFile.parse(globalRaw)
        current[key] = value
        globalRaw = ConfigFile.serialize(current, original: globalRaw)
        try write(globalRaw, to: globalPath, createParent: true)
    }

    public func setWorkspace(_ key: String, _ value: ConfigValue) throws {
        guard let path = workspacePath else { throw SettingsError.noWorkspaceConfigPath }
        workspace[key] = value
        var current = ConfigFile.parse(workspaceRaw)
        current[key] = value
        workspaceRaw = ConfigFile.serialize(current, original: workspaceRaw)
        try write(workspaceRaw, to: path, createParent: true)
    }

    public func resetGlobal(_ key: String) throws {
        global.removeValue(forKey: key)
        globalRaw = ConfigFile.removeKey(key, from: globalRaw)
        try write(globalRaw, to: globalPath, createParent: true)
    }

    /// Note: unlike `resetGlobal`, the Rust original does not create the
    /// `.writer` directory here, so resetting in a workspace without one fails.
    public func resetWorkspace(_ key: String) throws {
        guard let path = workspacePath else { throw SettingsError.noWorkspaceConfigPath }
        workspace.removeValue(forKey: key)
        workspaceRaw = ConfigFile.removeKey(key, from: workspaceRaw)
        try write(workspaceRaw, to: path, createParent: false)
    }

    public func reloadGlobal() {
        guard FileManager.default.fileExists(atPath: globalPath.path) else { return }
        globalRaw = (try? String(contentsOf: globalPath, encoding: .utf8)) ?? ""
        global = ConfigFile.parse(globalRaw)
    }

    public func reloadWorkspace() {
        guard let path = workspacePath, FileManager.default.fileExists(atPath: path.path) else { return }
        workspaceRaw = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        workspace = ConfigFile.parse(workspaceRaw)
    }

    private func write(_ text: String, to url: URL, createParent: Bool) throws {
        do {
            if createParent {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data(text.utf8).write(to: url)
        } catch {
            throw SettingsError.io(error.localizedDescription)
        }
    }

    // MARK: Derived

    /// Extensions the editor opens (`sync_supported_extensions`): only a
    /// *list*-valued `files.associations` counts; a single-line value parses as
    /// a string and — faithfully to the Rust — falls back to the built-in list.
    public var supportedExtensions: SupportedExtensions {
        if case let .list(patterns)? = get("files.associations") {
            return SupportedExtensions(patterns: patterns)
        }
        return SupportedExtensions(patterns: [])
    }

    public var values: SettingsValues { SettingsValues(merged()) }
}

/// Typed read-only view over a merged settings map. Each accessor falls back to
/// the schema default when the stored value is missing or of the wrong type.
public struct SettingsValues {
    public let raw: [String: ConfigValue]
    public init(_ raw: [String: ConfigValue]) { self.raw = raw }

    private func num(_ key: String) -> Double {
        raw[key]?.numberValue ?? SettingsSchema.def(key)?.defaultValue.numberValue ?? 0
    }
    private func bool(_ key: String) -> Bool {
        raw[key]?.boolValue ?? SettingsSchema.def(key)?.defaultValue.boolValue ?? false
    }
    private func str(_ key: String) -> String {
        raw[key]?.stringValue ?? SettingsSchema.def(key)?.defaultValue.stringValue ?? ""
    }
    private func list(_ key: String) -> [String] {
        if let l = raw[key]?.listValue { return l }
        if let s = raw[key]?.stringValue { return [s] }
        return SettingsSchema.def(key)?.defaultValue.listValue ?? []
    }
    private func option<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        T(rawValue: str(key)) ?? T(rawValue: SettingsSchema.def(key)?.defaultValue.stringValue ?? "") ?? fallback
    }

    // Editor
    public var editorFontSize: Double { num("editor.font-size") }
    public var editorLineHeight: Double { num("editor.line-height") }
    public var editorTabSize: Double { num("editor.tab-size") }
    public var editorAutoInsertDailyHeading: Bool { bool("editor.auto-insert-daily-heading") }
    public var editorShowOutline: Bool { bool("editor.show-outline") }
    public var editorShowHeadingChevrons: Bool { bool("editor.show-heading-chevrons") }
    public var editorSpellCheck: Bool { bool("editor.spell-check") }
    public var editorOutlineIndentPerLevel: Double { num("editor.outline-indent-per-level") }
    public var editorJumpToBottomAfterMinutes: Double { num("editor.jump-to-bottom-after-minutes") }
    public var editorHeadingSpaceBefore: Double { num("editor.heading-space-before") }
    public var editorHeadingSpaceAfter: Double { num("editor.heading-space-after") }
    public var editorSubheadingColor: String { str("editor.subheading-color") }
    public var editorParagraphSpacing: Double { num("editor.paragraph-spacing") }
    public var editorBulletSpacing: Double { num("editor.bullet-spacing") }
    // Status bar
    public var statusbarShowWords: Bool { bool("statusbar.show-words") }
    public var statusbarShowCharacters: Bool { bool("statusbar.show-characters") }
    public var statusbarShowParagraphs: Bool { bool("statusbar.show-paragraphs") }
    // Appearance
    public enum ThemePreference: String { case system, light, dark }
    public enum SidebarFileLabel: String { case title, filename }
    public enum EditorWidth: String { case full, narrow }
    public var appearanceTheme: ThemePreference { option("appearance.theme", .system) }
    public var appearanceSidebarWidth: Double { num("appearance.sidebar-width") }
    public var appearanceSidebarVisible: Bool { bool("appearance.sidebar-visible") }
    public var appearanceSidebarFileLabel: SidebarFileLabel { option("appearance.sidebar-file-label", .title) }
    public var appearanceSidebarShowSearch: Bool { bool("appearance.sidebar-show-search") }
    public var appearanceSidebarShowRecents: Bool { bool("appearance.sidebar-show-recents") }
    public var appearanceEditorWidth: EditorWidth { option("appearance.editor-width", .full) }
    // Fonts
    public var fontsUI: String { str("fonts.ui") }
    public var fontsEditor: String { str("fonts.editor") }
    public var fontsMono: String { str("fonts.mono") }
    // Theme
    public func themePreset(_ mode: ThemeMode) -> String { str("theme.\(mode.rawValue).preset") }
    public func themeAccent(_ mode: ThemeMode) -> String { str("theme.\(mode.rawValue).accent") }
    public func themeBackground(_ mode: ThemeMode) -> String { str("theme.\(mode.rawValue).background") }
    public func themeForeground(_ mode: ThemeMode) -> String { str("theme.\(mode.rawValue).foreground") }
    public func themeHeadingColor(_ mode: ThemeMode) -> String { str("theme.\(mode.rawValue).heading-color") }
    public func themeTranslucent(_ mode: ThemeMode) -> Double { num("theme.\(mode.rawValue).translucent") }
    public func themeContrast(_ mode: ThemeMode) -> Double { num("theme.\(mode.rawValue).contrast") }
    // Files
    public var filesAssociations: [String] { list("files.associations") }
    public var filesDefaultEncoding: String { str("files.default-encoding") }
    public var filesInsertFinalNewline: Bool { bool("files.insert-final-newline") }
    public var filesTrimTrailingWhitespace: Bool { bool("files.trim-trailing-whitespace") }
    // Workspace / window
    public var workspaceRestoreOpenFiles: Bool { bool("workspace.restore-open-files") }
    public var workspaceMaxRecentWorkspaces: Double { num("workspace.max-recent-workspaces") }
    public var windowRestoreWorkspace: Bool { bool("window.restore-workspace") }
    // Search
    public var searchDebounceMs: Double { num("search.debounce-ms") }
    public var searchMaxResults: Double { num("search.max-results") }

    /// `toggleTheme`: system → light → dark → system.
    public static func nextTheme(after current: ThemePreference) -> ThemePreference {
        switch current {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

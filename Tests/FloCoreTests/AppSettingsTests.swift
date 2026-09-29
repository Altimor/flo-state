import XCTest
@testable import FloCore

final class AppConfigFileTests: XCTestCase {
    // Ports of config.rs tests.
    func testParseSimple() {
        let r = ConfigFile.parse("key = value\nnumber = 42\nbool = true\n")
        XCTAssertEqual(r["key"], .string("value"))
        XCTAssertEqual(r["number"], .number(42))
        XCTAssertEqual(r["bool"], .bool(true))
    }

    func testParseCommentsAndBlanks() {
        let r = ConfigFile.parse("# comment\n\nkey = value\n# another comment\n")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r["key"], .string("value"))
    }

    func testParseDottedKeys() {
        let r = ConfigFile.parse("editor.font-size = 16\nappearance.theme = dark\n")
        XCTAssertEqual(r["editor.font-size"], .number(16))
        XCTAssertEqual(r["appearance.theme"], .string("dark"))
    }

    func testParseListValues() {
        let r = ConfigFile.parse("files.exclude = node_modules\nfiles.exclude = .DS_Store\nfiles.exclude = dist\n")
        XCTAssertEqual(r["files.exclude"], .list(["node_modules", ".DS_Store", "dist"]))
    }

    func testSerializePreservesComments() {
        let original = "# My settings\ntheme = dark\n\n# Font settings\nfont-size = 14\n"
        let out = ConfigFile.serialize(["theme": .string("light"), "font-size": .number(16)], original: original)
        XCTAssertEqual(out, "# My settings\ntheme = light\n\n# Font settings\nfont-size = 16\n")
    }

    func testSerializeAppendsNewKeys() {
        let out = ConfigFile.serialize(["theme": .string("dark"), "font-size": .number(14)], original: "theme = dark\n")
        XCTAssertEqual(out, "theme = dark\nfont-size = 14\n")
    }

    func testRemoveKey() {
        let out = ConfigFile.removeKey("font-size", from: "theme = dark\nfont-size = 14\nline-height = 1.6\n")
        XCTAssertEqual(out, "theme = dark\nline-height = 1.6\n")
    }

    func testRoundtrip() {
        let input = "editor.font-size = 16\nappearance.theme = system\n"
        let parsed = ConfigFile.parse(input)
        XCTAssertEqual(ConfigFile.parse(ConfigFile.serialize(parsed, original: input)), parsed)
    }

    func testValueWithEqualsSign() {
        XCTAssertEqual(ConfigFile.parse("template = title: My Title\n")["template"], .string("title: My Title"))
        XCTAssertEqual(ConfigFile.parse("a = b = c\n")["a"], .string("b = c"))
    }

    func testParseFalseAndFloat() {
        XCTAssertEqual(ConfigFile.parse("editor.spell-check = false\n")["editor.spell-check"], .bool(false))
        XCTAssertEqual(ConfigFile.parse("editor.line-height = 1.6\n")["editor.line-height"], .number(1.6))
    }

    // Extra semantics of the Rust parser.
    func testNoQuotingValuesAreVerbatim() {
        let r = ConfigFile.parse(#"fonts.ui = "SF Pro", -apple-system"# + "\nx = 'single'\ncolor = #0433FF\n")
        XCTAssertEqual(r["fonts.ui"], .string(#""SF Pro", -apple-system"#))
        XCTAssertEqual(r["x"], .string("'single'"))
        XCTAssertEqual(r["color"], .string("#0433FF"), "a # mid-line is not a comment")
    }

    func testBooleanCaseInsensitiveAndNumberGrammar() {
        let r = ConfigFile.parse("a = TRUE\nb = False\nc = 1e3\nd = .5\ne = 5.\nf = inf\ng = NaN\nh = 0x10\ni = +3\nj = 1_000\nk = -0.25\n")
        XCTAssertEqual(r["a"], .bool(true))
        XCTAssertEqual(r["b"], .bool(false))
        XCTAssertEqual(r["c"], .number(1000))
        XCTAssertEqual(r["d"], .number(0.5))
        XCTAssertEqual(r["e"], .number(5))
        XCTAssertEqual(r["f"], .string("inf"), "non-finite numbers stay strings")
        XCTAssertEqual(r["g"], .string("NaN"))
        XCTAssertEqual(r["h"], .string("0x10"), "no hex floats in Rust's f64 parser")
        XCTAssertEqual(r["i"], .number(3))
        XCTAssertEqual(r["j"], .string("1_000"))
        XCTAssertEqual(r["k"], .number(-0.25))
    }

    func testLinesWithoutEqualsAndBlankKeys() {
        let r = ConfigFile.parse("garbage line\n = orphan\nk=v\n  spaced  =  value with spaces  \n\r\nw = x\r\n")
        XCTAssertEqual(r[""], .string("orphan"))
        XCTAssertEqual(r["k"], .string("v"))
        XCTAssertEqual(r["spaced"], .string("value with spaces"))
        XCTAssertEqual(r["w"], .string("x"))
        XCTAssertNil(r["garbage line"])
    }

    func testRepeatedKeysKeepRawFirstValue() {
        // The first occurrence was parsed as a number; converting to a list re-renders it.
        let r = ConfigFile.parse("n = 1.50\nn = x\nb = TRUE\nb = y\n")
        XCTAssertEqual(r["n"], .list(["1.5", "x"]))
        XCTAssertEqual(r["b"], .list(["true", "y"]))
    }

    func testSerializeListsAndDuplicates() {
        let original = "# head\nfiles.associations = *.md\nother = 1\nfiles.associations = *.mdx\nbad line\n"
        let values: [String: ConfigValue] = ["files.associations": .list(["*.md", "*.txt", "*.csv"]), "other": .number(2)]
        XCTAssertEqual(ConfigFile.serialize(values, original: original),
                       "# head\nfiles.associations = *.md\nfiles.associations = *.txt\nfiles.associations = *.csv\nother = 2\nbad line\n")
    }

    func testSerializeDropsRemovedKeysAndFormatsNumbers() {
        let out = ConfigFile.serialize(["b": .number(1.5), "c": .number(-3), "d": .number(1e21), "e": .number(1e-7)], original: "a = 1\nb = 2\n")
        XCTAssertEqual(out, "b = 1.5\nc = -3\nd = 1000000000000000000000\ne = 0.0000001\n")
    }

    func testFormatNumber() {
        XCTAssertEqual(ConfigFile.formatNumber(16), "16")
        XCTAssertEqual(ConfigFile.formatNumber(1.5), "1.5")
        XCTAssertEqual(ConfigFile.formatNumber(0.1), "0.1")
        XCTAssertEqual(ConfigFile.formatNumber(-0.0), "0")
        XCTAssertEqual(ConfigFile.formatNumber(123456.789), "123456.789")
        XCTAssertEqual(ConfigFile.formatNumber(2.5e-5), "0.000025")
    }
}

final class AppSettingsLayerTests: XCTestCase {
    var dir: String!
    override func setUp() { dir = AppTestFS.makeTempDir("settings") }
    override func tearDown() { AppTestFS.remove(dir) }

    var dirURL: URL { URL(fileURLWithPath: dir) }

    func testMergeOrder() throws {
        let s = AppSettings(globalConfigDir: dirURL)
        XCTAssertEqual(s.get("editor.font-size"), .number(16))
        try s.setGlobal("editor.font-size", .number(18))
        XCTAssertEqual(s.get("editor.font-size"), .number(18))
        XCTAssertEqual(AppTestFS.read(dir + "/config"), "editor.font-size = 18\n")
    }

    func testWorkspaceOverride() throws {
        let ws = AppTestFS.makeTempDir("ws")
        defer { AppTestFS.remove(ws) }
        let s = AppSettings(globalConfigDir: dirURL)
        try s.setGlobal("editor.font-size", .number(18))
        s.loadWorkspace(root: URL(fileURLWithPath: ws))
        try s.setWorkspace("editor.font-size", .number(20))
        XCTAssertEqual(s.get("editor.font-size"), .number(20))
        XCTAssertEqual(AppTestFS.read(ws + "/.writer/config"), "editor.font-size = 20\n")
        s.clearWorkspace()
        XCTAssertEqual(s.get("editor.font-size"), .number(18))
        XCTAssertThrowsError(try s.setWorkspace("x", .bool(true))) { XCTAssertEqual($0 as? SettingsError, .noWorkspaceConfigPath) }
    }

    func testReset() throws {
        let s = AppSettings(globalConfigDir: dirURL)
        try s.setGlobal("editor.font-size", .number(18))
        try s.resetGlobal("editor.font-size")
        XCTAssertEqual(s.get("editor.font-size"), .number(16))
        XCTAssertEqual(AppTestFS.read(dir + "/config"), "")
    }

    func testThemeFontMigration() {
        AppTestFS.write(dir + "/config", "theme.light.editor-font = Georgia, serif\ntheme.dark.editor-font = Iowan Old Style, serif\ntheme.dark.mono-font = Fira Code, monospace\n")
        let s = AppSettings(globalConfigDir: dirURL)
        XCTAssertEqual(s.get("fonts.editor"), .string("Georgia, serif"))
        XCTAssertEqual(s.get("fonts.mono"), .string("Fira Code, monospace"))
        XCTAssertEqual(s.get("fonts.ui"), s.defaults["fonts.ui"])
        let raw = AppTestFS.read(dir + "/config")!
        XCTAssertFalse(raw.contains("theme.light.editor-font"))
        XCTAssertFalse(raw.contains("theme.dark.editor-font"))
        XCTAssertFalse(raw.contains("theme.dark.mono-font"))
        XCTAssertNil(s.get("theme.light.editor-font"))

        AppTestFS.write(dir + "/config", "fonts.editor = Palatino, serif\ntheme.light.editor-font = Georgia, serif\n")
        let s2 = AppSettings(globalConfigDir: dirURL)
        XCTAssertEqual(s2.get("fonts.editor"), .string("Palatino, serif"))
        XCTAssertEqual(AppTestFS.read(dir + "/config"), "fonts.editor = Palatino, serif\n")
    }

    func testPreferencesJsonMigration() {
        AppTestFS.write(dir + "/preferences.json", #"{"theme":"dark"}"#)
        let s = AppSettings(globalConfigDir: dirURL)
        XCTAssertEqual(s.get("appearance.theme"), .string("dark"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/preferences.json"))

        AppTestFS.write(dir + "/preferences.json", #"{"theme":"light"}"#)
        let s2 = AppSettings(globalConfigDir: dirURL)
        XCTAssertEqual(s2.get("appearance.theme"), .string("dark"), "existing config wins")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/preferences.json"))
    }

    func testSetPreservesCommentsInFile() throws {
        AppTestFS.write(dir + "/config", "# mine\nappearance.theme = dark\n\nfiles.associations = *.md\nfiles.associations = *.txt\n")
        let s = AppSettings(globalConfigDir: dirURL)
        try s.setGlobal("appearance.theme", .string("light"))
        XCTAssertEqual(AppTestFS.read(dir + "/config"), "# mine\nappearance.theme = light\n\nfiles.associations = *.md\nfiles.associations = *.txt\n")
        XCTAssertEqual(s.supportedExtensions.extensions, ["md", "txt"])
    }

    func testReloadAndMerged() throws {
        let s = AppSettings(globalConfigDir: dirURL)
        AppTestFS.write(dir + "/config", "search.max-results = 7\n")
        s.reloadGlobal()
        XCTAssertEqual(s.merged()["search.max-results"], .number(7))
        XCTAssertEqual(s.merged()["search.debounce-ms"], .number(150))
        XCTAssertEqual(s.values.searchMaxResults, 7)
    }

    func testSingleAssociationLineFallsBackToDefaults() {
        // One line parses as a string, not a list: the Rust sync falls back.
        AppTestFS.write(dir + "/config", "files.associations = *.rs\n")
        let s = AppSettings(globalConfigDir: dirURL)
        XCTAssertEqual(s.supportedExtensions, SupportedExtensions.default)
        XCTAssertEqual(s.values.filesAssociations, ["*.rs"])
    }

    func testJsonConversion() {
        XCTAssertEqual(ConfigValue(json: .array([.string("a"), .int(1), .string("b")])), .list(["a", "b"]))
        XCTAssertEqual(ConfigValue(json: .int(3)), .number(3))
        XCTAssertNil(ConfigValue(json: .null))
        XCTAssertEqual(ConfigValue.list(["x"]).json, .array([.string("x")]))
    }
}

final class AppSettingsSchemaTests: XCTestCase {
    func testSchemaLoadsAllKeysWithDefaults() {
        let d = SettingsSchema.defaults
        XCTAssertEqual(SettingsSchema.all.count, 50)
        XCTAssertEqual(d["editor.font-size"], .number(16))
        XCTAssertEqual(d["editor.line-height"], .number(1.5))
        XCTAssertEqual(d["editor.subheading-color"], .string("#3a3a3a"))
        XCTAssertEqual(d["appearance.theme"], .string("system"))
        XCTAssertEqual(d["files.associations"], .list(["*.md", "*.mdx", "*.markdown", "*.csv"]))
        XCTAssertEqual(d["files.insert-final-newline"], .bool(true))
        XCTAssertEqual(d["files.trim-trailing-whitespace"], .bool(false))
        XCTAssertEqual(d["theme.light.preset"], .string("Writer"))
        XCTAssertEqual(SettingsSchema.def("appearance.theme")?.options, ["system", "light", "dark"])
        XCTAssertEqual(SettingsSchema.def("editor.font-size")?.cssVar, "--writer-editor-font-size")
        XCTAssertEqual(SettingsSchema.def("editor.font-size")?.cssFormat, "px")
        XCTAssertEqual(SettingsSchema.def("theme.dark.contrast")?.type, .range)
        XCTAssertEqual(SettingsSchema.def("theme.dark.contrast")?.max, 100)
    }

    // settings-schema.test.ts
    func testTypographyDefaults() {
        let v = SettingsValues([:])
        XCTAssertTrue(v.fontsUI.hasPrefix("\"SF Pro\""))
        XCTAssertTrue(v.fontsEditor.hasPrefix("\"SF Pro\""))
        XCTAssertTrue(v.fontsMono.hasPrefix("\"SF Mono\""))
        XCTAssertEqual(SettingsSchema.def("fonts.ui")?.cssVar, "--ui-font")
        XCTAssertEqual(SettingsSchema.def("fonts.mono")?.cssVar, "--mono-font")
    }

    func testPrimaryDefs() {
        XCTAssertEqual(SettingsSchema.primaryDefs(.dark).map { $0.key },
                       ["theme.dark.accent", "theme.dark.background", "theme.dark.foreground", "theme.dark.heading-color", "theme.dark.translucent", "theme.dark.contrast"])
    }

    func testTypedAccessorsDefaultsAndFallbacks() {
        let v = SettingsValues(SettingsSchema.defaults)
        XCTAssertEqual(v.editorFontSize, 16)
        XCTAssertEqual(v.editorHeadingSpaceAfter, 8)
        XCTAssertEqual(v.editorBulletSpacing, 12)
        XCTAssertTrue(v.editorShowOutline)
        XCTAssertEqual(v.editorJumpToBottomAfterMinutes, 10)
        XCTAssertFalse(v.statusbarShowWords)
        XCTAssertEqual(v.appearanceTheme, .system)
        XCTAssertEqual(v.appearanceSidebarWidth, 240)
        XCTAssertEqual(v.appearanceSidebarFileLabel, .title)
        XCTAssertEqual(v.appearanceEditorWidth, .full)
        XCTAssertEqual(v.themeAccent(.light), "#FF6A00")
        XCTAssertEqual(v.themeBackground(.dark), "#111111")
        XCTAssertEqual(v.themeTranslucent(.dark), 20)
        XCTAssertEqual(v.filesDefaultEncoding, "utf-8")
        XCTAssertTrue(v.workspaceRestoreOpenFiles)
        XCTAssertEqual(v.workspaceMaxRecentWorkspaces, 10)
        XCTAssertTrue(v.windowRestoreWorkspace)
        XCTAssertEqual(v.searchDebounceMs, 150)
        // Wrong types fall back to the schema default.
        let bad = SettingsValues(["editor.font-size": .string("big"), "appearance.theme": .string("sepia")])
        XCTAssertEqual(bad.editorFontSize, 16)
        XCTAssertEqual(bad.appearanceTheme, .system)
    }

    func testThemeCycle() {
        XCTAssertEqual(SettingsValues.nextTheme(after: .system), .light)
        XCTAssertEqual(SettingsValues.nextTheme(after: .light), .dark)
        XCTAssertEqual(SettingsValues.nextTheme(after: .dark), .system)
    }

    func testCssVarBindings() {
        let b = SettingsSchema.cssVarBindings(SettingsSchema.defaults)
        let dict = Dictionary(uniqueKeysWithValues: b)
        XCTAssertEqual(dict["--writer-editor-font-size"], "16px")
        XCTAssertEqual(dict["--writer-editor-line-height"], "1.5")
        XCTAssertEqual(dict["--writer-heading-space-after"], "8px")
        XCTAssertNil(dict["--accent"], "theme keys are handled per mode")
    }
}

final class AppThemeTests: XCTestCase {
    func testPresetsDiscovered() {
        let names = ThemePreset.all.map { $0.name }
        XCTAssertEqual(names, ["Default", "High Contrast", "Warm Paper", "Writer"])
        let writer = ThemePreset.named("Writer")!
        XCTAssertEqual(writer.light, ThemePrimaries(accent: "#FF6A00", background: "#FFFFFF", foreground: "#0D0D0D", headingColor: "#191919", translucent: 10, contrast: 20))
        XCTAssertEqual(writer.dark.contrast, 16)
    }

    func testEveryPresetDefinesEveryPrimary() {
        for preset in ThemePreset.all {
            for mode in ThemeMode.allCases {
                let keys = preset.primaries(mode).settings(for: mode).map { $0.0 }
                XCTAssertEqual(keys, SettingsSchema.primaryDefs(mode).map { $0.key })
            }
        }
    }

    func testSchemaDefaultsMatchWriterPreset() {
        XCTAssertEqual(ThemeResolver.matchingPreset(SettingsValues([:]), mode: .light)?.name, "Writer")
        XCTAssertEqual(ThemeResolver.matchingPreset(SettingsValues([:]), mode: .dark)?.name, "Writer")
        XCTAssertNil(ThemeResolver.matchingPreset(SettingsValues(["theme.dark.accent": .string("#000000")]), mode: .dark))
    }

    func testDerivedMath() {
        XCTAssertEqual(ThemeTokens.bgOpacity(translucent: 0), 1)
        XCTAssertEqual(ThemeTokens.bgOpacity(translucent: 100), 0.05, accuracy: 1e-12)
        XCTAssertEqual(ThemeTokens.bgOpacity(translucent: 20), 0.81, accuracy: 1e-12)
        XCTAssertEqual(ThemeTokens.bgOpacity(translucent: 250), 0.05, accuracy: 1e-12)
        XCTAssertEqual(ThemeTokens.bgOpacity(translucent: .nan), 1)
        XCTAssertEqual(ThemeTokens.contrast(slider: 0), 0.2, accuracy: 1e-12)
        XCTAssertEqual(ThemeTokens.contrast(slider: 100), 1.0, accuracy: 1e-12)
        XCTAssertEqual(ThemeTokens.contrast(slider: 16), 0.328, accuracy: 1e-12)
        XCTAssertEqual(ThemeTokens.contrast(slider: -5), 0.2, accuracy: 1e-12)
    }

    func testTokensDarkDefaults() {
        let t = ThemeTokens(settings: SettingsValues([:]), mode: .dark)
        XCTAssertEqual(t.bgBase, RGBA(hex: "#111111"))
        XCTAssertEqual(t.bgOpacity, 0.81, accuracy: 1e-12)
        XCTAssertEqual(t.contrast, 0.328, accuracy: 1e-12)
        XCTAssertEqual(t.bg.a, 0.81, accuracy: 1e-12)
        XCTAssertEqual(t.textSecondary.a, 0.8, accuracy: 1e-12)
        XCTAssertEqual(t.textMuted.a, 0.54, accuracy: 1e-12)
        XCTAssertEqual(t.borderColor.a, 0.328 * 0.24, accuracy: 1e-12)
        XCTAssertEqual(t.sidebarFloatBg.a, 0.328 * 0.07, accuracy: 1e-12)
        XCTAssertEqual(t.sidebarFloatBorder.a, 0.328 * 0.18, accuracy: 1e-12)
        XCTAssertEqual(t.tabActiveBg.a, 0.328 * 0.34, accuracy: 1e-12, "dark bumps the active tab")
        XCTAssertEqual(t.surfaceInput.a, 0.328 * 0.28, accuracy: 1e-12)
        XCTAssertEqual(t.surfaceCard.a, 0.328 * 0.16, accuracy: 1e-12)
        XCTAssertEqual(t.editorSelectionBg, RGBA(hex: "#FF6A00")!.mixedWithTransparent(0.3))
        XCTAssertEqual(t.fgBase, RGBA(hex: "#FCFCFC"))
    }

    func testTokensLightOverrides() {
        let t = ThemeTokens(settings: SettingsValues([:]), mode: .light)
        XCTAssertEqual(t.contrast, 0.36, accuracy: 1e-12)
        XCTAssertEqual(t.surfaceCard, .transparent)
        XCTAssertEqual(t.surfaceInput.a, 0.36 * 0.20, accuracy: 1e-12)
        XCTAssertEqual(t.tabActiveBg.a, 0.36 * 0.24, accuracy: 1e-12)
        XCTAssertEqual(t.bgOpacity, 1 - 0.1 * 0.95, accuracy: 1e-12)
    }

    func testHexParsingAndFallback() {
        XCTAssertEqual(RGBA(hex: "#fff"), RGBA(r: 1, g: 1, b: 1))
        XCTAssertEqual(RGBA(hex: "#00000080")!.a, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(RGBA(hex: "red"))
        XCTAssertEqual(RGBA(hex: "#FF6A00")!.hexString, "#FF6A00")
        let t = ThemeTokens(settings: SettingsValues(["theme.dark.accent": .string("nope")]), mode: .dark)
        XCTAssertEqual(t.accent, RGBA(hex: "#FF6A00"))
    }

    func testActiveMode() {
        XCTAssertEqual(ThemeResolver.activeMode(.system, systemIsDark: true), .dark)
        XCTAssertEqual(ThemeResolver.activeMode(.system, systemIsDark: false), .light)
        XCTAssertEqual(ThemeResolver.activeMode(.light, systemIsDark: true), .light)
    }
}

final class AppDataDirectoryTests: XCTestCase {
    func testFirstRunImportsLegacyFiles() throws {
        let root = AppTestFS.makeTempDir("appdata")
        defer { AppTestFS.remove(root) }
        let legacy = root + "/com.writer-computer"
        AppTestFS.write(legacy + "/config", "appearance.theme = dark\n")
        AppTestFS.write(legacy + "/sessions.json", "{}")
        AppTestFS.write(legacy + "/recent_files.json", "[]")
        AppTestFS.write(legacy + "/updater-dismissed-version.json", "\"1\"")
        let dir = AppDataDirectory(baseURL: URL(fileURLWithPath: root + "/FloStateNative"))
        let imported = try dir.prepare(importingFrom: URL(fileURLWithPath: legacy))
        XCTAssertEqual(imported, ["config", "sessions.json", "recent_files.json"])
        XCTAssertEqual(AppTestFS.read(dir.configURL.path), "appearance.theme = dark\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.baseURL.appendingPathComponent("updater-dismissed-version.json").path))

        // Second run: directory exists, nothing re-imported.
        AppTestFS.write(legacy + "/recent_workspaces.json", "[]")
        XCTAssertEqual(try dir.prepare(importingFrom: URL(fileURLWithPath: legacy)), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.recentWorkspacesURL.path))
    }

    func testFirstRunWithoutLegacy() throws {
        let root = AppTestFS.makeTempDir("appdata2")
        defer { AppTestFS.remove(root) }
        let dir = AppDataDirectory(baseURL: URL(fileURLWithPath: root + "/New"))
        XCTAssertEqual(try dir.prepare(importingFrom: URL(fileURLWithPath: root + "/missing")), [])
        XCTAssertTrue(WorkspaceFS.isDirectory(dir.baseURL.path))
    }

    func testDefaultLocations() {
        XCTAssertTrue(AppDataDirectory.defaultBaseURL.path.hasSuffix("Library/Application Support/FloStateNative"))
        XCTAssertTrue(AppDataDirectory.legacyBaseURL.path.hasSuffix("Library/Application Support/com.writer-computer"))
    }
}

import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// The native Settings window, offscreen (never ordered front).
@MainActor
final class SettingsWindowTests: XCTestCase {
    var data: String!
    var backend: SettingsBackend!
    var wc: SettingsWindowController!
    var changes = 0

    override func setUp() async throws {
        data = TFS.tempDir("settings")
        TFS.write(data + "/config", "editor.font-size = 18\n")
        backend = SettingsBackend(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        backend.onChange = { [unowned self] in self.changes += 1 }
        wc = SettingsWindowController(backend: backend)
        wc.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    }

    override func tearDown() async throws { wc.window?.close() }

    var config: String { TFS.read(data + "/config") ?? "" }

    func pane(_ id: String) -> SettingsPaneController {
        wc.select(id)
        let p = wc.selectedPane
        _ = p.view
        return p
    }

    func testWindowShapeToolbarAndTitles() {
        let w = wc.window!
        XCTAssertFalse(w.styleMask.contains(.resizable))
        XCTAssertTrue(w.styleMask.contains(.titled) && w.styleMask.contains(.closable))
        XCTAssertEqual(w.toolbarStyle, .preference)
        XCTAssertEqual(w.toolbar?.items.map { $0.label }, ["General", "Editor", "Appearance", "Theme", "Files", "Advanced"])
        XCTAssertNil(w.appearance, "follows the system light/dark")
        for p in SettingsPanes.all {
            wc.select(p.id)
            XCTAssertEqual(w.title, p.title)
        }
    }

    func testWindowFitsEachPane() {
        var heights: [CGFloat] = []
        for p in SettingsPanes.all {
            let vc = pane(p.id)
            wc.resizeToPane(animate: false)
            XCTAssertEqual(wc.window!.contentView!.frame.height, vc.preferredContentSize.height, accuracy: 1, p.id)
            heights.append(vc.preferredContentSize.height)
            XCTAssertLessThan(vc.preferredContentSize.height, 700, "\(p.id) fits a laptop screen")
        }
        XCTAssertGreaterThan(Set(heights).count, 3, "panes resize the window")
    }

    func testEverySettingHasANativeControl() {
        var seen: [String] = []
        for p in SettingsPanes.all {
            let vc = pane(p.id)
            for c in vc.controls {
                seen.append(c.def.key)
                switch c.def.type {
                case .boolean: XCTAssertNotNil(c.checkbox, c.def.key)
                case .enum, .font: XCTAssertNotNil(c.popup, c.def.key)
                case .number: XCTAssertNotNil(c.stepper, c.def.key); XCTAssertNotNil(c.field)
                case .color: XCTAssertNotNil(c.well, c.def.key)
                case .range: XCTAssertNotNil(c.slider, c.def.key)
                case .list: XCTAssertNotNil(c.tokens, c.def.key)
                case .string: XCTAssertTrue(c.field != nil || c.popup != nil, c.def.key)
                }
            }
        }
        XCTAssertEqual(Set(seen), Set(SettingsSchema.all.map { $0.key }))
    }

    func testCheckboxWritesConfigAndBroadcasts() {
        let c = pane("general").control("statusbar.show-words")!
        XCTAssertEqual(c.checkbox?.state, .off)
        c.checkbox!.state = .on
        c.changed(c.checkbox)
        XCTAssertTrue(config.contains("statusbar.show-words = true"))
        XCTAssertEqual(changes, 1)
    }

    func testStepperAndFieldForNumbers() {
        let c = pane("editor").control("editor.font-size")!
        XCTAssertEqual(c.field?.doubleValue, 18, "reads the existing config")
        XCTAssertEqual(c.stepper?.maxValue, 32)
        c.stepper!.doubleValue = 19
        c.stepped(c.stepper!)
        XCTAssertEqual(c.field?.doubleValue, 19)
        XCTAssertTrue(config.contains("editor.font-size = 19"))
        c.field!.stringValue = "21"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.field))
        XCTAssertTrue(config.contains("editor.font-size = 21"))
    }

    func testPopupsColorWellsSlidersAndTokens() {
        let theme = pane("general").control("appearance.theme")!
        XCTAssertEqual(theme.popup?.itemTitles, ["Match System", "Light", "Dark"])
        theme.popup!.selectItem(at: 2)
        theme.changed(theme.popup)
        XCTAssertTrue(config.contains("appearance.theme = dark"))

        let t = pane("theme")
        let accent = t.control("theme.light.accent")!
        accent.well!.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        accent.changed(accent.well)
        XCTAssertTrue(config.contains("theme.light.accent = #FF0000"))
        XCTAssertEqual(t.control("theme.light.preset")!.popup?.titleOfSelectedItem, "Custom", "no preset matches now")
        let slider = t.control("theme.dark.translucent")!
        slider.slider!.doubleValue = 42.4
        slider.changed(slider.slider)
        XCTAssertTrue(config.contains("theme.dark.translucent = 42"))
        XCTAssertEqual(slider.sliderValue?.stringValue, "42")

        let files = pane("files").control("files.associations")!
        files.tokens!.objectValue = ["*.md", "*.txt"]
        files.commitTokens()
        XCTAssertTrue(config.contains("files.associations = *.md\nfiles.associations = *.txt"))

        let font = pane("appearance").control("fonts.editor")!
        font.popup!.selectItem(withTitle: "Menlo")
        font.changed(font.popup)
        XCTAssertTrue(config.contains("fonts.editor = Menlo, -apple-system-body"), config)
    }

    func testPresetAppliesPrimaries() {
        let t = pane("theme")
        let preset = t.control("theme.dark.preset")!
        guard let other = ThemePreset.all.first(where: { $0.name != "Writer" }) else { return }
        preset.popup!.selectItem(withTitle: other.name)
        preset.changed(preset.popup)
        XCTAssertEqual(backend.values.themeAccent(.dark), other.dark.accent)
        XCTAssertEqual(backend.values.themeContrast(.dark), other.dark.contrast)
        wc.syncAll()
        XCTAssertEqual(preset.popup?.titleOfSelectedItem, other.name)
    }

    func testRestoreDefaultsResetsOnlyThatPane() {
        let editor = pane("editor")
        let general = pane("general")
        general.control("statusbar.show-words")!.checkbox!.state = .on
        general.control("statusbar.show-words")!.changed(nil)
        editor.restoreDefaults()
        XCTAssertFalse(config.contains("editor.font-size"))
        XCTAssertTrue(config.contains("statusbar.show-words = true"))
        XCTAssertEqual(editor.control("editor.font-size")?.field?.doubleValue, 16)
    }

    func testExternalChangesSync() {
        let c = pane("appearance").control("appearance.sidebar-visible")!
        XCTAssertEqual(c.checkbox?.state, .on)
        TFS.write(data + "/config", "appearance.sidebar-visible = false\n")
        backend.reloadFromDisk()
        wc.syncAll()
        XCTAssertEqual(c.checkbox?.state, .off)
    }
}

/// App-level wiring: one reusable window; changes reach every workspace window.
@MainActor
final class SettingsBroadcastTests: XCTestCase {
    func testSettingsWindowChangesReachOpenWindows() async {
        let f = ShellFixture(files: ["a.md": ""])
        await f.open()
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [])
        let backend = SettingsBackend(dataDir: f.model.dataDir)
        let wc = SettingsWindowController(backend: backend)
        backend.onChange = { app.settingsChanged(from: nil) }
        app.adopt(model: f.model)
        let c = wc.panes.first { $0.pane.id == "editor" }!
        _ = c.view
        c.control("editor.font-size")!.stepper!.doubleValue = 20
        c.control("editor.font-size")!.stepped(c.control("editor.font-size")!.stepper!)
        XCTAssertEqual(f.model.values.editorFontSize, 20, "open windows pick it up live")
        wc.window?.close()
    }
}

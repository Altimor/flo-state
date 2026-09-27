import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

/// UI localization: every table has every key with matching format specifiers,
/// every UI string the code looks up is in the English table, and long / CJK /
/// RTL languages lay out without clipping (offscreen).
@MainActor
final class LocalizationTests: XCTestCase {
    static let sourcesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    override func tearDown() async throws { L10n.bundle = FloResources.bundle }

    func table(_ lang: String) -> [String: String] {
        guard let b = L10n.languageBundle(lang), let url = b.url(forResource: "Localizable", withExtension: "strings"),
              let d = NSDictionary(contentsOf: url) as? [String: String] else { XCTFail("no table for \(lang)"); return [:] }
        return d
    }

    /// Specifiers as a sorted multiset, positions dropped ("%1$@" → "%@").
    static func specifiers(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "%(?:\\d\\$)?[@dld]")
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map {
            (s as NSString).substring(with: $0.range).replacingOccurrences(of: "\\d\\$", with: "", options: .regularExpression)
        }.sorted()
    }

    func testEveryLanguageHasEveryKeyWithMatchingSpecifiers() {
        let en = table("en")
        XCTAssertGreaterThan(en.count, 250)
        XCTAssertEqual(L10n.languages.count, 14)  // en + 12 languages + pt-PT
        for lang in L10n.languages where lang != "en" {
            let t = table(lang)
            XCTAssertEqual(Set(t.keys).subtracting(en.keys), [], "\(lang): keys not in English")
            for (k, v) in en {
                guard let tv = t[k] else { XCTFail("\(lang): missing \"\(k)\""); continue }
                XCTAssertFalse(tv.trimmingCharacters(in: .whitespaces).isEmpty, "\(lang): empty \"\(k)\"")
                XCTAssertEqual(Self.specifiers(tv), Self.specifiers(v), "\(lang): specifiers of \"\(k)\"")
            }
            XCTAssertTrue(t["Welcome.md"]?.hasSuffix(".md") == true, lang)
            XCTAssertFalse(t["Welcome.md"]!.contains("/") || t["Notebook"]!.contains("/") || t["Untitled"]!.contains("/"), lang)
        }
    }

    /// Every `L("…")` literal in the sources, and every key the UI localizes at display time.
    func testEveryLookedUpStringIsInTheEnglishTable() throws {
        let en = table("en")
        var missing: [String] = []
        func check(_ k: String, _ where_: String) { if en[k] == nil { missing.append("\(where_): \(k)") } }
        let lit = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        let files = FileManager.default.enumerator(at: Self.sourcesDir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            for m in lit.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
                let raw = (src as NSString).substring(with: m.range(at: 1))
                check(raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\"), f.lastPathComponent)
            }
        }
        for e in MainMenu.fileEntries + MainMenu.viewEntries + MainMenu.tabEntries { if let e = e { check(e.title, "menu") } }
        for t in ["File", "Edit", "View", "Window", MainMenu.checkForUpdatesTitle, FloStateCLI.installLabel, FloStateCLI.uninstallLabel] { check(t, "menu") }
        for s in [SidebarItem.Section.pinned, .recents] { check(s.rawValue, "sidebar") }
        for t in WelcomeView.titles { check(t, "welcome") }
        for p in SettingsPanes.all {
            check(p.title, "settings pane")
            for g in p.groups { if let h = g.0 { check(h, "settings group") } }
        }
        for key in SettingsPanes.allKeys {
            guard let def = SettingsSchema.def(key) else { continue }
            check(SettingControl.displayLabel(def), "settings label \(key)")
            if !def.description.isEmpty { check(def.description, "settings description \(key)") }
            for o in def.options ?? [] { check(SettingsPanes.optionTitle(key, o), "settings option \(key)") }
        }
        for t in ThemePreset.all { check(SettingsPanes.presetTitle(t.name), "theme preset") }
        func walk(_ entries: [EditorMenuSpec.Entry]) {
            for e in entries {
                switch e {
                case let .item(_, t, _): check(t, "editor menu")
                case let .submenu(t, items): check(t, "editor menu"); walk(items)
                case .separator: break
                }
            }
        }
        walk(EditorFeatures.menuSpec(hasLink: true).entries)
        for t in ["Small", "Medium", "Large", "Full Width", "Original Size"] { check(t, "image menu") }
        let f = ShellFixture(files: ["a.md": "# A"])
        await_(f)
        for it in f.model.paletteCommands() { check(it.title, "palette"); check(it.subtitle ?? "", "palette") }
        XCTAssertEqual(missing, [])
    }

    private func await_(_ f: ShellFixture) {
        let e = expectation(description: "open")
        Task { await f.open(); e.fulfill() }
        wait(for: [e], timeout: 10)
    }

    /// English needs no table hits; a missing key falls back to the key.
    func testEnglishFallsBackToKey() {
        L10n.bundle = L10n.languageBundle("en")!
        XCTAssertEqual(L("Open Folder"), "Open Folder")
        XCTAssertEqual(L("no such key \u{1F600}"), "no such key \u{1F600}")
        XCTAssertEqual(L("Copy %d relative paths", 3), "Copy 3 relative paths")
        XCTAssertEqual(StarterNotebook.localizedWelcome, StarterNotebook.welcome)
    }

    func testFrenchLookupsAndFormats() {
        L10n.bundle = L10n.languageBundle("fr")!
        XCTAssertNotEqual(L("Open Folder"), "Open Folder")
        XCTAssertTrue(L("Copy %d relative paths", 3).contains("3"))
        XCTAssertTrue(L("Failed to delete \"%1$@\": %2$@", "x.md", "boom").contains("x.md"))
        XCTAssertTrue(L("Failed to delete \"%1$@\": %2$@", "x.md", "boom").contains("boom"))
    }

    /// Each translated Welcome note keeps the markdown, shortcuts and self-link.
    func testWelcomeNotes() throws {
        let english = StarterNotebook.welcome
        let glyphs = ["⌘K", "⌘O", "⌘⇧F", "⌘N", "⌘T", "⌘\\\\", "⌘⇧D", "⌘⌥←", "⌘⌥→", "⌘,", "⌘+", "⌘−", "[[", "$e^{i\\pi} + 1 = 0$",
                      "```mermaid", "- [ ] ", "- [x] ", "`attachments`", "](https://flocrivello.com/flostate/)", "| --- | --- |"]
        for g in glyphs { XCTAssertTrue(english.contains(g), "english: \(g)") }
        for lang in L10n.languages where lang != "en" {
            let b = try XCTUnwrap(L10n.languageBundle(lang))
            let url = try XCTUnwrap(b.url(forResource: "Welcome", withExtension: "md"), lang)
            let note = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(note.hasPrefix("# ") && note.contains("Flo State"), "\(lang): heading")
            for g in glyphs { XCTAssertTrue(note.contains(g), "\(lang): \(g)") }
            let stem = LinkPaths.getFileStem(table(lang)["Welcome.md"]!)
            XCTAssertTrue(note.contains("[[\(stem)]]"), "\(lang): self-link [[\(stem)]]")
            XCTAssertEqual(note.components(separatedBy: "```").count, english.components(separatedBy: "```").count, lang)
            XCTAssertEqual(note.components(separatedBy: "\n## ").count, english.components(separatedBy: "\n## ").count, "\(lang): sections")
        }
    }

    /// "Start from Scratch" in German: localized folder, note name and content.
    func testStartFromScratchLocalized() async throws {
        L10n.bundle = L10n.languageBundle("de")!
        let docs = URL(fileURLWithPath: TFS.tempDir("docs"))
        let (dir, note) = try StarterNotebook.create(documents: docs)
        XCTAssertEqual((dir as NSString).lastPathComponent, table("de")["Notebook"])
        XCTAssertEqual((note as NSString).lastPathComponent, table("de")["Welcome.md"])
        XCTAssertEqual(TFS.read(note), StarterNotebook.localizedWelcome)
        XCTAssertNotEqual(StarterNotebook.localizedWelcome, StarterNotebook.welcome)
    }

    // MARK: layout (offscreen)

    static var snapshotDir: String? { ProcessInfo.processInfo.environment["FLO_L10N_SNAPSHOT_DIR"] }

    func writePNG(_ v: NSView, _ name: String) {
        guard let dir = Self.snapshotDir else { return }
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
    }

    /// Controls whose content is wider than their frame, or frames outside the content view.
    func clipped(in root: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            let r = v.convert(v.bounds, to: root)
            if v !== root, r.width > 0, r.height > 0,
               r.minX < root.bounds.minX - 0.5 || r.maxX > root.bounds.maxX + 0.5 || r.minY < -0.5 || r.maxY > root.bounds.maxY + 0.5 {
                out.append("outside: \(type(of: v)) \(r)")
            }
            if let c = v as? NSControl, !(v is NSTokenField), !(v is NSSlider), !(v is NSStepper), !(v is NSColorWell) {
                let need = c.intrinsicContentSize.width
                if need != NSView.noIntrinsicMetric, need > c.frame.width + 0.5, !(c is NSTextField && (c as! NSTextField).isEditable) {
                    out.append("clipped: \(type(of: c)) \"\(c.stringValue.isEmpty ? (c as? NSButton)?.title ?? "" : c.stringValue)\" needs \(need) has \(c.frame.width)")
                }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    func testSettingsPanesFitInLongCJKAndRTLLanguages() {
        for lang in ["de", "ru", "ja", "ar", "hi", "fr"] {
            L10n.bundle = L10n.languageBundle(lang)!
            let data = TFS.tempDir("settings-\(lang)")
            TFS.write(data + "/config", "")
            let backend = SettingsBackend(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
            let wc = SettingsWindowController(backend: backend)
            let w = wc.window!
            w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            for p in SettingsPanes.all {
                wc.select(p.id)
                wc.resizeToPane(animate: false)
                let content = w.contentView!
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(w.title, L(p.title))
                XCTAssertEqual(clipped(in: content), [], "\(lang) \(p.id)")
                XCTAssertLessThanOrEqual(w.frame.width, 900, "\(lang) \(p.id): window too wide")
                if ["de", "ja", "ar"].contains(lang) { writePNG(w.contentView!.superview!, "settings-\(p.id)-\(lang)") }
            }
            let labels = w.toolbar!.items.map { $0.label }
            XCTAssertEqual(labels, SettingsPanes.all.map { L($0.title) }, lang)
            w.close()
        }
    }

    func testWelcomeScreenFitsInEveryLanguage() {
        for lang in L10n.languages {
            L10n.bundle = L10n.languageBundle(lang)!
            let f = ShellFixture()
            for width in [1200.0, 720, 480] {
                let wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: width, height: 700), offscreen: true)
                wc.root.opaqueBase = true
                wc.root.layoutSubtreeIfNeeded()
                let v = wc.root.welcome
                XCTAssertFalse(v.isHidden)
                let font = UIFonts.ui(f.model.values, weight: .medium)
                for (t, r) in v.buttons {
                    XCTAssertGreaterThanOrEqual(r.minX, 8, "\(lang) @\(width): \(t)")
                    XCTAssertLessThanOrEqual(r.maxX, v.bounds.width - 8, "\(lang) @\(width): \(t)")
                    XCTAssertLessThanOrEqual(TextStyle(font: font, color: .black).width(t), r.width - 31.5, "\(lang) @\(width): \(t) truncated")
                }
                let rects = v.buttons.map { $0.1 }
                for i in rects.indices { for j in rects.indices where j > i { XCTAssertFalse(rects[i].intersects(rects[j]), "\(lang) @\(width): overlap") } }
                XCTAssertLessThanOrEqual(v.messageLines.count, 4, lang)
                if width == 720, ["de", "ja", "ar", "ru"].contains(lang) {
                    wc.root.display()
                    writePNG(wc.root, "welcome-\(lang)")
                }
                wc.window?.close()
            }
        }
    }
}

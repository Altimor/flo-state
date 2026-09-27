import AppKit
import FloCore

// Native macOS Settings window (replaces the web app's Preferences tab):
// one reusable window, toolbar panes, native controls, live-applied changes
// written to the same global config file.

/// Font-stack helpers (`font-stack.ts`).
enum FontStackEdit {
    static func stripQuotes(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" { return String(s.dropFirst().dropLast()) }
        return s
    }

    static func firstFamily(_ stack: String) -> String {
        stripQuotes((stack.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces))
    }

    static func stackWithFamily(_ family: String, _ current: String) -> String {
        let name = family.trimmingCharacters(in: .whitespaces)
        let plain = name.range(of: "^[A-Za-z][A-Za-z0-9-]*$", options: .regularExpression) != nil
        let quoted = plain ? name : "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
        let tail = current.split(separator: ",", omittingEmptySubsequences: false).dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && stripQuotes($0) != name }
        return ([quoted] + tail).joined(separator: ", ")
    }
}

/// Line wrapping with Chrome-like greedy breaking at the given width.
enum TextWrap {
    static func lines(_ s: String, font: NSFont, width: CGFloat) -> [String] {
        let a = NSAttributedString(string: s, attributes: [.font: font])
        let ts = CTTypesetterCreateWithAttributedString(a)
        var out: [String] = []
        var start = 0
        let ns = s as NSString
        while start < ns.length {
            let n = CTTypesetterSuggestLineBreak(ts, start, Double(width))
            if n <= 0 { break }
            out.append(ns.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespaces))
            start += n
        }
        return out.isEmpty ? [""] : out
    }
}

/// Which settings live on which pane.
enum SettingsPanes {
    struct Pane: Equatable {
        var id: String
        var title: String
        var symbol: String
        /// Groups of keys; each group gets a section label (nil = none).
        var groups: [(String?, [String])]
        static func == (a: Pane, b: Pane) -> Bool { a.id == b.id && a.title == b.title && a.groups.map { $0.1 } == b.groups.map { $0.1 } }
    }

    static let all: [Pane] = [
        Pane(id: "general", title: "General", symbol: "gearshape", groups: [
            ("Appearance", ["appearance.theme"]),
            ("On launch", ["window.restore-workspace", "workspace.restore-open-files"]),
            (nil, ["workspace.max-recent-workspaces"]),
            ("Daily notes", ["editor.auto-insert-daily-heading", "editor.jump-to-bottom-after-minutes"]),
        ]),
        Pane(id: "editor", title: "Editor", symbol: "text.alignleft", groups: [
            ("Text", ["editor.font-size", "editor.line-height", "editor.tab-size", "appearance.editor-width"]),
            ("Spacing", ["editor.heading-space-before", "editor.heading-space-after", "editor.paragraph-spacing", "editor.bullet-spacing"]),
            (nil, ["editor.subheading-color"]),
            ("Headings", ["editor.show-heading-chevrons"]),
            ("Outline", ["editor.show-outline"]),
        ]),
        Pane(id: "appearance", title: "Appearance", symbol: "sidebar.left", groups: [
            ("Sidebar", ["appearance.sidebar-file-label", "appearance.sidebar-show-search", "appearance.sidebar-show-recents"]),
            ("Fonts", ["fonts.editor", "fonts.mono"]),
        ]),
        Pane(id: "theme", title: "Theme", symbol: "paintpalette", groups: [
            ("Light", ["theme.light.preset", "theme.light.accent", "theme.light.background", "theme.light.foreground",
                       "theme.light.heading-color", "theme.light.translucent", "theme.light.contrast"]),
            ("Dark", ["theme.dark.preset", "theme.dark.accent", "theme.dark.background", "theme.dark.foreground",
                      "theme.dark.heading-color", "theme.dark.translucent", "theme.dark.contrast"]),
        ]),
        Pane(id: "files", title: "Files", symbol: "doc", groups: [
            (nil, ["files.associations"]),
        ]),
    ]

    /// Settings that still work (defaults / config file) but aren't shown.
    static let hiddenKeys: Set<String> = [
        "statusbar.show-words", "statusbar.show-characters", "statusbar.show-paragraphs",  // footer right-click menu
        "editor.outline-indent-per-level",
        "appearance.sidebar-visible", "appearance.sidebar-width",  // Cmd-\ and the resize handle
        "fonts.ui",
        "files.default-encoding", "files.insert-final-newline", "files.trim-trailing-whitespace",
        "search.debounce-ms", "search.max-results",
    ]

    /// Theme preset display names ("Writer" is the legacy preset id, kept in config).
    static func presetTitle(_ name: String) -> String { name == "Writer" ? "Flo State" : name }
    static func presetName(_ title: String) -> String { title == "Flo State" ? "Writer" : title }

    static var allKeys: [String] { all.flatMap { $0.groups.flatMap { $0.1 } } }

    /// Menu titles for enum options.
    static func optionTitle(_ key: String, _ option: String) -> String {
        switch (key, option) {
        case ("appearance.theme", "system"): return L("Match System")
        case ("appearance.sidebar-file-label", "title"): return L("Document title")
        case ("appearance.sidebar-file-label", "filename"): return L("File name")
        case ("appearance.editor-width", "full"): return L("Wide")   // not the full window width
        default: return L(option.prefix(1).uppercased() + option.dropFirst())
        }
    }

    static func unit(_ def: SettingDef) -> String? {
        if def.cssFormat == "px" || def.key == "appearance.sidebar-width" || def.key == "editor.outline-indent-per-level" { return L("px") }
        if def.key.hasSuffix("-minutes") { return L("min") }
        if def.key.hasSuffix("-ms") { return L("ms") }
        return nil
    }

    static func stepperRange(_ def: SettingDef) -> (min: Double, max: Double, step: Double) {
        if let lo = def.min, let hi = def.max { return (lo, hi, def.step ?? 1) }
        switch def.key {
        case "editor.line-height": return (1, 3, 0.05)
        case "appearance.sidebar-width": return (220, 420, 1)
        case "search.debounce-ms": return (0, 2000, 10)
        default: return (0, 1000, 1)
        }
    }
}

/// The settings a Settings window edits: global config, broadcast to every
/// open workspace window on change.
@MainActor
final class SettingsBackend {
    let settings: AppSettings
    /// Called after every write (the app delegate reloads every window's settings).
    var onChange: () -> Void = {}
    /// UI refresh after a write (the Settings window re-syncs its controls).
    var refreshUI: () -> Void = {}

    private func changed() { onChange(); refreshUI() }

    init(dataDir: AppDataDirectory) {
        settings = AppSettings(globalConfigDir: dataDir.baseURL)
    }

    var values: SettingsValues { settings.values }
    func value(_ key: String) -> ConfigValue { settings.values.raw[key] ?? SettingsSchema.def(key)?.defaultValue ?? .string("") }

    func set(_ key: String, _ v: ConfigValue) {
        try? settings.setGlobal(key, v)
        changed()
    }

    func reset(_ keys: [String]) {
        for k in keys where settings.global[k] != nil { try? settings.resetGlobal(k) }
        changed()
    }

    /// Choosing a preset writes its name and its six primaries.
    func applyPreset(_ name: String, mode: ThemeMode) {
        guard let p = ThemePreset.named(name) else { return }
        try? settings.setGlobal("theme.\(mode.rawValue).preset", .string(name))
        for (k, v) in p.primaries(mode).settings(for: mode) { try? settings.setGlobal(k, v) }
        changed()
    }

    func reloadFromDisk() { settings.reloadGlobal() }
}

/// One setting's control + label, kept in sync with the backend.
@MainActor
final class SettingControl: NSObject, NSTextFieldDelegate, NSTokenFieldDelegate {
    let def: SettingDef
    unowned let backend: SettingsBackend
    let label: NSTextField
    private(set) var view: NSView = NSView()
    let help: NSTextField?
    private(set) var checkbox: NSButton?
    private(set) var popup: NSPopUpButton?
    private(set) var field: NSTextField?
    private(set) var stepper: NSStepper?
    private(set) var well: NSColorWell?
    private(set) var slider: NSSlider?
    private(set) var sliderValue: NSTextField?
    private(set) var tokens: NSTokenField?
    private var mode: ThemeMode? { def.key.hasPrefix("theme.light.") ? .light : def.key.hasPrefix("theme.dark.") ? .dark : nil }

    init(def: SettingDef, backend: SettingsBackend) {
        self.def = def
        self.backend = backend
        label = NSTextField(labelWithString: def.type == .boolean ? "" : SettingControl.displayLabel(def) + ":")
        label.alignment = .right
        var built: NSView = NSView()
        // Descriptions are tooltips (like native Settings panes); inline help
        // only where the control alone doesn't explain the behaviour.
        help = def.description.isEmpty || !SettingControl.inlineHelp.contains(def.key) ? nil : {
            let h = NSTextField(wrappingLabelWithString: L(def.description))
            h.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            h.textColor = .secondaryLabelColor
            h.preferredMaxLayoutWidth = 300
            return h
        }()
        super.init()
        switch def.type {
        case .boolean:
            let b = NSButton(checkboxWithTitle: SettingControl.displayLabel(def), target: self, action: #selector(changed(_:)))
            checkbox = b; built = b
        case .enum:
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            for o in def.options ?? [] {
                p.addItem(withTitle: SettingsPanes.optionTitle(def.key, o))
                p.lastItem?.representedObject = o
            }
            p.target = self; p.action = #selector(changed(_:))
            popup = p; built = p
        case .font:
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
            p.target = self; p.action = #selector(changed(_:))
            popup = p; built = p
        case .string where def.key.hasSuffix(".preset"):
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            for t in ThemePreset.all {
                p.addItem(withTitle: L(SettingsPanes.presetTitle(t.name)))
                p.lastItem?.representedObject = t.name
            }
            p.target = self; p.action = #selector(changed(_:))
            popup = p; built = p
        case .string:
            let f = NSTextField(string: "")
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 160).isActive = true
            field = f; built = f
        case .number:
            let f = NSTextField(string: "")
            f.alignment = .right
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            fmt.maximumFractionDigits = 2
            fmt.usesGroupingSeparator = false
            f.formatter = fmt
            let s = NSStepper()
            let r = SettingsPanes.stepperRange(def)
            s.minValue = r.min; s.maxValue = r.max; s.increment = r.step
            s.valueWraps = false
            s.target = self; s.action = #selector(stepped(_:))
            field = f; stepper = s
            var views: [NSView] = [f, s]
            if let u = SettingsPanes.unit(def) {
                let l = NSTextField(labelWithString: u)
                l.textColor = .secondaryLabelColor
                views.append(l)
            }
            let st = NSStackView(views: views)
            st.spacing = 4
            built = st
        case .color:
            let w = NSColorWell(style: .default)
            w.supportsAlpha = false
            w.target = self; w.action = #selector(changed(_:))
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
            w.heightAnchor.constraint(equalToConstant: 24).isActive = true
            well = w; built = w
        case .range:
            let s = NSSlider(value: 0, minValue: def.min ?? 0, maxValue: def.max ?? 100, target: self, action: #selector(changed(_:)))
            s.isContinuous = true
            s.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let v = NSTextField(labelWithString: "")
            v.alignment = .right
            v.textColor = .secondaryLabelColor
            v.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            v.widthAnchor.constraint(equalToConstant: 30).isActive = true
            slider = s; sliderValue = v
            let st = NSStackView(views: [s, v])
            st.spacing = 6
            built = st
        case .list:
            let t = NSTokenField()
            t.delegate = self
            t.tokenizingCharacterSet = CharacterSet(charactersIn: ", \n")
            // wrap onto more lines rather than clipping patterns off the end
            t.cell?.wraps = true
            t.cell?.isScrollable = false
            t.widthAnchor.constraint(equalToConstant: 300).isActive = true
            t.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            tokens = t; built = t
        }
        view = built
        view.toolTip = def.description.isEmpty ? nil : L(def.description)
        label.toolTip = view.toolTip
        sync()
    }

    var value: ConfigValue { backend.value(def.key) }

    static let inlineHelp: Set<String> = ["editor.jump-to-bottom-after-minutes", "editor.auto-insert-daily-heading",
                                          "files.associations", "appearance.editor-width"]

    /// Native wording where the schema label reads oddly in a Settings window.
    static func displayLabel(_ def: SettingDef) -> String {
        switch def.key {
        case "appearance.theme": return L("Appearance")
        case "appearance.sidebar-width": return L("Default width")
        case "appearance.sidebar-file-label": return L("File labels")
        case "appearance.editor-width": return L("Editor width")
        case "appearance.sidebar-visible": return L("Show sidebar")
        case "appearance.sidebar-show-search": return L("Show search button")
        case "appearance.sidebar-show-recents": return L("Show recents")
        default: return L(sentenceCase(def.label))
        }
    }

    /// macOS Settings use sentence case: "Font Size" → "Font size" (acronyms kept).
    static func sentenceCase(_ s: String) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        return words.enumerated().map { i, w in
            i == 0 || w.count > 1 && w == w.uppercased() ? String(w) : w.lowercased()
        }.joined(separator: " ")
    }

    /// Pull the current value into the control (skipping a field being edited).
    func sync() {
        let v = value
        checkbox?.state = (v.boolValue ?? false) ? .on : .off
        if let p = popup {
            switch def.type {
            case .enum: p.selectItem(at: (def.options ?? []).firstIndex(of: v.stringValue ?? "") ?? 0)
            case .font:
                let fam = FontStackEdit.firstFamily(v.stringValue ?? "")
                if p.item(withTitle: fam) == nil { p.insertItem(withTitle: fam, at: 0) }
                p.selectItem(withTitle: fam)
            default:
                // preset: the matching preset, else the stored name, else "Custom"
                let mode = self.mode ?? .light
                let name = ThemeResolver.matchingPreset(backend.values, mode: mode)?.name
                if let n = name, let i = p.itemArray.firstIndex(where: { $0.representedObject as? String == n }) { p.selectItem(at: i) } else {
                    if p.itemArray.last?.representedObject != nil { p.addItem(withTitle: L("Custom")) }
                    p.selectItem(at: p.numberOfItems - 1)
                }
            }
        }
        if let f = field, f.currentEditor() == nil {
            if def.type == .number { f.doubleValue = v.numberValue ?? 0 } else { f.stringValue = v.stringValue ?? "" }
        }
        stepper?.doubleValue = v.numberValue ?? 0
        if let w = well { w.color = RGBA(hex: v.stringValue ?? "")?.ns ?? .black }
        if let s = slider { s.doubleValue = v.numberValue ?? 0; sliderValue?.stringValue = String(Int((v.numberValue ?? 0).rounded())) }
        if let t = tokens, t.currentEditor() == nil {
            if case let .list(l) = v { t.objectValue = l } else { t.objectValue = [v.stringValue ?? ""].filter { !$0.isEmpty } }
        }
    }

    @objc func changed(_ sender: Any?) {
        switch def.type {
        case .boolean: backend.set(def.key, .bool(checkbox?.state == .on))
        case .enum:
            if let o = popup?.selectedItem?.representedObject as? String { backend.set(def.key, .string(o)) }
        case .font:
            if let fam = popup?.titleOfSelectedItem { backend.set(def.key, .string(FontStackEdit.stackWithFamily(fam, value.stringValue ?? ""))) }
        case .string where def.key.hasSuffix(".preset"):
            if let n = popup?.selectedItem?.representedObject as? String, let m = mode { backend.applyPreset(n, mode: m) }
        case .color:
            if let c = well?.color.usingColorSpace(.sRGB) {
                backend.set(def.key, .string(RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).hexString))
            }
        case .range:
            if let s = slider {
                let v = (s.doubleValue / (def.step ?? 1)).rounded() * (def.step ?? 1)
                sliderValue?.stringValue = String(Int(v))
                backend.set(def.key, .number(v))
            }
        default: break
        }
    }

    @objc func stepped(_ sender: NSStepper) {
        field?.doubleValue = sender.doubleValue
        backend.set(def.key, .number(sender.doubleValue))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, f === field else { return }
        if def.type == .number {
            if let n = Double(f.stringValue.replacingOccurrences(of: ",", with: ".")) { stepper?.doubleValue = n; backend.set(def.key, .number(n)) }
        } else {
            backend.set(def.key, .string(f.stringValue))
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let t = obj.object as? NSTokenField, t === tokens else { return }
        commitTokens()
    }

    func commitTokens() {
        let items = (tokens?.objectValue as? [Any] ?? []).compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        backend.set(def.key, .list(items))
    }

    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        DispatchQueue.main.async { [weak self] in self?.commitTokens() }
        return tokens
    }
}

/// One pane: a label/control grid with section headings and a
/// "Restore Defaults" button.
@MainActor
final class SettingsPaneController: NSViewController {
    let pane: SettingsPanes.Pane
    unowned let backend: SettingsBackend
    private(set) var controls: [SettingControl] = []
    let restoreButton = NSButton(title: L("Restore Defaults"), target: nil, action: nil)

    init(pane: SettingsPanes.Pane, backend: SettingsBackend) {
        self.pane = pane
        self.backend = backend
        super.init(nibName: nil, bundle: nil)
        title = L(pane.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        if pane.id == "theme" {
            buildThemeGrid(grid)
        } else {
            for (gi, group) in pane.groups.enumerated() {
                var firstInGroup = true
                var headingUsed = false
                for key in group.1 {
                    guard let def = SettingsSchema.def(key) else { continue }
                    let c = SettingControl(def: def, backend: backend)
                    controls.append(c)
                    // classic Settings layout: a group's checkboxes hang off the group label
                    if def.type == .boolean, !headingUsed, let h = group.0 {
                        c.label.stringValue = L(h) + ":"
                        headingUsed = true
                    }
                    let row = grid.addRow(with: [c.label, c.view])
                    row.yPlacement = .center
                    if firstInGroup && gi > 0 { row.topPadding = 14 }
                    firstInGroup = false
                    if let h = c.help { grid.addRow(with: [NSGridCell.emptyContentView, h]).topPadding = -3 }
                }
            }
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .leading
        }
        restoreButton.target = self
        restoreButton.action = #selector(restoreDefaults)
        restoreButton.bezelStyle = .rounded
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        container.addSubview(restoreButton)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -30),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor).withPriority(.defaultLow),
            restoreButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            restoreButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            restoreButton.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        view = container
        let fit = NSSize(width: grid.fittingSize.width + 60, height: 22 + grid.fittingSize.height + 20 + restoreButton.fittingSize.height + 20)
        preferredContentSize = NSSize(width: max(520, ceil(fit.width)), height: ceil(fit.height))
        container.frame = NSRect(origin: .zero, size: preferredContentSize)
    }

    /// Theme pane: one row per primary, Light and Dark side by side.
    private func buildThemeGrid(_ grid: NSGridView) {
        let light = pane.groups[0].1, dark = pane.groups[1].1
        let head = [NSGridCell.emptyContentView, NSTextField(labelWithString: L("Light")), NSTextField(labelWithString: L("Dark"))]
        (head[1] as! NSTextField).font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        (head[2] as! NSTextField).font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        grid.addRow(with: head)
        for (lk, dk) in zip(light, dark) {
            guard let ld = SettingsSchema.def(lk), let dd = SettingsSchema.def(dk) else { continue }
            let lc = SettingControl(def: ld, backend: backend), dc = SettingControl(def: dd, backend: backend)
            controls += [lc, dc]
            let row = grid.addRow(with: [lc.label, lc.view, dc.view])
            row.yPlacement = .center
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .leading
    }

    var keys: [String] { pane.groups.flatMap { $0.1 } }

    @objc func restoreDefaults() {
        backend.reset(keys)
        syncAll()
    }

    func syncAll() { controls.forEach { $0.sync() } }

    func control(_ key: String) -> SettingControl? { controls.first { $0.def.key == key } }
}

/// The single reusable Settings window (Cmd-,).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let backend: SettingsBackend
    let tabs = NSTabViewController()
    private(set) var panes: [SettingsPaneController] = []
    static let lastPaneKey = "settings.last-pane"

    init(backend: SettingsBackend) {
        self.backend = backend
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for p in SettingsPanes.all {
            let vc = SettingsPaneController(pane: p, backend: backend)
            panes.append(vc)
            let item = NSTabViewItem(viewController: vc)
            item.label = L(p.title)
            item.identifier = p.id
            item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: item.label)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.identifier = NSUserInterfaceItemIdentifier("settings")
        w.setFrameAutosaveName("FloStateSettings")
        super.init(window: w)
        w.delegate = self
        backend.refreshUI = { [weak self] in self?.syncAll() }
        tabs.addObserver(self, forKeyPath: "selectedTabViewItemIndex", options: [.new], context: nil)
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated { updateTitle() }
    }

    var selectedPane: SettingsPaneController { panes[max(0, tabs.selectedTabViewItemIndex)] }

    func select(_ id: String) {
        if let i = panes.firstIndex(where: { $0.pane.id == id }) { tabs.selectedTabViewItemIndex = i }
        updateTitle()
    }

    private func updateTitle() {
        window?.title = L(selectedPane.pane.title)
        resizeToPane(animate: window?.isVisible == true)
        // the outgoing pane can still constrain the frame this turn
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.resizeToPane(animate: false) } }
    }

    /// Fit the window to the selected pane, keeping its top edge.
    func resizeToPane(animate: Bool) {
        guard let w = window else { return }
        _ = selectedPane.view
        let size = selectedPane.preferredContentSize
        let frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var f = w.frame
        f.origin.y += f.height - frame.height
        f.size = frame.size
        w.setFrame(f, display: true, animate: animate)
    }

    /// Values changed elsewhere (another window, config reload): refresh controls.
    func syncAll() { panes.forEach { if $0.isViewLoaded { $0.syncAll() } } }

    func show() {
        backend.reloadFromDisk()
        syncAll()
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}

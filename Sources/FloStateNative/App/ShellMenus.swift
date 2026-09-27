import AppKit
import FloCore

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], checked: Bool? = nil, _ handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        if let c = checked { state = c ? .on : .off }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { handler?() }
}

/// Context menus (sidebar, tabs, footer, rail) — item order per the web app.
@MainActor
enum ShellMenus {
    static func menu(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        items.forEach(m.addItem)
        return m
    }

    /// `buildFileMenuItemsSpec`.
    static func fileMenu(model: ShellModel, entry: DirEntry, inlineRename: Bool) -> NSMenu {
        let isPinned = model.pinnedFiles.contains(entry.path)
        return menu([
            ClosureMenuItem(L("Open")) { Task { await model.editor.openFile(entry.path) } },
            ClosureMenuItem(L("Open in new tab")) {
                Task {
                    do { try await model.editor.openFileInNewTab(entry.path) } catch { model.alert(L("Failed to open in new tab: %@", "\(error)")) }
                }
            },
            ClosureMenuItem(isPinned ? L("Unpin") : L("Pin")) { model.togglePinned(entry.path) },
            .separator(),
            ClosureMenuItem(L("Duplicate")) { Task { await model.duplicate(entry.path) } },
            .separator(),
            ClosureMenuItem(L("Copy relative path")) { model.copyToPasteboard(model.relativePath(entry.path)) },
            ClosureMenuItem(L("Copy absolute path")) { model.copyToPasteboard(entry.path) },
            .separator(),
            ClosureMenuItem(L("Reveal in Finder")) { model.revealInFinder(entry.path) },
            .separator(),
            ClosureMenuItem(L("Rename...")) {
                if inlineRename { model.renamingPath = entry.path } else { promptRename(model: model, entry: entry) }
            },
            ClosureMenuItem(L("Delete")) { model.deleteEntry(entry) },
        ])
    }

    /// Pinned/Recents rows rename through a prompt (`window.prompt`).
    static func promptRename(model: ShellModel, entry: DirEntry) {
        let alert = NSAlert()
        alert.messageText = L("Rename file")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = LinkPaths.getFileStem(entry.name)
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.submitRename(entry, field.stringValue)
    }

    /// `buildFolderMenuItemsSpec`.
    static func folderMenu(model: ShellModel, entry: DirEntry) -> NSMenu {
        menu([
            ClosureMenuItem(L("New File")) { model.createFileInFolder(entry.path) },
            ClosureMenuItem(L("New Folder")) { model.createFolderInFolder(entry.path) },
            .separator(),
            ClosureMenuItem(L("Copy relative path")) { model.copyToPasteboard(model.relativePath(entry.path)) },
            ClosureMenuItem(L("Copy absolute path")) { model.copyToPasteboard(entry.path) },
            .separator(),
            ClosureMenuItem(L("Reveal in Finder")) { model.revealInFinder(entry.path) },
            .separator(),
            ClosureMenuItem(L("Rename...")) { model.renamingPath = entry.path },
            ClosureMenuItem(L("Delete")) { model.deleteEntry(entry) },
        ])
    }

    /// `buildBulkMenuItemsSpec`.
    static func bulkMenu(model: ShellModel, paths: [String]) -> NSMenu {
        menu([
            ClosureMenuItem(L("Copy %d relative paths", paths.count)) { model.copyToPasteboard(paths.map(model.relativePath).joined(separator: "\n")) },
            ClosureMenuItem(L("Copy %d absolute paths", paths.count)) { model.copyToPasteboard(paths.joined(separator: "\n")) },
            .separator(),
            ClosureMenuItem(L("Delete %d items", paths.count)) { model.deleteEntries(paths) },
        ])
    }

    /// Right-click on empty sidebar space: Search / Recents check items.
    static func sidebarSurfaceMenu(model: ShellModel) -> NSMenu {
        let v = model.values
        return menu([
            ClosureMenuItem(L("Search"), checked: v.appearanceSidebarShowSearch) { model.setSetting("appearance.sidebar-show-search", .bool(!v.appearanceSidebarShowSearch)) },
            ClosureMenuItem(L("Recents"), checked: v.appearanceSidebarShowRecents) { model.setSetting("appearance.sidebar-show-recents", .bool(!v.appearanceSidebarShowRecents)) },
        ])
    }

    /// Workspace switcher: other recents | Open Folder… | Close Workspace.
    static func workspaceMenu(model: ShellModel) -> NSMenu {
        var items: [NSMenuItem] = []
        let others = model.recentWorkspacesStore.load().filter { $0 != model.root }
        for p in others {
            let name = (p as NSString).lastPathComponent
            items.append(ClosureMenuItem(name.isEmpty ? p : name) { Task { await model.openWorkspace(p) } })
        }
        if !others.isEmpty { items.append(.separator()) }
        items.append(ClosureMenuItem(L("Open Folder…")) { model.perform(.openWorkspacePanel) })
        if model.root != nil { items.append(ClosureMenuItem(L("Close Workspace")) { model.closeWorkspace() }) }
        return menu(items)
    }

    /// `buildTabMenuItemsSpec`: Close, Close others, Close all | Reveal in sidebar, Copy path.
    static func tabMenu(model: ShellModel, tab: Tab) -> NSMenu? {
        guard let path = tab.location.primaryPath else { return nil }
        return menu([
            ClosureMenuItem(L("Close")) { model.editor.closeTab(tab.id) },
            ClosureMenuItem(L("Close others")) { model.editor.closeOtherTabs(tab.id) },
            ClosureMenuItem(L("Close all")) { model.editor.closeAllTabs() },
            .separator(),
            ClosureMenuItem(L("Reveal in sidebar")) { model.editor.setActiveTab(tab.id); model.revealInSidebar(path) },
            ClosureMenuItem(L("Copy path")) { model.copyToPasteboard(model.relativePath(path)) },
        ])
    }

    /// Footer: Words / Characters / Paragraphs check items.
    static func footerMenu(model: ShellModel) -> NSMenu {
        let v = model.values
        return menu([
            ClosureMenuItem(L("Words"), checked: v.statusbarShowWords) { model.setSetting("statusbar.show-words", .bool(!v.statusbarShowWords)) },
            ClosureMenuItem(L("Characters"), checked: v.statusbarShowCharacters) { model.setSetting("statusbar.show-characters", .bool(!v.statusbarShowCharacters)) },
            ClosureMenuItem(L("Paragraphs"), checked: v.statusbarShowParagraphs) { model.setSetting("statusbar.show-paragraphs", .bool(!v.statusbarShowParagraphs)) },
        ])
    }
}

/// The app menu bar (`install_app_menu` in lib.rs). Items send `ShellAction`s
/// to the key window's shell (`emit_to_focused_window`).
@MainActor
enum MainMenu {
    struct Entry: Equatable {
        var title: String
        var key: String
        var modifiers: NSEvent.ModifierFlags
        var action: ShellAction?
        /// Extra key equivalent for the same action (hidden item, still flashes the menu title).
        var hidden = false
        static func == (a: Entry, b: Entry) -> Bool { a.title == b.title && a.key == b.key && a.modifiers == b.modifiers && a.action == b.action && a.hidden == b.hidden }
    }

    /// File / View entries in order; `nil` title = separator.
    static let fileEntries: [Entry?] = [
        Entry(title: "New Note", key: "n", modifiers: [.command], action: .newNote),
        Entry(title: "New Tab", key: "t", modifiers: [.command], action: .newTab),
        Entry(title: "Go to File…", key: "o", modifiers: [.command], action: .openFileSearch),
        nil,
        Entry(title: "Go to Today", key: "d", modifiers: [.command, .shift], action: .goToToday),
        Entry(title: "Search…", key: "k", modifiers: [.command], action: .search),
        Entry(title: "Search in All Notes…", key: "f", modifiers: [.command, .shift], action: .searchContents),
        nil,
        Entry(title: "Close Tab", key: "w", modifiers: [.command], action: .closeTab),
    ]

    static let viewEntries: [Entry?] = [
        Entry(title: "Toggle Sidebar", key: "\\", modifiers: [.command], action: .toggleSidebar),
        Entry(title: "Toggle Typewriter Scrolling", key: "c", modifiers: [.command, .option], action: .toggleTypewriter),
        nil,
        Entry(title: "Increase Font Size", key: "=", modifiers: [.command], action: .fontSizeIncrease),
        Entry(title: "Decrease Font Size", key: "-", modifiers: [.command], action: .fontSizeDecrease),
        Entry(title: "Reset Font Size", key: "0", modifiers: [.command], action: .fontSizeReset),
        nil,
        Entry(title: "Collapse All Headings", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: [.command, .option], action: .collapseHeadings),
        Entry(title: "Expand All Headings", key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .option], action: .expandHeadings),
        nil,
        Entry(title: "Back", key: "", modifiers: [], action: .back),
        Entry(title: "Forward", key: "", modifiers: [], action: .forward),
        nil,
        Entry(title: "Previous File", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command, .option], action: .stepFile(-1)),
        Entry(title: "Next File", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command, .option], action: .stepFile(1)),
    ]

    /// Format menu: the editor's formatting shortcuts, so they're discoverable. The editor
    /// keymap handles the keys when it has focus; the menu item runs the same chord.
    static let formatEntries: [Entry?] = [
        Entry(title: "Bold", key: "b", modifiers: [.command], action: .editorKey("Mod-b")),
        Entry(title: "Italic", key: "i", modifiers: [.command], action: .editorKey("Mod-i")),
        Entry(title: "Strikethrough", key: "x", modifiers: [.command, .shift], action: .editorKey("Mod-Shift-x")),
        Entry(title: "Inline Code", key: "e", modifiers: [.command], action: .editorKey("Mod-e")),
        Entry(title: "Insert Link", key: "", modifiers: [], action: .editorKey("Mod-k")),
        nil,
        Entry(title: "Heading 1", key: "1", modifiers: [.command, .option], action: .editorKey("Mod-Alt-1")),
        Entry(title: "Heading 2", key: "2", modifiers: [.command, .option], action: .editorKey("Mod-Alt-2")),
        Entry(title: "Heading 3", key: "3", modifiers: [.command, .option], action: .editorKey("Mod-Alt-3")),
        Entry(title: "Body Text", key: "0", modifiers: [.command, .option], action: .editorKey("Mod-Alt-0")),
        nil,
        Entry(title: "Bulleted List", key: "8", modifiers: [.command, .shift], action: .editorKey("Mod-Shift-8")),
        Entry(title: "Numbered List", key: "7", modifiers: [.command, .shift], action: .editorKey("Mod-Shift-7")),
        Entry(title: "Checkbox", key: "9", modifiers: [.command, .shift], action: .editorKey("Mod-Shift-9")),
        Entry(title: "Mark as Done", key: ".", modifiers: [.command], action: .editorKey("Mod-.")),
        Entry(title: "Quote", key: ".", modifiers: [.command, .shift], action: .editorKey("Mod-Shift-.")),
        nil,
        Entry(title: "Indent", key: "]", modifiers: [.command], action: .editorKey("Mod-]")),
        Entry(title: "Outdent", key: "[", modifiers: [.command], action: .editorKey("Mod-[")),
        Entry(title: "Move Line Up", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.option], action: .editorKey("Alt-ArrowUp")),
        Entry(title: "Move Line Down", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.option], action: .editorKey("Alt-ArrowDown")),
    ]

    /// Window-menu tab navigation (web: use-keyboard-shortcuts.ts), as menu
    /// items so the menu title flashes like in other apps.
    static let tabEntries: [Entry?] = [
        Entry(title: "Show Previous Tab", key: "{", modifiers: [.command], action: .previousTab),
        Entry(title: "Show Next Tab", key: "}", modifiers: [.command], action: .nextTab),
        Entry(title: "Show Previous Tab", key: "\t", modifiers: [.control, .shift], action: .previousTab, hidden: true),
        Entry(title: "Show Next Tab", key: "\t", modifiers: [.control], action: .nextTab, hidden: true),
    ]

    /// Native menu accelerators that win over the editor keymap (spec §2):
    /// Cmd-N, T, W, K, \\, ",", Shift-D, Alt-C, =, −, 0, Alt-←, Alt-→.
    static func menuWins(keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool) -> Bool {
        guard command, !control else { return false }
        switch (keyCode, shift, option) {
        case (45, false, false), (17, false, false), (13, false, false), (40, false, false), (42, false, false), (43, false, false):
            return true // N T W K \ ,
        case (2, true, false): return true // Shift-D
        case (8, false, true): return true // Alt-C
        case (24, false, false), (27, false, false), (29, false, false): return true // = - 0
        case (123, false, true), (124, false, true): return true // Alt-← Alt-→
        default: return false
        }
    }

    static let checkForUpdatesTitle = "Check for Updates…"

    /// `updateItem`: "Check for Updates…" (AppUpdater) — only when this build has a feed.
    static func build(target: MenuRouter, updateItem: NSMenuItem? = nil) -> NSMenu {
        let main = NSMenu()
        func sub(_ key: String, _ items: [NSMenuItem]) {
            let title = L(key)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
        }
        func routed(_ entries: [Entry?]) -> [NSMenuItem] {
            entries.map { e in
                guard let e = e else { return .separator() }
                let it = NSMenuItem(title: L(e.title), action: #selector(MenuRouter.menuAction(_:)), keyEquivalent: e.key)
                it.keyEquivalentModifierMask = e.modifiers
                it.target = target
                it.representedObject = MenuRouter.Box(e.action!)
                if e.hidden { it.isHidden = true; it.allowsKeyEquivalentWhenHidden = true }
                return it
            }
        }
        // the installed bundle's name ("Flo State"); tests / bare binaries get the same
        let appName = Bundle.main.bundleIdentifier == "app.flostate.native"
            ? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Flo State") : "Flo State"
        let prefs = NSMenuItem(title: L("Settings…"), action: #selector(MenuRouter.menuAction(_:)), keyEquivalent: ",")
        prefs.target = target
        prefs.representedObject = MenuRouter.Box(.openPreferences)
        let services = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: L("Services"))
        NSApp?.servicesMenu = services.submenu
        let hideOthers = NSMenuItem(title: L("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        sub(appName, [
            NSMenuItem(title: L("About %@", appName), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
        ] + (updateItem.map { [$0] } ?? []) + [
            .separator(),
            prefs,
            CLIMenuItem(),
            .separator(),
            services,
            .separator(),
            NSMenuItem(title: L("Hide %@", appName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            hideOthers,
            NSMenuItem(title: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: L("Quit %@", appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        let openFolder = NSMenuItem(title: L("Open Folder…"), action: #selector(MenuRouter.menuAction(_:)), keyEquivalent: "")
        openFolder.target = target
        openFolder.representedObject = MenuRouter.Box(.openWorkspacePanel)
        sub("File", routed(fileEntries))
        // Edit: standard responder actions + Substitutions (text replacement).
        let redo = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let subs = NSMenuItem(title: L("Substitutions"), action: nil, keyEquivalent: "")
        let subsMenu = NSMenu(title: L("Substitutions"))
        subsMenu.addItem(NSMenuItem(title: L("Show Substitutions"), action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: ""))
        subsMenu.addItem(.separator())
        subsMenu.addItem(NSMenuItem(title: L("Smart Copy/Paste"), action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: ""))
        subsMenu.addItem(NSMenuItem(title: L("Smart Quotes"), action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: ""))
        subsMenu.addItem(NSMenuItem(title: L("Smart Dashes"), action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: ""))
        subsMenu.addItem(NSMenuItem(title: L("Smart Links"), action: #selector(NSTextView.toggleAutomaticLinkDetection(_:)), keyEquivalent: ""))
        subsMenu.addItem(NSMenuItem(title: L("Text Replacement"), action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: ""))
        subs.submenu = subsMenu
        sub("Edit", [
            NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            .separator(),
            subs,
        ])
        sub("Format", routed(formatEntries))
        sub("View", routed(viewEntries))
        let fullscreen = NSMenuItem(title: L("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        let goTo = NSMenuItem(title: L("Go to Tab"), action: nil, keyEquivalent: "")
        goTo.submenu = NSMenu(title: L("Go to Tab"))
        routed((1...9).map { Entry(title: L("Tab %d", $0), key: "\($0)", modifiers: [.command], action: .selectTab($0)) }).forEach(goTo.submenu!.addItem)
        let windowMenuItems: [NSMenuItem] = [
            NSMenuItem(title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            fullscreen,
            .separator(),
        ] + routed(tabEntries) + [
            goTo,
            .separator(),
            NSMenuItem(title: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: ""),
        ]
        sub("Window", windowMenuItems)
        NSApp?.windowsMenu = main.items.last?.submenu
        return main
    }
}

/// Target of every routed menu item: forwards to the key window's shell.
@MainActor
final class MenuRouter: NSObject, NSMenuItemValidation {
    final class Box: NSObject { let action: ShellAction; init(_ a: ShellAction) { action = a } }
    /// Resolves the shell of the focused window (nil = no window).
    var focusedModel: () -> ShellModel? = { nil }
    /// Fallback when no window: e.g. Open Folder… creates one.
    var noWindow: (ShellAction) -> Void = { _ in }
    private(set) var log: [ShellAction] = []

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let a = (sender.representedObject as? Box)?.action else { return }
        route(a)
    }

    /// App-level actions (e.g. Settings…) handled before any window; true = handled.
    var appAction: (ShellAction) -> Bool = { _ in false }

    /// The key window is not a workspace window (e.g. Settings): Close Tab
    /// closes that window instead of reaching into a workspace behind it.
    var keyWindowIsForeign: () -> Bool = { false }
    var closeKeyWindow: () -> Void = { NSApp?.keyWindow?.performClose(nil) }

    func route(_ a: ShellAction) {
        log.append(a)
        if appAction(a) { return }
        if keyWindowIsForeign() {
            if a == .closeTab { closeKeyWindow() }
            return
        }
        if let m = focusedModel() { m.perform(a) } else { noWindow(a) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let a = (item.representedObject as? Box)?.action, let m = focusedModel() else { return item.representedObject == nil || focusedModel() != nil || true }
        switch a {
        case .back: return m.editor.canNavigateBack
        case .forward: return m.editor.canNavigateForward
        case .toggleTypewriter: item.state = m.typewriterScrolling ? .on : .off; return true
        default: return true
        }
    }
}

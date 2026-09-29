import AppKit
import FloCore
import FloKit
import UniformTypeIdentifiers

/// GUI entry point.
@MainActor
enum FloApp {
    static var delegate: AppDelegate?

    static func run() {
        let args = CommandLine.arguments
        // Invoked through the `writer` symlink: act as the CLI and exit.
        if let a0 = args.first, FloStateCLI.isCLIInvocation(a0) {
            exit(FloStateCLI.run(args, cwd: FileManager.default.currentDirectoryPath))
        }
        forceLeftToRightLayout()
        if args.contains("--settings-snapshot") {
            ShellSnapshot.runSettings(args)
            exit(0)
        }
        if args.contains("--selftest-sidebar") {
            SelfTest.runSidebar(args)
        }
        if args.contains("--selftest-scroll") {
            SelfTest.runScroll(args)
        }
        if args.contains("--selftest-return") {
            SelfTest.run(args)
            exit(0)
        }
        if args.contains("--shell-snapshot") {
            ShellSnapshot.run(args)
            exit(0)
        }
        if args.contains("--sparkle-probe") {
            UpdateProbe.run(args)
        }
        LaunchTrace.mark("main")
        if LaunchTrace.enabled { EditorController.launchTrace = { LaunchTrace.note($0, since: $1) } }
        registerLaunchDefaults()
        let app = NSApplication.shared
        let dataOverride = ProcessInfo.processInfo.environment["FLO_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        let d = AppDelegate(dataDir: AppDataDirectory(baseURL: dataOverride ?? AppDataDirectory.defaultBaseURL), launchPaths: launchPaths(args))
        if dataOverride == nil, d.forwardToRunningInstance() { exit(0) }
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// AppKit's document-app launch behaviour (the Info.plist declares
    /// document types): with no window at launch/reopen it would show its own
    /// app-centric Open panel instead of an untitled document. Never.
    static let launchDefaults: [String: Any] = [
        "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false,
        // Our own session restore owns windows; no AppKit window restoration.
        "NSQuitAlwaysKeepsWindows": false,
    ]

    /// Arabic and Urdu get translated text in a left-to-right layout. A
    /// right-to-left app direction (the system's AppleTextDirection) makes
    /// TextKit's default paragraph direction right-to-left, which moves the
    /// editor's indents and bullets off the note's own text direction; the
    /// shell is custom-drawn and doesn't mirror anyway. Argument domain: wins
    /// over the global setting, for this process only, nothing persisted.
    static func forceLeftToRightLayout(_ defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: "AppleTextDirection") else { return }  // left-to-right systems: nothing to do
        var args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        args["AppleTextDirection"] = false
        defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }

    static func registerLaunchDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: launchDefaults)
    }

    /// Paths passed on the command line (ignoring `-NSDocument…`-style flags).
    static func launchPaths(_ args: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for a in args.dropFirst() {
            if skip { skip = false; continue }
            if a.hasPrefix("-") { skip = a.hasPrefix("-NS") || a.hasPrefix("-Apple"); continue }
            out.append((a as NSString).expandingTildeInPath)
        }
        return out.map { $0.hasPrefix("/") ? $0 : FileManager.default.currentDirectoryPath + "/" + $0 }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openNotification = Notification.Name("app.flostate.native.open")
    static let bundleID = "app.flostate.native"

    let dataDir: AppDataDirectory
    let router = MenuRouter()
    private(set) var windows: [ShellWindowController] = []
    private var launchPaths: [String]
    private var didFinishLaunching = false
    /// Tests: windows are built offscreen and never ordered front.
    let offscreen: Bool
    /// Workspace/file opens still restoring (startup, reopen, Finder opens).
    private var pendingOpens: [UUID: Task<Void, Never>] = [:]
    var isOpening: Bool { !pendingOpens.isEmpty }

    init(dataDir: AppDataDirectory, launchPaths: [String], offscreen: Bool = false) {
        self.dataDir = dataDir
        self.launchPaths = launchPaths
        self.offscreen = offscreen
        super.init()
    }

    /// Wait for every in-flight open (tests; also used before quitting).
    func waitForPendingOpens() async {
        while let t = pendingOpens.values.first { await t.value }
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pendingOpens[id] = Task { [weak self] in
            await work()
            self?.pendingOpens[id] = nil
        }
    }

    /// Single instance: another copy running → hand it our paths and quit.
    func forwardToRunningInstance() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).filter { $0.processIdentifier != me }
        guard let other = others.first else { return false }
        DistributedNotificationCenter.default().postNotificationName(Self.openNotification, object: nil,
                                                                      userInfo: ["paths": launchPaths], deliverImmediately: true)
        other.activate()
        return true
    }

    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("didFinishLaunching")
        claimDefaultTextHandlersOnce()
        // Follow the system light/dark switch for windows set to "system".
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for m in self?.adoptedModels.compactMap({ $0.model }) ?? [] where m.values.appearanceTheme == .system {
                        m.notify(.editorFont)
                        m.notify(.theme)
                    }
                    self?.settingsWindow?.syncAll()
                }
            }
        }
        if !offscreen, AppUpdater.shared == nil, AppUpdater.isConfigured() { AppUpdater.shared = AppUpdater() }
        if LaunchTrace.enabled { let t = Date(); _ = L("File"); LaunchTrace.note("first localized lookup (\(L10n.current))", since: t) }
        NSApp.mainMenu = MainMenu.build(target: router, updateItem: AppUpdater.shared?.menuItem())
        router.focusedModel = { [weak self] in self?.focusedController?.model }
        router.keyWindowIsForeign = { [weak self] in
            guard let key = NSApp.keyWindow, let self = self else { return false }
            return !self.windows.contains { $0.window === key }
        }
        router.appAction = { [weak self] a in
            guard a == .openPreferences else { return false }
            self?.showSettings()
            return true
        }
        router.noWindow = { [weak self] a in
            if a == .openWorkspacePanel { self?.openFolderPanel() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.openNotification, object: nil, queue: .main) { [weak self] n in
            let paths = n.userInfo?["paths"] as? [String] ?? []
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                if paths.isEmpty { self?.focusedController?.window?.makeKeyAndOrderFront(nil) } else { self?.open(paths: paths) }
            }
        }
        didFinishLaunching = true
        startup()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `get_startup_state`: argv/Finder open → workspace/file; else last workspace; else welcome.
    /// Same path for a normal, background (`open -g`) or hidden (`open -j`) launch.
    func startup() {
        let settings = AppSettings(globalConfigDir: dataDir.baseURL)
        try? dataDir.prepare()
        let recents = RecentWorkspacesStore(appData: dataDir).load()
        let pending = launchPaths.lazy.compactMap { PendingOpen.resolve($0, extensions: settings.supportedExtensions) }.first
        let plan = WorkspaceBootstrap.plan(startupOpen: pending, recentWorkspaces: recents, restoreWorkspace: settings.values.windowRestoreWorkspace)
        switch plan {
        case let .workspace(root, file, keep):
            openWorkspaceWindow(root, file: file, keepSession: keep)
        case let .standaloneFile(f):
            openCompactWindow(f)
        case .empty:
            openWelcomeWindow()
        }
    }

    /// Menu actions go to the key window; with no key window (app inactive),
    /// the main or first workspace window.
    var focusedController: ShellWindowController? {
        if let key = NSApp.keyWindow { return windows.first { $0.window === key } }
        return windows.first { $0.window?.isMainWindow == true } ?? windows.first
    }

    // MARK: Settings window + settings broadcast

    private(set) var settingsWindow: SettingsWindowController?
    private var broadcasting = false

    func showSettings() {
        if settingsWindow == nil {
            let backend = SettingsBackend(dataDir: dataDir)
            backend.onChange = { [weak self] in self?.settingsChanged(from: nil) }
            settingsWindow = SettingsWindowController(backend: backend)
        }
        settingsWindow?.show()
    }

    /// A global setting changed (in the Settings window or a workspace window,
    /// e.g. Cmd-= / Cmd-\\): every other window reloads the global layer.
    func settingsChanged(from source: ShellModel?) {
        guard !broadcasting else { return }
        broadcasting = true
        defer { broadcasting = false }
        for m in adoptedModels.compactMap({ $0.model }) where m !== source {
            m.settings.reloadGlobal()
            m.settingsDidChange()
        }
        if source != nil { settingsWindow?.backend.reloadFromDisk() }
        settingsWindow?.syncAll()
    }

    /// Hook a window's model into the Settings window + settings broadcast.
    func adopt(model: ShellModel) {
        model.openSettingsWindow = { [weak self] in self?.showSettings() }
        model.observers.append { [weak self, weak model] change in
            if change == .settings, let m = model { self?.settingsChanged(from: m) }
        }
        adoptedModels.append(Weak(model))
    }

    private final class Weak { weak var model: ShellModel?; init(_ m: ShellModel) { model = m } }
    private var adoptedModels: [Weak] = []

    private func makeController() -> ShellWindowController {
        let model = ShellModel(dataDir: dataDir)
        adopt(model: model)
        let c = offscreen ? ShellWindowController(model: model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
                          : ShellWindowController(model: model)
        model.openWorkspaceElsewhere = { [weak self] p in self?.openWorkspaceWindow(p, file: nil, keepSession: true) }
        model.openCompactWindow = { [weak self] p in self?.openCompactWindow(p) }
        model.openDroppedPaths = { [weak self] ps in self?.open(paths: ps) }
        model.closeWindow = { [weak c] in c?.window?.close() }
        c.onClose = { [weak self] wc in self?.windows.removeAll { $0 === wc } }
        windows.append(c)
        return c
    }

    func openWorkspaceWindow(_ root: String, file: String?, keepSession: Bool) {
        let canonical = WorkspaceFS.canonicalize(root)
        if let existing = windows.first(where: { $0.model.root == canonical }) {
            existing.window?.makeKeyAndOrderFront(nil)
            if let f = file { Task { try? await existing.model.editor.openFileInTabOrFocus(f) } }
            return
        }
        // Reuse an empty welcome window.
        let c = windows.first(where: { $0.model.root == nil && $0.model.editor.tabs.isEmpty }) ?? makeController()
        let secondary = windows.count > 1
        c.model.onWorkspaceShellReady = { [weak self, weak c] in
            guard let self = self, let c = c else { return }
            c.model.onWorkspaceShellReady = {}
            c.flush()
            if c.window?.isVisible != true { self.show(c, secondary: secondary) }
        }
        track { [weak self] in
            await c.model.openWorkspace(canonical, openFile: file, keepSession: keepSession)
            c.flush()
            if c.window?.isVisible != true { self?.show(c, secondary: secondary) }
            c.didActivate()
        }
    }

    func openCompactWindow(_ file: String) {
        let c = makeController()
        track { [weak self] in
            await c.model.editor.openCompactFile(file)
            c.flush()
            self?.show(c, secondary: (self?.windows.count ?? 0) > 1)
        }
    }

    func openWelcomeWindow() {
        let c = makeController()
        c.flush()
        show(c)
    }

    private func show(_ c: ShellWindowController, secondary: Bool = false) {
        guard !offscreen else { return }
        c.showAndFocus(secondary: secondary)
    }

    func openFolderPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        guard p.runModal() == .OK, let url = p.url else { return }
        openWorkspaceWindow(url.path, file: nil, keepSession: true)
    }

    /// Once per install, from the installed app only: make Flo State the default app for Markdown and plain
    /// text (.txt). Never repeated, so a user who switches back to another editor keeps their choice.
    /// CSV / .log are registered (Open With) but not claimed: those usually belong to other apps.
    private func claimDefaultTextHandlersOnce() {
        let key = "claimedDefaultTextHandlers"
        guard !offscreen, !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        let app = Bundle.main.bundleURL
        for type in [UTType("net.daringfireball.markdown"), UTType.plainText].compactMap({ $0 }) {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if let error { NSLog("Flo State: couldn't become default for \(type.identifier): \(error.localizedDescription)") }
            }
        }
    }

    /// Finder / `open` / dock drops (`take_pending_open` + fa649ea routing).
    func open(paths: [String]) {
        let settings = AppSettings(globalConfigDir: dataDir.baseURL)
        for p in paths {
            guard let pending = PendingOpen.resolve(p, extensions: settings.supportedExtensions) else { continue }
            if let ws = pending.workspace { openWorkspaceWindow(ws, file: nil, keepSession: true); continue }
            guard let file = pending.file else { continue }
            let roots = windows.compactMap { $0.model.root }
            if let owner = WorkspaceBootstrap.owningWorkspace(of: file, among: roots) {
                openWorkspaceWindow(owner, file: file, keepSession: true)
            } else if let c = windows.first(where: { $0.model.root != nil }) {
                c.window?.makeKeyAndOrderFront(nil)
                Task { try? await c.model.editor.openFileInTabOrFocus(file) }
            } else {
                openCompactWindow(file)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.map { $0.path }
        if !didFinishLaunching { launchPaths += paths; return }
        open(paths: paths)
    }

    /// Dock click / `open` of the running app. Returning false stops AppKit's
    /// default (an untitled document, i.e. its Open panel).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopen(hasVisibleWindows: flag)
        return false
    }

    enum ReopenAction: Equatable { case none, showExisting, startup }

    /// Hidden (`-j`), minimised or still-restoring windows are brought back,
    /// never duplicated; only with no window at all is the last workspace reopened.
    func reopenAction(hasVisibleWindows: Bool) -> ReopenAction {
        if hasVisibleWindows { return .none }
        return windows.isEmpty && !isOpening ? .startup : .showExisting
    }

    func reopen(hasVisibleWindows: Bool) {
        switch reopenAction(hasVisibleWindows: hasVisibleWindows) {
        case .none: break
        case .startup: startup()
        case .showExisting:
            guard !offscreen else { return }
            if NSApp.isHidden { NSApp.unhide(nil) }
            for c in windows {
                guard let w = c.window else { continue }
                if w.isMiniaturized { w.deminiaturize(nil) } else if !w.isVisible, !isOpening { w.makeKeyAndOrderFront(nil) }
            }
        }
    }

    /// No AppKit untitled document / Open panel, at launch or on reopen:
    /// startup() and reopen() decide which window to show.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        for w in windows { w.model.windowWillClose() }
    }

    /// Dock menu: recent workspaces.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        for p in RecentWorkspacesStore(appData: dataDir).load() {
            m.addItem(ClosureMenuItem((p as NSString).lastPathComponent) { [weak self] in self?.openWorkspaceWindow(p, file: nil, keepSession: true) })
        }
        return m
    }
}

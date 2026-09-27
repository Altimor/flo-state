import AppKit
import FloCore

/// Every user-facing action the shell can perform. Menu items, keyboard
/// shortcuts, palette commands and buttons all route through `ShellModel.perform`.
enum ShellAction: Equatable {
    // menu:* events (lib.rs + use-menu-events.ts)
    case openPreferences, newNote, newTab, goToToday, search, closeTab
    case toggleSidebar, toggleTypewriter
    case fontSizeIncrease, fontSizeDecrease, fontSizeReset
    case collapseHeadings, expandHeadings
    case back, forward
    // web-view shortcuts (use-keyboard-shortcuts.ts)
    case openFileSearch            // Cmd-O
    case searchContents            // Cmd-Shift-F
    case previousTab, nextTab      // Cmd-Shift-[ ], Ctrl-(Shift-)Tab
    case selectTab(Int)            // Cmd-1…9 (1-based)
    case stepFile(Int)             // Cmd-Alt-↑/↓
    // palette commands
    case closeAllTabs, openWorkspacePanel, closeWorkspace, toggleTheme, openInCompactWindow
}

/// Command palette state (`ui-store.ts` + `command-palette/index.tsx`).
struct PaletteState: Equatable {
    enum Intent: String { case search, createFile = "create-file", fullText = "full-text" }
    var intent: Intent
    var query: String = ""
    var selected: Int = 0
}

/// A palette row.
struct PaletteItem: Equatable {
    enum Kind: Equatable { case command(String), file(String), create(String), hit(path: String, offset: Int, length: Int) }
    var kind: Kind
    var title: String
    var subtitle: String?
    /// Highlighted UTF-16 offsets in `subtitle` (fuzzy matches).
    var highlights: [Int] = []
}

/// The workspace window's controller state: settings, tabs (EditorStore),
/// autosave, session, file tree, index, watcher, palette, sidebar visibility.
/// Contains no views, so it is unit-testable.
@MainActor
final class ShellModel {
    let dataDir: AppDataDirectory
    let settings: AppSettings
    let scheduler: AppScheduler
    let editor: EditorStore
    let tree: WorkspaceTreeModel
    let sessionStore: SessionStore
    let recentWorkspacesStore: RecentWorkspacesStore
    let recentFilesStore: RecentFilesStore
    private(set) var sessionAutosaver: SessionAutosaver!
    private(set) var reconciler: FileChangeReconciler!
    private var recentRecorder: RecentFilesRecorder?

    private(set) var root: String?
    private(set) var index: FileIndex?
    private(set) var ignore = WorkspaceIgnore.bootstrap()
    private(set) var watcher: WorkspaceWatcherModel?
    private(set) var isIndexing = false
    /// Snapshot mode: never write files (autosave is a no-op), no watcher.
    var readOnly = false
    /// Tests drive `handleWatcherOutputs` directly.
    var watcherEnabled = true

    // View state
    var windowWidth: CGFloat = 1200 { didSet { if oldValue != windowWidth { notify(.layout) } } }
    var typewriterScrolling = true
    var palette: PaletteState? {
        didSet {
            // full-text search keeps note text only while it's open
            if palette?.intent != .fullText { contentSearch.clear(); contentResults = [] }
            notify(.palette)
        }
    }
    var paletteResults: [SearchResult] = []
    var contentResults: [ContentHit] = []
    let contentSearch = ContentSearch()
    /// Text range to select after opening a note from full-text search.
    var pendingReveal: (path: String, offset: Int, length: Int)?
    var renamingPath: String? { didSet { notify(.sidebar) } }
    var selectedPaths: Set<String> = [] { didSet { notify(.sidebar) } }
    var selectionAnchor: String?
    var pinnedVisibleCount = 6
    var recentVisibleCount = 4
    var collapsedSections: Set<String> = []
    /// Host hooks (window controller).
    var systemIsDark: () -> Bool = { NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var pickFolder: () -> String? = { nil }
    var alert: (String) -> Void = { _ in }
    var confirm: (String) -> Bool = { _ in true }
    var openWorkspaceElsewhere: (String) -> Void = { _ in }
    var openCompactWindow: (String) -> Void = { _ in }
    var editorCommand: (EditorCommandRequest) -> Void = { _ in }
    var revealInFinder: (String) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
    var copyToPasteboard: (String) -> Void = { s in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    var requestWindowClose: () -> Void = {}
    /// Cmd-, / palette "Settings": the app-wide Settings window.
    var openSettingsWindow: () -> Void = {}

    enum Change { case layout, sidebar, tabs, palette, settings, theme, editorFont, content }
    var observers: [(Change) -> Void] = []
    private var notifying = false

    enum EditorCommandRequest: Equatable { case goToToday, autoInsertDaily, collapseAll, expandAll }

    init(dataDir: AppDataDirectory, scheduler: AppScheduler? = nil, importLegacy: Bool = true) {
        self.dataDir = dataDir
        try? dataDir.prepare(importingFrom: importLegacy ? AppDataDirectory.legacyBaseURL : nil)
        let scheduler = scheduler ?? MainQueueScheduler()
        self.scheduler = scheduler
        settings = AppSettings(globalConfigDir: dataDir.baseURL)
        sessionStore = SessionStore(appData: dataDir)
        recentWorkspacesStore = RecentWorkspacesStore(appData: dataDir)
        recentFilesStore = RecentFilesStore(appData: dataDir)
        values = settings.values
        pinnedStore = PinnedStore(url: dataDir.baseURL.appendingPathComponent("sidebar_pinned.json"))
        let box = ReaderBox()
        readerBox = box
        tree = WorkspaceTreeModel(readDirectory: { try box.read($0) })
        let settingsRef = settings
        var writeHook: ((String, String) throws -> Void)?
        let saveEngine = SaveEngine(scheduler: scheduler, processing: { SaveProcessing(settings: settingsRef.values) },
                                    writer: { path, content, done in
                                        do { try writeHook?(path, content); done(.success(())) } catch { done(.failure(error)) }
                                    })
        editor = EditorStore(reader: { path in try WorkspaceFS.readFile(path) }, saveEngine: saveEngine)
        writeHook = { [weak self] path, content in try self?.writeFile(path, content) }
        box.read = { [weak self] path in
            guard let self = self else { return [] }
            return try WorkspaceFS.readDirectory(path, ignore: self.ignore, extensions: self.settings.supportedExtensions,
                                                 dirsWithSupportedFiles: self.index?.isReady == true ? self.index?.dirsWithSupportedFiles : nil)
        }
        sessionAutosaver = SessionAutosaver(editor: editor, store: sessionStore, scheduler: scheduler,
                                            root: { [weak self] in self?.root },
                                            restoreOpenFiles: { [weak self] in self?.values.workspaceRestoreOpenFiles ?? true })
        reconciler = FileChangeReconciler(editor: editor, reader: { path in try WorkspaceFS.readFile(path) })
        reconciler.onSidebarMetadataChanged = { [weak self] in self?.tree.bumpSidebarMetadataVersion(); self?.notify(.sidebar) }
        recentRecorder = RecentFilesRecorder(editor: editor) { [weak self] path in
            guard let self = self, !self.readOnly else { return }
            try? self.recentFilesStore.record(path, extensions: self.settings.supportedExtensions)
        }
        editor.observers.append { [weak self] change in self?.editorChanged(change) }
        editor.onRequestWindowClose = { [weak self] in self?.requestWindowClose() }
        tree.persistPinned = { [weak self] root, pinned in
            guard let self = self, !self.readOnly else { return }
            self.pinnedStore.save(root: root, pinned)
        }
    }

    private let readerBox: ReaderBox
    private let pinnedStore: PinnedStore
    private(set) var values: SettingsValues

    // MARK: notifications

    func notify(_ c: Change) {
        for o in observers { o(c) }
    }

    private func editorChanged(_ change: EditorChange) {
        if editor.tabs != change.previousTabs || editor.activeTabId != change.previousActiveTabId {
            notify(.tabs)
            if let p = editor.activeFilePath, editor.file(p)?.isLoading == false { maybeAutoInsertDaily() }
        } else {
            notify(.content)
        }
    }

    // MARK: settings

    var mode: ThemeMode { ThemeResolver.activeMode(values.appearanceTheme, systemIsDark: systemIsDark()) }
    var palette_: ShellPalette { ShellPalette(settings: values, mode: mode) }

    func setSetting(_ key: String, _ value: ConfigValue) {
        do { try settings.set(key, value, scope: .global) } catch { alert("Failed to save setting: \(error)") }
        settingsDidChange()
    }

    func resetSetting(_ key: String) {
        try? settings.reset(key, scope: .global)
        settingsDidChange()
    }

    func settingsDidChange() {
        let old = values
        values = settings.values
        notify(.settings)
        let editorKeys = ["editor.font-size", "editor.line-height", "editor.heading-space-before", "editor.heading-space-after",
                          "editor.paragraph-spacing", "editor.bullet-spacing", "editor.subheading-color", "fonts.editor", "appearance.theme"]
        let themeChanged = SettingsSchema.all.contains { $0.key.hasPrefix("theme.") && old.raw[$0.key] != values.raw[$0.key] }
        if themeChanged || editorKeys.contains(where: { old.raw[$0] != values.raw[$0] }) { notify(.editorFont) }
        if themeChanged || old.raw["appearance.theme"] != values.raw["appearance.theme"] { notify(.theme) }
        if old.raw["files.associations"] != values.raw["files.associations"] { watcher?.extensions = settings.supportedExtensions }
    }

    // MARK: sidebar visibility (use-sidebar.ts)

    var sidebarPreferenceVisible: Bool { values.appearanceSidebarVisible }
    var isNarrow: Bool { windowWidth < Metrics.narrowWidth }
    /// Effective: preference unless the window is narrower than 850px.
    var sidebarVisible: Bool { sidebarPreferenceVisible && !isNarrow && root != nil }
    var sidebarWidth: CGFloat { Metrics.clampSidebarWidth(values.appearanceSidebarWidth, viewport: windowWidth) }
    var tabStripLeft: CGFloat { sidebarVisible ? sidebarWidth + 12 : Metrics.collapsedTabLeft }

    func toggleSidebar() { setSetting("appearance.sidebar-visible", .bool(!sidebarPreferenceVisible)) }

    // MARK: workspace lifecycle

    /// `openWorkspace` + `restoreFromBundle`: canonical root, listing, pinned,
    /// session restore (or `openFile`), background index.
    func openWorkspace(_ path: String, openFile: String? = nil, keepSession: Bool = true) async {
        if let r = root, r != path {
            openWorkspaceElsewhere(path)
            return
        }
        if root == path, openFile == nil { return }
        let info: WorkspaceInfo
        do {
            info = try WorkspaceBootstrap.open(path, settings: settings, recents: readOnly ? nil : recentWorkspacesStore)
        } catch {
            alert("Failed to open workspace: \(error)")
            return
        }
        values = settings.values
        // No session writes until this workspace's restore has finished: the
        // editor is empty / half-restored until then (quit during startup,
        // a hidden launch, a failed restore must keep the stored session).
        sessionAutosaver.disarm()
        editor.reset()
        root = info.root
        ignore = WorkspaceIgnore.load(root: URL(fileURLWithPath: info.root))
        let idx = FileIndex(root: info.root)
        idx.rebuild(extensions: settings.supportedExtensions)
        index = idx
        isIndexing = false
        let entries = readDirectory(info.root)
        tree.open(root: info.root, entries: entries, recentWorkspaces: recentWorkspacesStore.load(),
                  pinned: pinnedStore.load(root: info.root))
        startWatcher()
        notify(.settings)
        notify(.sidebar)
        let stored = keepSession ? SessionAutosaver.loadSession(store: sessionStore, root: info.root, restoreOpenFiles: values.workspaceRestoreOpenFiles) : nil
        var complete = true
        if let s = stored, !s.tabs.isEmpty {
            complete = await editor.restoreSession(s.tabs, activeIndex: s.activeIndex)
            purgeSettingsTabs()
        }
        // Another openWorkspace/closeWorkspace ran meanwhile: it owns the gate.
        guard root == info.root else { return }
        if let f = openFile {
            // Arm first: the explicitly opened file is a real change to save.
            sessionAutosaver.restoreFinished(complete: complete)
            try? await editor.openFileInTabOrFocus(f)
        } else {
            editor.ensureLauncherTab()
            // Only a faithful restore saves right away; a launcher-only or
            // partial state waits for the user's next tab change.
            sessionAutosaver.restoreFinished(complete: complete && stored.map { !$0.tabs.isEmpty } == true)
        }
        notify(.tabs)
    }

    /// Settings live in their own window: a web-app session's Settings tab is
    /// dropped on restore (the last one leaves a launcher, not a closed window).
    func purgeSettingsTabs() {
        for t in editor.tabs where t.location == .settings {
            if editor.tabs.count == 1 { editor.openNewTab() }
            editor.closeTab(t.id)
        }
    }

    /// Directory listing honouring ignore rules / supported extensions.
    func readDirectory(_ path: String) -> [DirEntry] { (try? readerBox.read(path)) ?? [] }

    func closeWorkspace() {
        guard root != nil else { return }
        sessionAutosaver.flush()
        sessionAutosaver.disarm()
        stopWatcher()
        editor.reset()
        root = nil
        index = nil
        tree.close()
        settings.clearWorkspace()
        values = settings.values
        notify(.sidebar)
        notify(.tabs)
    }

    /// Before the window goes away: flush the session (beforeunload).
    func windowWillClose() {
        sessionAutosaver.flush()
        flushDirtyFiles()
        stopWatcher()
    }

    /// Write every dirty buffer now (window close / quit), bypassing the
    /// 1s throttle so the last edits are never lost.
    func flushDirtyFiles() {
        guard !readOnly else { return }
        for (path, f) in editor.openFiles where f.isDirty && !f.isLoading {
            let full = editor.saveEngine.serializeForSave(frontmatter: f.frontmatter, content: f.content)
            do {
                try writeFile(path, full)
                editor.saveEngine.cancelSave(path)
                editor.markSaved(path, diskContent: full)
            } catch {
                editor.setSaveError(path, error: "\(error)")
            }
        }
    }

    var workspaceName: String {
        guard let r = root else { return "No Workspace" }
        let n = (r as NSString).lastPathComponent
        return n.isEmpty ? r : n
    }

    var fileCount: Int { index?.files.count ?? 0 }

    // MARK: file writes (autosave)

    private func writeFile(_ path: String, _ content: String) throws {
        if readOnly { return }
        try WorkspaceFS.writeFile(path, content: content)
        watcher?.recordWrite(path, nowMs: scheduler.nowMs)
        index?.updateModifiedAt(path, WorkspaceFS.modifiedTime(path))
        tree.bumpSidebarMetadataVersion()
        let dir = (path as NSString).deletingLastPathComponent
        if tree.directoryCache[dir] != nil { try? tree.refreshDirectory(dir) }
        notify(.sidebar)
    }

    // MARK: tree operations (WorkspaceTreeModel)

    func entries(_ dir: String) -> [DirEntry] {
        if let c = tree.directoryCache[dir] { return c }
        try? tree.refreshDirectory(dir)
        return tree.directoryCache[dir] ?? []
    }

    var expanded: Set<String> { tree.expandedDirs }
    func isExpanded(_ path: String) -> Bool { tree.expandedDirs.contains(path) }

    func toggleDirectory(_ path: String) {
        try? tree.toggleDirectory(path)
        notify(.sidebar)
    }

    private func ensureExpanded(_ dir: String) {
        if dir != root && !tree.expandedDirs.contains(dir) { try? tree.toggleDirectory(dir) }
    }

    func refreshDirectory(_ path: String) {
        try? tree.refreshDirectory(path)
        notify(.sidebar)
    }

    func handleDirectoryChanged(_ path: String) {
        tree.handleDirectoryChanged(path)
        notify(.sidebar)
    }

    /// `flattenTree`: visible rows in sidebar order.
    struct FlatItem: Equatable { var entry: DirEntry; var depth: Int }

    func flatTree() -> [FlatItem] {
        guard let root = root else { return [] }
        var out: [FlatItem] = []
        func walk(_ dir: String, _ depth: Int) {
            for e in entries(dir) {
                out.append(FlatItem(entry: e, depth: depth))
                if e.isDir && tree.expandedDirs.contains(e.path) { walk(e.path, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    func visibleFiles() -> [String] { flatTree().filter { !$0.entry.isDir }.map { $0.entry.path } }

    /// Reveal in sidebar: expand ancestors, show the sidebar.
    func revealInSidebar(_ path: String) {
        try? tree.expandAncestors(of: path)
        if !sidebarPreferenceVisible { setSetting("appearance.sidebar-visible", .bool(true)) }
        revealTarget = path
        notify(.sidebar)
    }
    var revealTarget: String?

    // MARK: sidebar sections (use-sidebar-files.ts)

    struct SectionFiles: Equatable { var files: [DirEntry]; var hasMore: Bool }

    var pinnedFiles: [String] { tree.pinnedFiles }

    func pinnedSection() -> SectionFiles {
        guard let root = root, !tree.pinnedFiles.isEmpty else { return SectionFiles(files: [], hasMore: false) }
        let paths = Array(tree.pinnedFiles.prefix(pinnedVisibleCount + 1))
        let entries = WorkspaceFS.readFileEntries(paths, root: root, extensions: settings.supportedExtensions)
        return SectionFiles(files: Array(entries.prefix(pinnedVisibleCount)),
                            hasMore: tree.pinnedFiles.count > pinnedVisibleCount || entries.count > pinnedVisibleCount)
    }

    func recentsSection() -> SectionFiles {
        guard values.appearanceSidebarShowRecents, root != nil, let index = index, index.files.count >= 10 else {
            return SectionFiles(files: [], hasMore: false)
        }
        let pinned = Set(tree.pinnedFiles)
        var unpinned: [DirEntry] = []
        var offset = 0
        while unpinned.count <= recentVisibleCount {
            let page = index.readRecentFiles(limit: 100, offset: offset, extensions: settings.supportedExtensions)
            if page.isEmpty { break }
            unpinned += page.filter { !pinned.contains($0.path) }
            offset += page.count
            if page.count < 100 { break }
        }
        return SectionFiles(files: Array(unpinned.prefix(recentVisibleCount)), hasMore: unpinned.count > recentVisibleCount)
    }

    /// Row label: document title unless `appearance.sidebar-file-label = filename`.
    func label(for e: DirEntry) -> String {
        if e.isDir { return e.name }
        let stem = LinkPaths.getFileStem(e.name)
        if values.appearanceSidebarFileLabel == .filename { return stem }
        if let f = editor.file(e.path), !f.isLoading { return f.title.isEmpty ? stem : f.title }
        if let t = e.title, !t.isEmpty { return t }
        return stem
    }

    func togglePinned(_ path: String) { tree.togglePinnedFile(path); notify(.sidebar) }

    // MARK: file operations (context menus)

    func createFileInFolder(_ folder: String) {
        do {
            let p = try WorkspaceFS.newFilePath(in: folder)
            _ = try WorkspaceFS.createFile(p)
            if tree.expandedDirs.contains(folder) || folder == root { refreshDirectory(folder) } else { ensureExpanded(folder) }
            index?.add(p, modifiedAt: WorkspaceFS.modifiedTime(p))
            renamingPath = p
        } catch { alert("Failed to create file: \(error)") }
    }

    func createFolderInFolder(_ folder: String) {
        do {
            let p = try WorkspaceFS.newFolderPath(in: folder)
            _ = try WorkspaceFS.createDirectory(p)
            if tree.expandedDirs.contains(folder) || folder == root { refreshDirectory(folder) } else { ensureExpanded(folder) }
            renamingPath = p
        } catch { alert("Failed to create folder: \(error)") }
    }

    /// `handleRenameSubmit`: files take a stem, folders a full name.
    func submitRename(_ entry: DirEntry, _ value: String) {
        renamingPath = nil
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parent = LinkPaths.getParentDir(entry.path)
        let newPath: String, conflict: String
        if entry.isDir {
            if trimmed == entry.name { return }
            newPath = "\(parent)/\(trimmed)"
            conflict = "A folder named \"\(trimmed)\" already exists."
        } else {
            let stem = LinkPaths.getFileStem(entry.name)
            if trimmed == stem { return }
            let ext = Self.fileExtension(entry.name)
            newPath = "\(parent)/\(trimmed)\(ext)"
            conflict = "A file named \"\(trimmed)\(ext)\" already exists."
        }
        if newPath == entry.path { return }
        if WorkspaceFS.exists(newPath) { alert(conflict); return }
        do { try applyPathChange(entry, newPath) } catch { alert("Failed to rename: \(error)") }
    }

    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[dot...])
    }

    /// `applyPathChange` (rename or move).
    func applyPathChange(_ entry: DirEntry, _ newPath: String) throws {
        try WorkspaceFS.renameEntry(entry.path, to: newPath)
        watcher?.recordWrite(entry.path, nowMs: scheduler.nowMs)
        if entry.isDir {
            editor.rewritePathPrefix(entry.path, to: newPath)
            tree.rewriteExpandedDir(entry.path, to: newPath)
            // rekeyed listings still carry the old child paths: re-read them
            for dir in tree.directoryCache.keys where dir == newPath || dir.hasPrefix(newPath + "/") { try? tree.refreshDirectory(dir) }
            tree.rewritePinnedPath(entry.path, to: newPath)
            index?.removeSubtree(entry.path)
            index?.addSubtree(newPath, extensions: settings.supportedExtensions)
        } else {
            editor.renameOpenFile(entry.path, to: newPath)
            tree.rewritePinnedPath(entry.path, to: newPath)
            index?.remove(entry.path)
            index?.add(newPath, modifiedAt: WorkspaceFS.modifiedTime(newPath))
        }
        let from = LinkPaths.getParentDir(entry.path), to = LinkPaths.getParentDir(newPath)
        refreshDirectory(from)
        if to != from { refreshDirectory(to) }
    }

    /// Drag-to-move (`moveEntry`): into `destDir`, keeping the name.
    enum MoveOutcome: Equatable { case moved(String), skipped, exists(String), failed(String) }

    func moveEntry(_ entry: DirEntry, into destDir: String) -> MoveOutcome {
        let src = entry.path
        if LinkPaths.getParentDir(src) == destDir || destDir == src || (entry.isDir && destDir.hasPrefix(src + "/")) { return .skipped }
        let newPath = "\(destDir)/\(entry.name)"
        if WorkspaceFS.exists(newPath) { return .exists(newPath) }
        do { try applyPathChange(entry, newPath); return .moved(newPath) } catch { return .failed("\(error)") }
    }

    func deleteEntry(_ entry: DirEntry) {
        if entry.isDir {
            let prefix = entry.path + "/"
            let dirty = editor.openFiles.filter { $0.key.hasPrefix(prefix) && $0.value.isDirty }.count
            if dirty > 0, !confirm("\"\(entry.name)\" contains \(dirty) unsaved file\(dirty > 1 ? "s" : ""). Delete anyway?") { return }
        } else if editor.file(entry.path)?.isDirty == true,
                  !confirm("\"\(entry.name)\" has unsaved changes. Delete anyway?") { return }
        do {
            _ = try WorkspaceFS.deleteEntry(entry.path)
            if entry.isDir {
                editor.removePathsWithPrefix(entry.path)
                tree.removePinnedFilesWithPrefix(entry.path)
                index?.removeSubtree(entry.path)
                tree.invalidatePath(entry.path)
            } else {
                editor.removePathReferences(entry.path)
                tree.removePinnedFile(entry.path)
                index?.remove(entry.path)
            }
            refreshDirectory(LinkPaths.getParentDir(entry.path))
        } catch { alert("Failed to delete: \(error)") }
    }

    func deleteEntries(_ paths: [String]) {
        let dirty = paths.filter { editor.file($0)?.isDirty == true }.count
        let msg = dirty > 0 ? "\(dirty) of \(paths.count) selected items have unsaved changes. Delete anyway?" : "Delete \(paths.count) items?"
        guard confirm(msg) else { return }
        var parents = Set<String>()
        for p in paths {
            do {
                _ = try WorkspaceFS.deleteEntry(p)
                editor.removePathReferences(p)
                tree.removePinnedFile(p)
                tree.removePinnedFilesWithPrefix(p)
                index?.remove(p); index?.removeSubtree(p)
                parents.insert(LinkPaths.getParentDir(p))
            } catch { alert("Failed to delete \"\(p)\": \(error)") }
        }
        selectedPaths = []
        for d in parents { refreshDirectory(d) }
    }

    func duplicate(_ path: String) async {
        do {
            let target = try WorkspaceFS.duplicatePath(for: path)
            let content: String
            if let f = editor.file(path), f.isDirty, !f.isLoading {
                content = Frontmatter.serialize(f.frontmatter, body: f.content)
            } else {
                content = try WorkspaceFS.readFile(path).content
            }
            _ = try WorkspaceFS.createFile(target)
            try WorkspaceFS.writeFile(target, content: content)
            index?.add(target, modifiedAt: WorkspaceFS.modifiedTime(target))
            refreshDirectory(LinkPaths.getParentDir(path))
            try await editor.openFileInNewTab(target)
        } catch { alert("Failed to duplicate: \(error)") }
    }

    func relativePath(_ p: String) -> String { root.map { LinkPaths.getRelativePath(p, root: $0) } ?? p }

    // MARK: tree selection (file-tree.tsx)

    enum Modifier { case none, shift, command }

    /// Pointer-down selection logic. Returns the entries a drag would carry.
    @discardableResult
    func pressRow(_ entry: DirEntry, modifier: Modifier) -> [DirEntry] {
        let flat = flatTree()
        switch modifier {
        case .shift:
            guard let anchor = selectionAnchor ?? flat.first?.entry.path,
                  let a = flat.firstIndex(where: { $0.entry.path == anchor }),
                  let b = flat.firstIndex(where: { $0.entry.path == entry.path }) else { return [] }
            selectedPaths = Set(flat[min(a, b)...max(a, b)].map { $0.entry.path })
            return []
        case .command:
            var next = selectedPaths
            if next.contains(entry.path) { next.remove(entry.path) } else { next.insert(entry.path) }
            selectedPaths = next
            selectionAnchor = entry.path
            return []
        case .none:
            if selectedPaths.count >= 2 && selectedPaths.contains(entry.path) {
                return flat.map { $0.entry }.filter { selectedPaths.contains($0.path) }
            }
            if !selectedPaths.isEmpty { selectedPaths = [] }
            selectionAnchor = entry.path
            return [entry]
        }
    }

    /// Plain click on a tree row: toggle folder / open-or-focus file.
    func clickTreeRow(_ entry: DirEntry) {
        selectedPaths = []
        selectionAnchor = entry.path
        if entry.isDir { toggleDirectory(entry.path) } else { Task { try? await editor.openFileInTabOrFocus(entry.path) } }
    }

    // MARK: actions

    func perform(_ action: ShellAction) {
        switch action {
        case .openPreferences: openSettingsWindow()
        case .newNote: if root != nil && !isCompact { palette = PaletteState(intent: .createFile) }
        case .newTab: if root != nil && !isCompact { editor.openNewTab() }
        case .goToToday: editorCommand(.goToToday)
        case .search: palette = PaletteState(intent: .search)
        case .openFileSearch: if root != nil { palette = PaletteState(intent: .search) }
        case .searchContents: if root != nil && !isCompact { palette = PaletteState(intent: .fullText) }
        case .closeTab: if editor.activeTabId != nil && !isCompact { editor.closeActiveTab() }
        case .toggleSidebar: toggleSidebar()
        case .toggleTypewriter: typewriterScrolling.toggle(); notify(.layout)
        case .fontSizeIncrease: stepFontSize(1)
        case .fontSizeDecrease: stepFontSize(-1)
        case .fontSizeReset: resetSetting("editor.font-size")
        case .collapseHeadings: editorCommand(.collapseAll)
        case .expandHeadings: editorCommand(.expandAll)
        case .back: Task { await editor.navigateBack() }
        case .forward: Task { await editor.navigateForward() }
        case .previousTab: editor.cycleTab(by: -1)
        case .nextTab: editor.cycleTab(by: 1)
        case let .selectTab(n): editor.activateTab(number: n)
        case let .stepFile(delta): stepFile(delta)
        case .closeAllTabs: editor.closeAllTabs()
        case .openWorkspacePanel:
            if let p = pickFolder() { Task { await openWorkspace(p) } }
        case .closeWorkspace: closeWorkspace()
        case .toggleTheme:
            setSetting("appearance.theme", .string(SettingsValues.nextTheme(after: values.appearanceTheme).rawValue))
        case .openInCompactWindow:
            if let p = editor.activeFilePath { openCompactWindow(p) }
        }
    }

    func stepFontSize(_ delta: Double) {
        let base = values.editorFontSize
        let next = min(32, max(10, base + delta))
        if next == base { return }
        setSetting("editor.font-size", .number(next))
    }

    /// Cmd-Alt-↑/↓ (`stepThroughFiles`): no wrap; off-tree starts at an end.
    func stepFile(_ delta: Int) {
        let files = visibleFiles()
        guard !files.isEmpty else { return }
        let current = editor.activeFilePath
        let i = current.flatMap { files.firstIndex(of: $0) } ?? -1
        let target = i == -1 ? (delta > 0 ? 0 : files.count - 1) : i + delta
        guard target >= 0, target < files.count else { return }
        Task { await editor.navigateToFile(files[target]) }
    }

    // MARK: daily note / jump to bottom

    var jumpToEndRequested = false

    /// `maybeInsertDailyHeading`: runs when a pane becomes active and on focus.
    func maybeAutoInsertDaily() {
        guard values.editorAutoInsertDailyHeading else { return }
        editorCommand(.autoInsertDaily)
    }

    // MARK: links (use-prosemark-editor.ts link click → paths.ts)

    enum LinkAction: Equatable {
        case navigate(String, anchor: String?)
        case scrollToAnchor(String)
        case openURL(String)
        case openPath(String)
        case none
    }

    /// Resolve a markdown link clicked in `fromPath`.
    func linkAction(href: String, from fromPath: String) -> LinkAction {
        guard let t = LinkPaths.resolveLinkTarget(href, currentFilePath: fromPath, workspaceRoot: root, fileExists: WorkspaceFS.isFile) else { return .none }
        switch t {
        case let .internalFile(path, anchor): return path == fromPath ? (anchor.map { .scrollToAnchor($0) } ?? .none) : .navigate(path, anchor: anchor)
        case let .sameDocAnchor(a): return .scrollToAnchor(a)
        case let .externalURL(u): return .openURL(u)
        case let .externalPath(p): return .openPath(p)
        }
    }

    /// Resolve a `[[wiki link]]` (fragment ignored; unresolved → none).
    func wikiLinkAction(_ raw: String, from fromPath: String) -> LinkAction {
        guard let root = root else { return .none }
        switch WikiLinkResolver.resolve(raw, workspaceRoot: root, fuzzySearch: { [weak self] q, n in self?.index?.fuzzySearch(q, limit: n) ?? [] },
                                        fileExists: WorkspaceFS.isFile, currentFilePath: fromPath) {
        case let .internalFile(p): return p == fromPath ? .none : .navigate(p, anchor: nil)
        case .unresolved: return .none
        }
    }

    /// Heading to scroll to after a navigation with `#anchor`.
    var pendingAnchor: (path: String, slug: String)?
    /// "Heading \"#x\" not found in this document" banner text.
    var anchorWarning: String? { didSet { notify(.layout) } }
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var scrollToAnchor: (String) -> Bool = { _ in false }

    func perform(link a: LinkAction) {
        switch a {
        case let .navigate(path, anchor):
            if let anchor = anchor { pendingAnchor = (path, anchor) }
            Task { await editor.navigateToFile(path) }
        case let .scrollToAnchor(slug):
            if !scrollToAnchor(slug) { anchorWarning = "Heading \"#\(slug)\" not found in this document" }
        case let .openURL(u): if let url = URL(string: u) { openExternal(url) }
        case let .openPath(p): openExternal(URL(fileURLWithPath: p))
        case .none: break
        }
    }

    // MARK: drops (use-image-drop.ts / use-open-drop.ts)

    /// Copy dropped images next to the note; the markdown to insert (nil if none imported).
    func importDroppedImages(_ sources: [String], into notePath: String) -> [String] {
        var snippets: [String] = []
        for src in sources {
            do {
                let saved = try WorkspaceFS.importImageFile(markdownFilePath: notePath, sourcePath: src)
                let name = LinkPaths.getFileName(src)
                let alt = name.range(of: "\\.[^.]+$", options: .regularExpression).map { String(name[..<$0.lowerBound]) } ?? name
                snippets.append("![\(alt)](\(LinkPaths.formatMarkdownDestination(saved.relativePath)))")
            } catch { continue }
        }
        return snippets
    }

    /// Insertion for dropped image snippets at `caret` (own lines, caret after).
    static func imageDropEdit(snippets: [String], lineStart: Bool) -> String {
        (lineStart ? "" : "\n") + snippets.joined(separator: "\n") + "\n"
    }

    /// Paths from a Finder drop that are not images (folders / notes to open).
    var openDroppedPaths: ([String]) -> Void = { _ in }

    /// Welcome screen "Open File…": the note opens on its own (compact window), like a
    /// Finder open. Its folder is NOT opened as a workspace: no scan, no sidebar, not
    /// added to recent workspaces (a note in ~/Downloads used to pull in the whole folder).
    var closeWindow: () -> Void = {}
    func openPickedFile(_ path: String) {
        openDroppedPaths([path])
        if root == nil && editor.tabs.isEmpty { closeWindow() }
    }

    // MARK: palette (command-palette/index.tsx)

    /// A standalone (compact) file window: no workspace, one file tab.
    var isCompact: Bool { root == nil && !editor.tabs.isEmpty }

    func paletteCommands() -> [PaletteItem] {
        var out: [PaletteItem] = []
        func add(_ id: String, _ label: String, _ desc: String = "Command") { out.append(PaletteItem(kind: .command(id), title: label, subtitle: desc)) }
        let compact = isCompact
        if root != nil && !compact { add("toggle-sidebar", "Toggle Sidebar") }
        if root != nil && !compact { add("search-contents", "Search in All Notes") }
        if root != nil || (compact && editor.activeFilePath != nil) { add("new-file", "Create New File") }
        if root != nil && editor.activeFilePath != nil { add("open-in-compact-window", "Open File in Compact Window") }
        if editor.activeTabId != nil && !compact { add("close-tab", "Close Current Tab") }
        if !editor.tabs.isEmpty && !compact { add("close-all", "Close All Tabs") }
        add("open-workspace", "Open Workspace")
        if root != nil { add("close-workspace", "Close Workspace") }
        add("toggle-theme", "Toggle Dark Mode")
        add("open-settings", "Settings", "App preferences")
        return out
    }

    struct PaletteView: Equatable {
        var heading: String?
        var empty: String?
        var items: [PaletteItem]
        var placeholder: String
    }

    func paletteView() -> PaletteView? {
        guard let p = palette else { return nil }
        let q = p.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.intent == .createFile {
            // compact windows create next to the active file
            let base = root ?? editor.activeFilePath.map(LinkPaths.getParentDir)
            guard let root = base, !q.isEmpty, let path = WorkspaceFS.paletteCreatePath(root: root, rawName: q) else {
                return PaletteView(heading: nil, empty: q.isEmpty ? "Type a note name to create it." : nil, items: [], placeholder: "Create a new note...")
            }
            return PaletteView(heading: "Create note", empty: nil,
                               items: [PaletteItem(kind: .create(path), title: "Create: \(LinkPaths.getFileName(path))")],
                               placeholder: "Create a new note...")
        }
        if p.intent == .fullText {
            let items = contentResults.map {
                PaletteItem(kind: .hit(path: $0.path, offset: $0.offset, length: $0.length),
                            title: "\(LinkPaths.getFileStem(LinkPaths.getFileName($0.path)))  ·  line \($0.line)",
                            subtitle: $0.snippet, highlights: $0.highlights)
            }
            if items.isEmpty {
                let empty = q.count < 2 ? "Type at least two characters to search inside your notes." : (isIndexing ? "Indexing workspace..." : "No notes contain \"\(q)\".")
                return PaletteView(heading: nil, empty: empty, items: [], placeholder: "Search in all notes...")
            }
            return PaletteView(heading: "In notes", empty: nil, items: items, placeholder: "Search in all notes...")
        }
        let cmds = q.isEmpty ? paletteCommands() : paletteCommands().filter { $0.title.lowercased().contains(q.lowercased()) }
        var files = q.isEmpty || isCompact ? [] : paletteResults.map {
            PaletteItem(kind: .file($0.path), title: LinkPaths.getFileName($0.path), subtitle: $0.relativePath,
                        highlights: $0.matchIndices.map { Int($0) })
        }
        if isCompact && !q.isEmpty {
            // compact windows filter the global recents client-side
            let ql = q.lowercased()
            files = recentFilesStore.list(limit: 30, extensions: settings.supportedExtensions).filter {
                ($0.title ?? "").lowercased().contains(ql) || $0.name.lowercased().contains(ql) || $0.path.lowercased().contains(ql)
            }.map { PaletteItem(kind: .file($0.path), title: ($0.title?.isEmpty == false ? $0.title! : LinkPaths.getFileStem($0.name)),
                                subtitle: LinkPaths.getParentDir($0.path)) }
        }
        let items = cmds + files
        if items.isEmpty {
            return PaletteView(heading: nil, empty: isIndexing && !q.isEmpty ? "Indexing workspace..." : "No results found.", items: [], placeholder: "Search...")
        }
        let heading = q.isEmpty ? "Suggested" : (isIndexing ? "Results (indexing...)" : "Results")
        return PaletteView(heading: heading, empty: nil, items: items, placeholder: "Search...")
    }

    /// Query changed: fuzzy search (20 results, the web's `useFuzzySearch` limit).
    func setPaletteQuery(_ q: String) {
        guard var p = palette else { return }
        p.query = q
        p.selected = 0
        if p.intent == .fullText {
            let open = Dictionary(editor.tabs.compactMap { t -> (String, String)? in
                guard let path = t.location.primaryPath, let f = editor.file(path), !f.isLoading else { return nil }
                return (path, f.content)
            }, uniquingKeysWith: { a, _ in a })
            contentResults = contentSearch.search(q, in: index?.files ?? [], overrides: open)
        } else if p.intent == .search, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            paletteResults = index?.fuzzySearch(q, limit: 20) ?? []
        } else {
            paletteResults = []
        }
        palette = p
    }

    func movePaletteSelection(_ delta: Int) {
        guard var p = palette, let v = paletteView(), !v.items.isEmpty else { return }
        p.selected = min(v.items.count - 1, max(0, p.selected + delta))
        palette = p
    }

    func runPaletteItem(_ item: PaletteItem) {
        switch item.kind {
        case let .file(path):
            palette = nil
            if isCompact { Task { await editor.openCompactFile(path) } } else { Task { try? await editor.openFileInTabOrFocus(path) } }
        case let .hit(path, offset, length):
            palette = nil
            pendingReveal = (path, offset, length)
            Task { try? await editor.openFileInTabOrFocus(path); notify(.content) }
        case let .create(path):
            palette = nil
            Task {
                do {
                    _ = try WorkspaceFS.createFile(path)
                    index?.add(path, modifiedAt: WorkspaceFS.modifiedTime(path))
                    refreshDirectory(LinkPaths.getParentDir(path))
                } catch { /* already exists: open it */ }
                if isCompact { await editor.openCompactFile(path) } else { try? await editor.openFileInTabOrFocus(path) }
            }
        case let .command(id):
            switch id {
            case "toggle-sidebar": palette = nil; toggleSidebar()
            case "search-contents": palette = PaletteState(intent: .fullText); contentResults = []
            case "new-file": palette = PaletteState(intent: .createFile)
            case "open-in-compact-window": palette = nil; perform(.openInCompactWindow)
            case "close-tab": palette = nil; perform(.closeTab)
            case "close-all": palette = nil; editor.closeAllTabs()
            case "open-workspace": palette = nil; perform(.openWorkspacePanel)
            case "close-workspace": palette = nil; closeWorkspace()
            case "toggle-theme": palette = nil; perform(.toggleTheme)
            case "open-settings": palette = nil; openSettingsWindow()
            default: palette = nil
            }
        }
    }

    func runSelectedPaletteItem() {
        guard let p = palette, let v = paletteView(), p.selected < v.items.count else { return }
        runPaletteItem(v.items[p.selected])
    }

    // MARK: watcher

    private var fsStream: FSEventsStream?
    private var tickTimer: Timer?

    private func startWatcher() {
        stopWatcher()
        guard let root = root, !readOnly, watcherEnabled else { return }
        let w = WorkspaceWatcherModel(root: root, ignore: ignore, extensions: settings.supportedExtensions, index: index, startMs: scheduler.nowMs)
        watcher = w
        fsStream = FSEventsStream(path: root) { [weak self] events in
            guard let self = self else { return }
            for e in events { self.handleWatcherOutputs(w.ingest(e, nowMs: self.scheduler.nowMs)) }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, let w = self.watcher else { return }
                self.handleWatcherOutputs(w.tick(nowMs: self.scheduler.nowMs))
            }
        }
    }

    private func stopWatcher() {
        fsStream?.stop()
        fsStream = nil
        tickTimer?.invalidate()
        tickTimer = nil
        watcher = nil
    }

    /// Route watcher outputs (`use-file-watcher.ts`).
    func handleWatcherOutputs(_ outs: [WatcherOutput]) {
        for o in outs {
            switch o {
            case let .fileChanged(path, kind):
                Task { if await reconciler.handleFileChanged(path: path, kind: kind) { notify(.content) } }
            case let .directoryChanged(path, _):
                handleDirectoryChanged(path)
            case .settingsChanged:
                settings.reloadWorkspace()
                settingsDidChange()
            case .rebuildIgnore:
                if let r = root { ignore = WorkspaceIgnore.load(root: URL(fileURLWithPath: r)); watcher?.ignore = ignore }
            }
        }
    }
}

/// Pinned files per workspace root (the web app keeps them in localStorage).
struct PinnedStore {
    let url: URL
    func load(root: String) -> [String] {
        guard let d = try? Data(contentsOf: url), let j = try? JSON.parse(data: d) else { return [] }
        return (j[root]?.arrayValue ?? []).compactMap { $0.stringValue }
    }
    func save(root: String, _ pinned: [String]) {
        var pairs: [(String, JSONValue)] = []
        if let d = try? Data(contentsOf: url), let j = try? JSON.parse(data: d), case let .object(p) = j { pairs = p }
        pairs.removeAll { $0.0 == root }
        pairs.append((root, .array(pinned.map { .string($0) })))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(JSON.prettyString(.object(pairs)).utf8).write(to: url)
    }
}

/// Late-bound directory reader for `WorkspaceTreeModel` (needs `self`).
final class ReaderBox {
    var read: (String) throws -> [DirEntry] = { _ in [] }
}

import Foundation

// MARK: - Locations (page-kinds)

/// What a tab shows (`page-kinds`: file / launcher / settings).
public enum TabLocation: Equatable, Hashable {
    case file(String)
    case launcher
    case settings

    public var kind: String {
        switch self {
        case .file: return "file"
        case .launcher: return "launcher"
        case .settings: return "settings"
        }
    }

    /// `paths()`.
    public var paths: [String] { if case let .file(p) = self { return [p] }; return [] }
    /// `primaryPath()`.
    public var primaryPath: String? { if case let .file(p) = self { return p }; return nil }
    public var isLauncher: Bool { self == .launcher }
    public var isFile: Bool { if case .file = self { return true }; return false }
    /// Kept mounted while hidden.
    public var keepAlive: Bool { self != .launcher }

    /// Fallback tab title (document titles win for files).
    public var fallbackTitle: String {
        switch self {
        case let .file(p): return LinkPaths.getFileName(p)
        case .launcher: return "New tab"
        case .settings: return "Settings"
        }
    }

    /// `rewritePath` (rename/move).
    public func rewritingPath(from: String, to: String) -> TabLocation? {
        if case let .file(p) = self, p == from { return .file(to) }
        return self
    }

    /// `removePath` (delete): nil invalidates the location.
    public func removingPath(_ path: String) -> TabLocation? {
        if case let .file(p) = self, p == path { return nil }
        return self
    }

    /// `serializeLocation`: launcher tabs are transient (nil).
    public var serialized: SerializedLocation? {
        switch self {
        case let .file(p): return SerializedLocation(kind: "file", payload: [("path", .string(p))])
        case .launcher: return nil
        case .settings: return SerializedLocation(kind: "settings", payload: [])
        }
    }

    /// `deserializeLocation`: unknown kinds / bad payloads → nil.
    public init?(serialized: SerializedLocation?) {
        guard let s = serialized else { return nil }
        switch s.kind {
        case "file":
            guard case let .string(p)? = s.payload.first(where: { $0.0 == "path" })?.1 else { return nil }
            self = .file(p)
        case "launcher": self = .launcher
        case "settings": self = .settings
        default: return nil
        }
    }
}

/// Session-persisted location: `kind` + free-form payload (round-trips unknown fields).
public struct SerializedLocation: Equatable {
    public var kind: String
    public var payload: [(String, JSONValue)]

    public init(kind: String, payload: [(String, JSONValue)]) { self.kind = kind; self.payload = payload }

    public static func == (a: SerializedLocation, b: SerializedLocation) -> Bool {
        a.kind == b.kind && JSONValue.object(a.payload) == JSONValue.object(b.payload)
    }

    public var json: JSONValue { .object([("kind", .string(kind))] + payload.filter { $0.0 != "kind" }) }

    public init?(json: JSONValue) {
        guard case let .object(pairs) = json, let kind = json["kind"]?.stringValue else { return nil }
        self.kind = kind
        self.payload = pairs.filter { $0.0 != "kind" }
    }
}

public struct Tab: Equatable {
    public var id: String
    public var location: TabLocation
    public var back: [TabLocation]
    public var forward: [TabLocation]

    public init(id: String, location: TabLocation, back: [TabLocation] = [], forward: [TabLocation] = []) {
        self.id = id; self.location = location; self.back = back; self.forward = forward
    }

    /// Every path referenced by the location or its history (`tabPaths`), deduped in order.
    public var allPaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in location.paths + back.flatMap({ $0.paths }) + forward.flatMap({ $0.paths }) where seen.insert(p).inserted {
            out.append(p)
        }
        return out
    }

    func applying(_ rewrite: (TabLocation) -> TabLocation?) -> Tab? {
        guard let loc = rewrite(location) else { return nil }
        return Tab(id: id, location: loc, back: back.compactMap(rewrite), forward: forward.compactMap(rewrite))
    }
}

public struct SessionTab: Equatable {
    public var location: SerializedLocation
    public var back: [SerializedLocation]
    public var forward: [SerializedLocation]
    public init(location: SerializedLocation, back: [SerializedLocation] = [], forward: [SerializedLocation] = []) {
        self.location = location; self.back = back; self.forward = forward
    }
}

public struct OpenFile: Equatable {
    public var path: String
    public var frontmatter: String?
    /// Editor text (body without frontmatter).
    public var content: String
    public var title: String
    public var titleSource: TitleSource
    /// Last content known to be on disk (the full file text).
    public var diskContent: String
    public var isDirty: Bool
    public var isLoading: Bool
    public var saveError: String?
    public var reloadVersion: Int
    public var scrollPos: Double
    public var cursorPos: Int
    public var displayDate: String?
    public var stats: DocumentStats

    static func loading(_ path: String) -> OpenFile {
        OpenFile(path: path, frontmatter: nil, content: "", title: "", titleSource: .none, diskContent: "", isDirty: false,
                 isLoading: true, saveError: nil, reloadVersion: 0, scrollPos: 0, cursorPos: 0, displayDate: nil, stats: .empty)
    }

    /// Display title: document title, else the file name.
    public var displayTitle: String { title.isEmpty ? LinkPaths.getFileName(path) : title }
}

/// Change notification: the state before the mutation.
public struct EditorChange {
    public let previousTabs: [Tab]
    public let previousActiveTabId: String?
    public let previousActiveFilePath: String?
}

// MARK: - Store

/// Tabs, per-tab history and open-file state (port of `editor-store.ts`).
@MainActor
public final class EditorStore: SaveEngineHost {
    public typealias Reader = @MainActor (String) async throws -> FileContent

    public private(set) var openFiles: [String: OpenFile] = [:]
    public private(set) var tabs: [Tab] = []
    public private(set) var activeTabId: String?
    public private(set) var activeFilePath: String?

    /// Called after every state change with the previous tab state.
    public var observers: [(EditorChange) -> Void] = []
    /// Closing the last tab closes the window.
    public var onRequestWindowClose: (() -> Void)?

    public let saveEngine: SaveEngine
    private let reader: Reader
    private let displayDate: (String?) -> String?
    /// `OPEN_FILE_GRACE_MS`.
    public var openGraceNanoseconds: UInt64 = 40_000_000

    private var pendingLoads: [String: Task<Void, Error>] = [:]
    private var navigationVersions: [String: Int] = [:]
    private var tabSequence = 0

    public init(reader: @escaping Reader, saveEngine: SaveEngine, displayDate: @escaping (String?) -> String? = { Frontmatter.displayDate($0) }) {
        self.reader = reader
        self.saveEngine = saveEngine
        self.displayDate = displayDate
        saveEngine.host = self
    }

    // MARK: State plumbing

    private func mutate(_ body: () -> Void) {
        let change = EditorChange(previousTabs: tabs, previousActiveTabId: activeTabId, previousActiveFilePath: activeFilePath)
        body()
        for o in observers { o(change) }
    }

    /// Replace everything (the web app's `useEditorStore.setState({...})` resets).
    public func reset() {
        mutate {
            openFiles = [:]
            tabs = []
            activeTabId = nil
            activeFilePath = nil
        }
    }

    public func file(_ path: String) -> OpenFile? { openFiles[path] }
    public var activeTab: Tab? { tabs.first { $0.id == activeTabId } }

    private func createTabId() -> String {
        tabSequence += 1
        return "tab-\(tabSequence)"
    }

    public func makeLauncherTab() -> Tab { Tab(id: createTabId(), location: .launcher) }
    public func makeFileTab(_ path: String) -> Tab { Tab(id: createTabId(), location: .file(path)) }
    public func makeSettingsTab() -> Tab { Tab(id: createTabId(), location: .settings) }

    private func deriveActiveFilePath(_ tabs: [Tab], _ activeId: String?) -> String? {
        tabs.first { $0.id == activeId }?.location.primaryPath
    }

    private func index(of tabId: String) -> Int? { tabs.firstIndex { $0.id == tabId } }

    private func referencedPaths(_ tabs: [Tab]) -> Set<String> {
        Set(tabs.flatMap { $0.allPaths })
    }

    /// `maybePruneFiles`: drop clean files no longer referenced by any tab.
    private func pruneFiles(nextTabs: [Tab], candidates: [String]) {
        let referenced = referencedPaths(nextTabs)
        for path in candidates where !referenced.contains(path) {
            guard let f = openFiles[path], !f.isDirty else { continue }
            saveEngine.cancelSave(path)
            openFiles[path] = nil
        }
    }

    private func startNavigation(_ tabId: String) -> Int {
        let v = (navigationVersions[tabId] ?? 0) + 1
        navigationVersions[tabId] = v
        return v
    }

    private func isNavigationCurrent(_ tabId: String, _ version: Int) -> Bool { navigationVersions[tabId] == version }

    private func withDerived(_ f: OpenFile) -> OpenFile {
        var f = f
        f.displayDate = displayDate(f.frontmatter)
        f.stats = DocumentStatsCalculator.stats(f.content)
        return f
    }

    private func loaded(_ base: OpenFile, raw: String) -> OpenFile {
        let parsed = Frontmatter.parseDocument(raw)
        var f = base
        f.frontmatter = parsed.frontmatter
        f.content = parsed.body
        f.title = parsed.title
        f.titleSource = parsed.titleSource
        f.diskContent = raw
        f.isLoading = false
        return withDerived(f)
    }

    // MARK: Loading

    /// `ensureFileLoaded`: one read per path at a time; a failed read removes
    /// the placeholder and rethrows.
    public func ensureFileLoaded(_ path: String) async throws {
        if let existing = openFiles[path], !existing.isLoading { return }
        if let pending = pendingLoads[path] {
            try await pending.value
            return
        }
        if openFiles[path] == nil {
            mutate { openFiles[path] = .loading(path) }
        }
        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.pendingLoads[path] = nil }
            do {
                let raw = try await self.reader(path)
                guard let file = self.openFiles[path] else { return }
                self.mutate { self.openFiles[path] = self.loaded(file, raw: raw.content) }
            } catch {
                if self.openFiles[path] != nil { self.mutate { self.openFiles[path] = nil } }
                throw error
            }
        }
        pendingLoads[path] = task
        try await task.value
    }

    private func seedLoadingIfNeeded(_ path: String) {
        if openFiles[path] == nil { openFiles[path] = .loading(path) }
    }

    // MARK: Opening

    /// `openFile` (Pinned/Recents click): fill an active launcher, navigate in
    /// place in an active file tab, else create a tab (after a short grace so
    /// failed reads never flash a tab).
    public func openFile(_ path: String) async {
        if let active = activeTab {
            if active.location.isLauncher { await replaceTabWithFile(active.id, path: path); return }
            if active.location.isFile { await navigateToFile(path); return }
        }
        let load = Task { @MainActor in try await self.ensureFileLoaded(path) }
        let grace = openGraceNanoseconds
        let failedBeforeGrace = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { do { try await load.value; return false } catch { return true } }
            group.addTask { try? await Task.sleep(nanoseconds: grace); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if failedBeforeGrace { return }
        let next = makeFileTab(path)
        mutate {
            tabs.append(next)
            activeTabId = next.id
            activeFilePath = path
        }
        do { try await load.value } catch { closeTab(next.id) }
    }

    /// `openCompactFile`: the compact window shows exactly one file tab.
    public func openCompactFile(_ path: String, prefetched: FileContent? = nil) async {
        if let pre = prefetched, pre.path == path {
            mutate { openFiles[path] = loaded(.loading(path), raw: pre.content) }
        }
        let previousIds = tabs.map { $0.id }
        let load = Task { @MainActor in try await self.ensureFileLoaded(path) }
        let next = makeFileTab(path)
        mutate {
            var seen = Set<String>()
            let candidates = tabs.flatMap { $0.allPaths.filter { $0 != path } }.filter { seen.insert($0).inserted }
            seedLoadingIfNeeded(path)
            let nextTabs = [next]
            pruneFiles(nextTabs: nextTabs, candidates: candidates)
            tabs = nextTabs
            activeTabId = next.id
            activeFilePath = path
        }
        for id in previousIds { navigationVersions[id] = nil }
        do { try await load.value } catch { closeTab(next.id) }
    }

    /// `openFileInTabOrFocus` (file-tree click): focus an existing tab for the
    /// file, else fill an active launcher, else open a new tab.
    public func openFileInTabOrFocus(_ path: String) async throws {
        if let existing = tabs.first(where: { $0.location == .file(path) }) {
            setActiveTab(existing.id)
            return
        }
        if let active = activeTab, active.location.isLauncher {
            await replaceTabWithFile(active.id, path: path)
            return
        }
        try await openFileInNewTab(path)
    }

    public struct OpenFailed: Error, Equatable { public let path: String }

    /// `openFileInNewTab`: always a fresh tab; removed again if loading fails.
    public func openFileInNewTab(_ path: String) async throws {
        let next = makeFileTab(path)
        mutate {
            tabs.append(next)
            activeTabId = next.id
            activeFilePath = path
            seedLoadingIfNeeded(path)
        }
        do { try await ensureFileLoaded(path) } catch {
            closeTab(next.id)
            throw OpenFailed(path: path)
        }
    }

    /// `openNewTab`: append and activate a launcher.
    public func openNewTab() {
        let next = makeLauncherTab()
        mutate {
            tabs.append(next)
            activeTabId = next.id
            activeFilePath = nil
        }
    }

    public func ensureLauncherTab() {
        guard tabs.isEmpty else { return }
        let launcher = makeLauncherTab()
        mutate {
            tabs = [launcher]
            activeTabId = launcher.id
            activeFilePath = nil
        }
    }

    /// `openOrFocus`: focus a matching tab, else replace an active launcher
    /// (keeping its id), else append.
    public func openOrFocus(match: (Tab) -> Bool, factory: () -> Tab) {
        if let existing = tabs.first(where: match) {
            if existing.id != activeTabId { setActiveTab(existing.id) }
            return
        }
        let active = activeTab
        let next = factory()
        mutate {
            if let active = active, active.location.isLauncher, let idx = index(of: active.id) {
                tabs[idx] = Tab(id: active.id, location: next.location, back: next.back, forward: next.forward)
                activeTabId = active.id
                activeFilePath = deriveActiveFilePath(tabs, active.id)
                return
            }
            tabs.append(next)
            activeTabId = next.id
            activeFilePath = deriveActiveFilePath(tabs, next.id)
        }
    }

    /// Preferences… (⌘,): open or focus the Settings tab.
    public func openSettingsTab() {
        openOrFocus(match: { $0.location == .settings }, factory: { makeSettingsTab() })
    }

    /// `replaceTabWithFile`: turn a launcher tab into a file tab (same id).
    public func replaceTabWithFile(_ tabId: String, path: String) async {
        guard let target = tabs.first(where: { $0.id == tabId }), target.location.isLauncher else {
            await openFile(path)
            return
        }
        let version = startNavigation(tabId)
        mutate {
            guard let idx = index(of: tabId), tabs[idx].location.isLauncher else { return }
            tabs[idx] = Tab(id: tabId, location: .file(path))
            if activeTabId == tabId { activeFilePath = path }
            seedLoadingIfNeeded(path)
        }
        do { try await ensureFileLoaded(path) } catch {
            guard isNavigationCurrent(tabId, version) else { return }
            mutate {
                guard let idx = index(of: tabId), tabs[idx].location == .file(path) else {
                    pruneFiles(nextTabs: tabs, candidates: [path])
                    return
                }
                var next = tabs
                next[idx] = target
                pruneFiles(nextTabs: next, candidates: [path])
                tabs = next
                if activeTabId == tabId { activeFilePath = nil }
            }
        }
    }

    // MARK: Closing

    /// `closeFile`: close the active tab if it shows `path`, else the first tab that does.
    public func closeFile(_ path: String) {
        if let active = activeTab, active.location == .file(path) { closeTab(active.id); return }
        if let t = tabs.first(where: { $0.location == .file(path) }) { closeTab(t.id) }
    }

    /// `closeTab`: the right neighbour becomes active, else the left one.
    /// Closing the last tab leaves no tabs and asks the window to close.
    public func closeTab(_ tabId: String) {
        let isLastTab = tabs.count == 1 && tabs[0].id == tabId
        guard let idx = index(of: tabId) else {
            navigationVersions[tabId] = nil
            return
        }
        mutate {
            let closed = tabs[idx]
            var next = tabs
            next.remove(at: idx)
            var nextActive = activeTabId
            if next.isEmpty && !isLastTab {
                let launcher = makeLauncherTab()
                next = [launcher]
                nextActive = launcher.id
            } else if next.isEmpty {
                nextActive = nil
            } else if activeTabId == tabId {
                nextActive = idx < next.count ? next[idx].id : (idx - 1 >= 0 ? next[idx - 1].id : nil)
            }
            pruneFiles(nextTabs: next, candidates: closed.allPaths)
            tabs = next
            activeTabId = nextActive
            activeFilePath = deriveActiveFilePath(next, nextActive)
        }
        navigationVersions[tabId] = nil
        if isLastTab { onRequestWindowClose?() }
    }

    public func closeActiveTab() {
        if let id = activeTabId { closeTab(id) }
    }

    /// Tab context menu "Close others".
    public func closeOtherTabs(_ keepId: String) {
        for t in tabs where t.id != keepId { closeTab(t.id) }
    }

    /// Tab context menu "Close all" (closes the window at the end).
    public func closeAllTabs() {
        for t in tabs { closeTab(t.id) }
    }

    // MARK: Activation

    public func setActiveFile(_ path: String) {
        guard let t = tabs.first(where: { $0.location == .file(path) }) else { return }
        mutate {
            activeTabId = t.id
            activeFilePath = path
        }
    }

    public func setActiveTab(_ tabId: String) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        mutate {
            activeTabId = tabId
            activeFilePath = deriveActiveFilePath(tabs, tabId)
        }
    }

    /// Cmd-Shift-[ / ] and Ctrl-(Shift-)Tab: cycle with wrap-around.
    public func cycleTab(by delta: Int) {
        guard !tabs.isEmpty else { return }
        let current = activeTabId.flatMap { index(of: $0) } ?? 0
        let n = tabs.count
        setActiveTab(tabs[((current + delta) % n + n) % n].id)
    }

    /// Cmd-1…9: jump to tab N (1-based); out of range is a no-op.
    public func activateTab(number: Int) {
        guard number >= 1, number <= tabs.count else { return }
        setActiveTab(tabs[number - 1].id)
    }

    // MARK: Navigation

    /// `navigateToFile`: in-place navigation in the active tab, pushing history.
    public func navigateToFile(_ path: String) async {
        guard let active = activeTab else { await openFile(path); return }
        if active.location.isLauncher { await replaceTabWithFile(active.id, path: path); return }
        if active.location == .file(path) { return }
        let previous = active
        let next = Tab(id: active.id, location: .file(path), back: active.back + [active.location], forward: [])
        let version = startNavigation(active.id)
        mutate {
            guard let idx = index(of: active.id) else { return }
            tabs[idx] = next
            if activeTabId == active.id { activeFilePath = path }
            seedLoadingIfNeeded(path)
        }
        do { try await ensureFileLoaded(path) } catch {
            revert(active.id, to: previous, version: version, failedPath: path)
        }
    }

    private func revert(_ tabId: String, to previous: Tab, version: Int, failedPath: String) {
        guard isNavigationCurrent(tabId, version) else { return }
        mutate {
            guard let idx = index(of: tabId) else { return }
            var next = tabs
            next[idx] = previous
            pruneFiles(nextTabs: next, candidates: [failedPath])
            tabs = next
            if activeTabId == tabId { activeFilePath = previous.location.primaryPath }
        }
    }

    public var canNavigateBack: Bool { !(activeTab?.back.isEmpty ?? true) }
    public var canNavigateForward: Bool { !(activeTab?.forward.isEmpty ?? true) }

    public func navigateBack() async {
        guard let active = activeTab, let target = active.back.last else { return }
        let previous = active
        let next = Tab(id: active.id, location: target, back: Array(active.back.dropLast()), forward: [active.location] + active.forward)
        await navigateHistory(active: active, previous: previous, next: next, target: target)
    }

    public func navigateForward() async {
        guard let active = activeTab, let target = active.forward.first else { return }
        let previous = active
        let next = Tab(id: active.id, location: target, back: active.back + [active.location], forward: Array(active.forward.dropFirst()))
        await navigateHistory(active: active, previous: previous, next: next, target: target)
    }

    private func navigateHistory(active: Tab, previous: Tab, next: Tab, target: TabLocation) async {
        let targetPath = target.primaryPath
        let version = startNavigation(active.id)
        mutate {
            guard let idx = index(of: active.id) else { return }
            tabs[idx] = next
            if activeTabId == active.id { activeFilePath = targetPath }
        }
        guard let path = targetPath else { return }
        do { try await ensureFileLoaded(path) } catch {
            revert(active.id, to: previous, version: version, failedPath: path)
        }
    }

    // MARK: Path maintenance (rename / delete)

    /// `renameOpenFile`.
    public func renameOpenFile(_ oldPath: String, to newPath: String) {
        guard let file = openFiles[oldPath] else { return }
        let dirty = file.isDirty
        mutate {
            openFiles[oldPath] = nil
            var moved = file
            moved.path = newPath
            openFiles[newPath] = moved
            tabs = tabs.map { $0.applying { $0.rewritingPath(from: oldPath, to: newPath) } ?? $0 }
            if activeFilePath == oldPath { activeFilePath = newPath }
        }
        saveEngine.cancelSave(oldPath)
        if dirty { saveEngine.scheduleSave(newPath) }
    }

    /// `removePathReferences`: after a delete.
    public func removePathReferences(_ path: String) {
        mutate {
            let next = tabs.compactMap { $0.applying { $0.removingPath(path) } }
            var nextActive = activeTabId
            if !next.contains(where: { $0.id == nextActive }) { nextActive = next.first?.id }
            tabs = next
            activeTabId = nextActive
            activeFilePath = deriveActiveFilePath(next, nextActive)
            openFiles[path] = nil
        }
        saveEngine.cancelSave(path)
        if tabs.isEmpty { ensureLauncherTab() }
    }

    /// `removePathsWithPrefix`: after deleting a folder.
    public func removePathsWithPrefix(_ prefix: String) {
        let dirPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        let matches: (String) -> Bool = { $0 == prefix || $0.hasPrefix(dirPrefix) }
        var cancelled: [String] = []
        mutate {
            let transform: (TabLocation) -> TabLocation? = { loc in
                for p in loc.paths where matches(p) { return loc.removingPath(p) }
                return loc
            }
            let next = tabs.compactMap { $0.applying(transform) }
            var nextActive = activeTabId
            if !next.contains(where: { $0.id == nextActive }) { nextActive = next.first?.id }
            for p in openFiles.keys.sorted() where matches(p) {
                cancelled.append(p)
                openFiles[p] = nil
            }
            tabs = next
            activeTabId = nextActive
            activeFilePath = deriveActiveFilePath(next, nextActive)
        }
        for p in cancelled { saveEngine.cancelSave(p) }
        if tabs.isEmpty { ensureLauncherTab() }
    }

    /// `rewritePathPrefix`: after renaming a folder.
    public func rewritePathPrefix(_ oldPrefix: String, to newPrefix: String) {
        let dirPrefix = oldPrefix.hasSuffix("/") ? oldPrefix : oldPrefix + "/"
        let rewrite: (String) -> String = { p in
            if p == oldPrefix { return newPrefix }
            if p.hasPrefix(dirPrefix) { return newPrefix + p.dropFirst(oldPrefix.count) }
            return p
        }
        var reschedule: [String] = []
        mutate {
            let transform: (TabLocation) -> TabLocation? = { loc in
                var next = loc
                for p in loc.paths {
                    let r = rewrite(p)
                    if r != p {
                        guard let applied = next.rewritingPath(from: p, to: r) else { return nil }
                        next = applied
                    }
                }
                return next
            }
            tabs = tabs.compactMap { $0.applying(transform) }
            var files: [String: OpenFile] = [:]
            for (p, f) in openFiles {
                let np = rewrite(p)
                if np != p {
                    var moved = f
                    moved.path = np
                    files[np] = moved
                    if f.isDirty { reschedule.append(np) }
                    saveEngine.cancelSave(p)
                } else {
                    files[p] = f
                }
            }
            openFiles = files
            activeFilePath = activeFilePath.map(rewrite)
        }
        for p in reschedule.sorted() { saveEngine.scheduleSave(p) }
    }

    // MARK: Session

    /// `restoreSession`: rebuild tabs (unknown kinds dropped), seed the
    /// prefetched active file, load the rest, and drop tabs whose files fail.
    public func restoreSession(_ sessionTabs: [SessionTab], activeIndex: Int?, prefetchedActiveFile: FileContent? = nil) async {
        var restored: [Tab] = []
        for st in sessionTabs {
            guard let loc = TabLocation(serialized: st.location) else { continue }
            restored.append(Tab(id: createTabId(), location: loc,
                                back: st.back.compactMap { TabLocation(serialized: $0) },
                                forward: st.forward.compactMap { TabLocation(serialized: $0) }))
        }
        if restored.isEmpty {
            reset()
            ensureLauncherTab()
            return
        }
        var seen = Set<String>()
        let uniquePaths = restored.flatMap { $0.location.paths + $0.back.flatMap { $0.paths } + $0.forward.flatMap { $0.paths } }
            .filter { seen.insert($0).inserted }
        let idx = activeIndex ?? 0
        let active: Tab? = (idx >= 0 && idx < restored.count) ? restored[idx] : restored.first
        let activePath = active?.location.primaryPath
        var seeded: OpenFile?
        if let pre = prefetchedActiveFile, let ap = activePath, pre.path == ap {
            seeded = loaded(.loading(ap), raw: pre.content)
        }
        mutate {
            for p in uniquePaths where openFiles[p] == nil { openFiles[p] = .loading(p) }
            if let s = seeded, let ap = activePath { openFiles[ap] = s }
            tabs = restored
            activeTabId = active?.id
            activeFilePath = activePath
        }
        let toLoad = seeded != nil ? uniquePaths.filter { $0 != activePath } : uniquePaths
        var failed = Set<String>()
        await withTaskGroup(of: (String, Bool).self) { group in
            for p in toLoad {
                group.addTask { @MainActor in
                    do { try await self.ensureFileLoaded(p); return (p, true) } catch { return (p, false) }
                }
            }
            for await (p, ok) in group where !ok { failed.insert(p) }
        }
        if failed.isEmpty { return }
        var needsLauncher = false
        mutate {
            let next = tabs.compactMap { tab in
                tab.applying { loc in loc.paths.contains(where: failed.contains) ? nil : loc }
            }
            for p in failed { openFiles[p] = nil }
            let nextActive = next.contains(where: { $0.id == activeTabId }) ? activeTabId : next.first?.id
            needsLauncher = next.isEmpty
            tabs = next
            activeTabId = nextActive
            activeFilePath = deriveActiveFilePath(next, nextActive)
        }
        if needsLauncher { ensureLauncherTab() }
    }

    /// `getEditorSessionSnapshot`: launcher tabs omitted; `activeIndex` counts
    /// only serialized tabs (nil when the active tab is a launcher).
    public func sessionSnapshot() -> (tabs: [SessionTab], activeIndex: Int?) {
        var out: [SessionTab] = []
        var activeIndex: Int?
        for tab in tabs {
            guard let loc = tab.location.serialized else { continue }
            let i = out.count
            out.append(SessionTab(location: loc, back: tab.back.compactMap { $0.serialized }, forward: tab.forward.compactMap { $0.serialized }))
            if let a = activeTabId, tab.id == a { activeIndex = i }
        }
        return (out, activeIndex)
    }

    // MARK: Content

    /// `updateContent`: marks dirty, re-infers the title, schedules a save.
    public func updateContent(_ path: String, _ content: String) {
        guard let existing = openFiles[path] else { return }
        if !(existing.content == content && existing.isDirty) {
            let t = Frontmatter.inferTitle(body: content, frontmatter: existing.frontmatter)
            mutate {
                var f = existing
                f.content = content
                f.title = t.title
                f.titleSource = t.source
                f.isDirty = true
                f.stats = DocumentStatsCalculator.stats(content)
                openFiles[path] = f
            }
        }
        saveEngine.scheduleSave(path)
    }

    /// `updateFrontmatter` (nil removes the block).
    public func updateFrontmatter(_ path: String, _ frontmatter: String?) {
        if let file = openFiles[path], file.frontmatter != frontmatter {
            let t = Frontmatter.inferTitle(body: file.content, frontmatter: frontmatter)
            mutate {
                var f = file
                f.frontmatter = frontmatter
                f.title = t.title
                f.titleSource = t.source
                f.isDirty = true
                f.displayDate = displayDate(frontmatter)
                openFiles[path] = f
            }
        }
        saveEngine.scheduleSave(path)
    }

    public func markSaved(_ path: String, diskContent: String, hasNewerChanges: Bool = false) {
        guard var f = openFiles[path] else { return }
        mutate {
            f.diskContent = diskContent
            f.isDirty = hasNewerChanges
            f.saveError = nil
            openFiles[path] = f
        }
    }

    public func setSaveError(_ path: String, error: String) { setSaveError(path, error as String?) }

    public func setSaveError(_ path: String, _ error: String?) {
        guard var f = openFiles[path], f.saveError != error else { return }
        mutate {
            f.saveError = error
            openFiles[path] = f
        }
    }

    /// `reloadFromDisk`: replace the buffer with disk content (unsaved edits
    /// discarded), bump `reloadVersion`.
    public func reloadFromDisk(_ path: String, rawContent: String) {
        saveEngine.cancelSave(path)
        guard let file = openFiles[path] else { return }
        mutate {
            var f = loaded(file, raw: rawContent)
            f.isDirty = false
            f.reloadVersion = file.reloadVersion + 1
            f.isLoading = file.isLoading ? false : false
            openFiles[path] = f
        }
    }

    public func updateScrollPos(_ path: String, _ pos: Double) {
        guard var f = openFiles[path], f.scrollPos != pos else { return }
        mutate { f.scrollPos = pos; openFiles[path] = f }
    }

    public func updateCursorPos(_ path: String, _ pos: Int) {
        guard var f = openFiles[path], f.cursorPos != pos else { return }
        mutate { f.cursorPos = pos; openFiles[path] = f }
    }

    // MARK: SaveEngineHost

    public func fileForSave(_ path: String) -> (frontmatter: String?, content: String, isDirty: Bool)? {
        openFiles[path].map { ($0.frontmatter, $0.content, $0.isDirty) }
    }

    // MARK: Titles

    /// Window title: just the document's name (its title, like the tab label),
    /// with no app-name suffix.
    public func windowTitle() -> String {
        guard let tab = activeTab else { return "Flo State" }
        switch tab.location {
        case .file: return tabTitle(tab)
        case .launcher: return "New Tab"
        case .settings: return "Settings"
        }
    }

    /// Tab strip label: document title, else file name / kind title.
    public func tabTitle(_ tab: Tab) -> String {
        if case let .file(p) = tab.location, let f = openFiles[p], !f.title.isEmpty { return f.title }
        return tab.location.fallbackTitle
    }
}

/// Caret after an external reload: kept, clamped to the new length.
public func clampCaret(_ pos: Int, length: Int) -> Int { max(0, min(pos, length)) }

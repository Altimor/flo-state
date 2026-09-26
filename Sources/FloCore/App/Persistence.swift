import Foundation

// MARK: - Sessions (sessions.json)

/// One workspace's saved tabs (`workspace.rs::SessionData`).
public struct SessionData: Equatable {
    public var tabs: [SessionTab]
    public var activeIndex: Int?
    public init(tabs: [SessionTab], activeIndex: Int?) { self.tabs = tabs; self.activeIndex = activeIndex }

    var json: JSONValue {
        .object([
            ("tabs", .array(tabs.map { t in
                .object([("location", t.location.json), ("back", .array(t.back.map { $0.json })), ("forward", .array(t.forward.map { $0.json }))])
            })),
            ("active_index", activeIndex.map { .int(Int64($0)) } ?? .null),
        ])
    }

    init?(json: JSONValue) {
        guard case .object = json else { return nil }
        var tabs: [SessionTab] = []
        for t in json["tabs"]?.arrayValue ?? [] {
            guard let loc = t["location"].flatMap(SerializedLocation.init(json:)) else { return nil }
            let back = (t["back"]?.arrayValue ?? []).compactMap(SerializedLocation.init(json:))
            let forward = (t["forward"]?.arrayValue ?? []).compactMap(SerializedLocation.init(json:))
            tabs.append(SessionTab(location: loc, back: back, forward: forward))
        }
        self.tabs = tabs
        if let i = json["active_index"]?.intValue, i >= 0 { activeIndex = Int(i) } else { activeIndex = nil }
    }
}

/// `sessions.json`: `{ "<root>": SessionData }` keyed by workspace root with
/// trailing slashes trimmed. Read-modify-write under a lock.
public final class SessionStore {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }
    public convenience init(appData: AppDataDirectory) { self.init(url: appData.sessionsURL) }

    static func key(_ root: String) -> String {
        var k = root
        while k.hasSuffix("/") { k.removeLast() }
        return k
    }

    /// Unreadable or corrupt file → empty.
    func loadAll() -> [(String, JSONValue)] {
        guard let data = try? Data(contentsOf: url), let json = try? JSON.parse(data: data), case let .object(pairs) = json else { return [] }
        return pairs
    }

    public func load(root: String) -> SessionData? {
        lock.lock(); defer { lock.unlock() }
        let key = SessionStore.key(root)
        guard let entry = loadAll().first(where: { $0.0 == key })?.1 else { return nil }
        return SessionData(json: entry)
    }

    /// Empty tabs with no active index delete the key.
    public func save(root: String, tabs: [SessionTab], activeIndex: Int?) throws {
        lock.lock(); defer { lock.unlock() }
        let key = SessionStore.key(root)
        var all = loadAll()
        if tabs.isEmpty && activeIndex == nil {
            all.removeAll { $0.0 == key }
        } else {
            let value = SessionData(tabs: tabs, activeIndex: activeIndex).json
            if let idx = all.firstIndex(where: { $0.0 == key }) { all[idx].1 = value } else { all.append((key, value)) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(JSON.prettyString(.object(all)).utf8).write(to: url)
    }
}

/// Frontend session policy (`session.ts` + the workspace-store subscription):
/// saves 500 ms after any tab-list / active-tab change, flushes on unload,
/// only with a workspace root and `workspace.restore-open-files` on.
@MainActor
public final class SessionAutosaver {
    public static let debounceMs: Double = 500

    private let store: SessionStore
    private let scheduler: AppScheduler
    private weak var editor: EditorStore?
    private let root: () -> String?
    private let restoreOpenFiles: () -> Bool
    private var timer: ScheduledToken?
    public private(set) var saveCount = 0

    public init(editor: EditorStore, store: SessionStore, scheduler: AppScheduler,
                root: @escaping () -> String?, restoreOpenFiles: @escaping () -> Bool) {
        self.editor = editor
        self.store = store
        self.scheduler = scheduler
        self.root = root
        self.restoreOpenFiles = restoreOpenFiles
        editor.observers.append { [weak self] change in
            guard let self = self, let editor = self.editor else { return }
            if editor.tabs == change.previousTabs && editor.activeTabId == change.previousActiveTabId { return }
            if self.state == .armOnNextChange { self.state = .armed }
            guard self.state == .armed else { return }
            self.schedule()
        }
    }

    /// Saving is gated on the workspace's session restore: until it has
    /// finished, the editor holds a transient (empty / launcher-only /
    /// half-restored) state that must never replace the stored session.
    public enum State: Equatable {
        /// Restore pending or in progress: nothing is written, flush included.
        case disarmed
        /// Restore didn't reproduce the stored session (tabs dropped because
        /// files failed to load, or nothing was restored): keep the stored
        /// session until the user changes the tab list.
        case armOnNextChange
        /// Restore finished: normal debounced saving.
        case armed
    }
    public private(set) var state: State = .disarmed

    /// A workspace is about to (re)load: stop saving and drop a pending save.
    public func disarm() {
        if let t = timer { scheduler.cancel(t); timer = nil }
        state = .disarmed
    }

    /// The session restore for the current root finished. `complete`: the
    /// editor now reflects the stored session (or there was none).
    public func restoreFinished(complete: Bool) {
        state = complete ? .armed : .armOnNextChange
    }

    public var hasPendingSave: Bool { timer != nil }

    private func schedule() {
        if let t = timer { scheduler.cancel(t) }
        timer = scheduler.schedule(afterMs: SessionAutosaver.debounceMs) { [weak self] in
            self?.timer = nil
            self?.saveNow()
        }
    }

    /// `beforeunload`: cancel the debounce and save immediately.
    public func flush() {
        if let t = timer { scheduler.cancel(t); timer = nil }
        saveNow()
    }

    public func saveNow() {
        guard state == .armed, let root = root(), let editor = editor else { return }
        guard restoreOpenFiles() else { return }
        let snap = editor.sessionSnapshot()
        try? store.save(root: root, tabs: snap.tabs, activeIndex: snap.activeIndex)
        saveCount += 1
    }

    /// `loadSession`: nil when the setting is off or nothing is stored.
    public static func loadSession(store: SessionStore, root: String, restoreOpenFiles: Bool) -> SessionData? {
        guard restoreOpenFiles else { return nil }
        return store.load(root: root)
    }
}

// MARK: - Recent workspaces (recent_workspaces.json)

public final class RecentWorkspacesStore {
    /// Hard-coded in the Rust (`truncate(10)`), independent of `workspace.max-recent-workspaces`.
    public static let maxCount = 10
    public let url: URL

    public init(url: URL) { self.url = url }
    public convenience init(appData: AppDataDirectory) { self.init(url: appData.recentWorkspacesURL) }

    /// Missing file → []; corrupt file → [] (the Rust surfaces an error that callers default away).
    public func load() -> [String] {
        guard let data = try? Data(contentsOf: url), let json = try? JSON.parse(data: data), let arr = json.arrayValue else { return [] }
        return arr.compactMap { $0.stringValue }
    }

    /// `save_recent_workspace`: dedupe, push front, cap at 10.
    public func record(_ canonicalPath: String) throws {
        var list = load()
        list.removeAll { $0 == canonicalPath }
        list.insert(canonicalPath, at: 0)
        if list.count > RecentWorkspacesStore.maxCount { list = Array(list.prefix(RecentWorkspacesStore.maxCount)) }
        try write(list)
    }

    public func remove(_ path: String) throws {
        var list = load()
        list.removeAll { $0 == path }
        try write(list)
    }

    private func write(_ list: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(JSON.prettyString(.array(list.map { .string($0) })).utf8).write(to: url)
    }
}

// MARK: - Global recent files (recent_files.json)

public struct RecentEntry: Equatable {
    public var path: String
    /// Unix seconds; 0 marks a legacy entry with unknown time.
    public var openedAt: UInt64
    public init(path: String, openedAt: UInt64) { self.path = path; self.openedAt = openedAt }
}

public struct RecentFile: Equatable {
    public var path: String
    public var name: String
    public var title: String?
    public var openedAt: UInt64
}

public final class RecentFilesStore {
    public static let maxCount = 30
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }
    public convenience init(appData: AppDataDirectory) { self.init(url: appData.recentFilesURL) }

    /// Current format `[{path, opened_at}]`, legacy `["path", …]` (opened_at 0), corrupt → [].
    public func load() -> [RecentEntry] {
        guard let data = try? Data(contentsOf: url), let json = try? JSON.parse(data: data), let arr = json.arrayValue else { return [] }
        if arr.allSatisfy({ if case .object = $0 { return true }; return false }) {
            var out: [RecentEntry] = []
            for e in arr {
                guard let p = e["path"]?.stringValue else { return [] }
                let at = e["opened_at"]?.intValue ?? 0
                out.append(RecentEntry(path: p, openedAt: at > 0 ? UInt64(at) : 0))
            }
            return out
        }
        if arr.allSatisfy({ $0.stringValue != nil }) {
            return arr.map { RecentEntry(path: $0.stringValue!, openedAt: 0) }
        }
        return []
    }

    private func save(_ entries: [RecentEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = JSONValue.array(entries.map { .object([("path", .string($0.path)), ("opened_at", .int(Int64($0.openedAt)))]) })
        try AtomicFile.write(Data(JSON.prettyString(json).utf8), to: url, tempName: url.lastPathComponent.replacingOccurrences(of: ".json", with: ".json.tmp"))
    }

    /// `push_recent`: dedupe by path, insert at front, cap.
    public static func push(_ list: inout [RecentEntry], path: String, openedAt: UInt64) {
        list.removeAll { $0.path == path }
        list.insert(RecentEntry(path: path, openedAt: openedAt), at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
    }

    /// `record_recent_file`: ignores missing / non-openable paths; stores the canonical path.
    public func record(_ path: String, extensions: SupportedExtensions = .schemaDefault, now: Date = Date()) throws {
        guard WorkspaceFS.isFile(path), extensions.isSupported(path) else { return }
        let canonical = WorkspaceFS.canonicalize(path)
        lock.lock(); defer { lock.unlock() }
        var list = load()
        RecentFilesStore.push(&list, path: canonical, openedAt: UInt64(max(0, now.timeIntervalSince1970)))
        try save(list)
    }

    public func remove(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        let before = list.count
        list.removeAll { $0.path == path }
        if list.count == before { return }
        try save(list)
    }

    /// `get_recent_files_global`: entries that can't be stat'ed are hidden
    /// from the result but kept on disk.
    public func list(limit: Int? = nil, extensions: SupportedExtensions = .schemaDefault) -> [RecentFile] {
        let l = max(1, limit ?? RecentFilesStore.maxCount)
        lock.lock(); defer { lock.unlock() }
        return Array(load().compactMap { e -> RecentFile? in
            guard let f = WorkspaceFS.fileEntry(e.path, extensions: extensions) else { return nil }
            return RecentFile(path: f.path, name: f.name, title: f.title, openedAt: e.openedAt)
        }.prefix(l))
    }
}

/// `global-recents.ts`: every file that becomes the active file is recorded once.
@MainActor
public final class RecentFilesRecorder {
    public init(editor: EditorStore, record: @escaping (String) -> Void) {
        editor.observers.append { [weak editor] change in
            guard let editor = editor, let path = editor.activeFilePath, path != change.previousActiveFilePath else { return }
            record(path)
        }
    }
}

/// `relative-time.ts::formatRelativeTime` ("just now", "2 mins ago", …); nil for 0.
public func formatRelativeTime(_ openedAt: UInt64, nowSecs: UInt64) -> String? {
    if openedAt == 0 { return nil }
    let diff = Double(nowSecs > openedAt ? nowSecs - openedAt : 0)
    let minute = 60.0, hour = 3600.0, day = 86400.0, week = 604800.0
    func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }
    if diff < 45 { return "just now" }
    if diff < hour { let m = jsRound(diff / minute); return "\(m) min\(m == 1 ? "" : "s") ago" }
    if diff < day { let h = jsRound(diff / hour); return "\(h) hour\(h == 1 ? "" : "s") ago" }
    if diff < week { let d = jsRound(diff / day); return "\(d) day\(d == 1 ? "" : "s") ago" }
    let w = jsRound(diff / week)
    return "\(w) week\(w == 1 ? "" : "s") ago"
}

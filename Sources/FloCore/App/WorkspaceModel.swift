import Foundation

/// Sidebar tree + pinned files state (port of the non-editor parts of
/// `workspace-store.ts`). Directory reads are injected.
public final class WorkspaceTreeModel {
    public typealias DirectoryReader = (String) throws -> [DirEntry]

    public private(set) var root: String?
    public private(set) var directoryCache: [String: [DirEntry]] = [:]
    public private(set) var expandedDirs: Set<String> = []
    public private(set) var pinnedFiles: [String] = []
    public private(set) var sidebarMetadataVersion = 0
    public var recentWorkspaces: [String] = []

    private let readDirectory: DirectoryReader
    /// Persist pinned files for a root (web app: localStorage
    /// `writer:pref:workspace:{root}:sidebar-pinned-files`).
    public var persistPinned: ((String, [String]) -> Void)?

    public init(readDirectory: @escaping DirectoryReader) { self.readDirectory = readDirectory }

    public static func pinnedFilesPreferenceKey(_ root: String) -> String { "workspace:\(root):sidebar-pinned-files" }

    /// Open a workspace root with its first listing.
    public func open(root: String, entries: [DirEntry], recentWorkspaces: [String], pinned: [String] = []) {
        self.root = root
        directoryCache = [root: entries]
        expandedDirs = []
        pinnedFiles = WorkspaceTreeModel.normalizePinned(root: root, pinned)
        sidebarMetadataVersion = 0
        self.recentWorkspaces = recentWorkspaces
    }

    public func close() {
        root = nil
        directoryCache = [:]
        expandedDirs = []
        pinnedFiles = []
        sidebarMetadataVersion = 0
    }

    public func refreshDirectory(_ path: String) throws {
        directoryCache[path] = try readDirectory(path)
    }

    public func toggleDirectory(_ path: String) throws {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
            return
        }
        if directoryCache[path] == nil { directoryCache[path] = try readDirectory(path) }
        expandedDirs.insert(path)
    }

    /// Reveal in sidebar: expand every ancestor folder of `path` below the root.
    public func expandAncestors(of path: String) throws {
        guard let root = root else { return }
        var dirs: [String] = []
        var d = (path as NSString).deletingLastPathComponent
        while d.count > root.count && d.hasPrefix(root + "/") {
            dirs.append(d)
            d = (d as NSString).deletingLastPathComponent
        }
        for dir in dirs.reversed() where !expandedDirs.contains(dir) { try toggleDirectory(dir) }
    }

    public func invalidatePath(_ path: String) { directoryCache[path] = nil }

    public func bumpSidebarMetadataVersion() { sidebarMetadataVersion += 1 }

    /// `fs:directory-changed`: refresh visible dirs (expanded or root) in place,
    /// invalidate hidden ones; same for the parent.
    public func handleDirectoryChanged(_ path: String) {
        bumpSidebarMetadataVersion()
        func touch(_ p: String) {
            if expandedDirs.contains(p) || p == root { try? refreshDirectory(p) } else { invalidatePath(p) }
        }
        touch(path)
        let ns = path as NSString
        let slash = ns.range(of: "/", options: .backwards).location
        if slash != NSNotFound {
            let parent = ns.substring(to: slash)
            if !parent.isEmpty { touch(parent) }
        }
    }

    /// `rewriteExpandedDir`: after a folder rename (also rekeys the cache).
    public func rewriteExpandedDir(_ oldPath: String, to newPath: String) {
        let prefix = oldPath + "/"
        var changed = false
        var next = Set<String>()
        for d in expandedDirs {
            if d == oldPath { next.insert(newPath); changed = true }
            else if d.hasPrefix(prefix) { next.insert(newPath + d.dropFirst(oldPath.count)); changed = true }
            else { next.insert(d) }
        }
        guard changed else { return }
        var cache: [String: [DirEntry]] = [:]
        for (k, v) in directoryCache {
            if k == oldPath { cache[newPath] = v }
            else if k.hasPrefix(prefix) { cache[newPath + k.dropFirst(oldPath.count)] = v }
            else { cache[k] = v }
        }
        expandedDirs = next
        directoryCache = cache
    }

    /// Visible tree order (folders expanded), used for Cmd-Alt-↑/↓ stepping.
    public func visibleFiles() -> [String] {
        guard let root = root else { return [] }
        var out: [String] = []
        func walk(_ dir: String) {
            for e in directoryCache[dir] ?? [] {
                if e.isDir { if expandedDirs.contains(e.path) { walk(e.path) } } else { out.append(e.path) }
            }
        }
        walk(root)
        return out
    }

    /// Step to the previous/next visible file; stops at the ends (no wrap).
    public func stepFile(from current: String?, by delta: Int) -> String? {
        let files = visibleFiles()
        guard !files.isEmpty else { return nil }
        guard let current = current, let idx = files.firstIndex(of: current) else { return delta >= 0 ? files.first : files.last }
        let next = idx + delta
        guard next >= 0, next < files.count else { return nil }
        return files[next]
    }

    // MARK: Pinned

    /// `normalizePinnedFiles`: strings under `root/`, deduped, order kept.
    public static func normalizePinned(root: String, _ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix(root + "/") && seen.insert($0).inserted }
    }

    public func togglePinnedFile(_ path: String) {
        guard let root = root, path.hasPrefix(root + "/") else { return }
        pinnedFiles = pinnedFiles.contains(path) ? pinnedFiles.filter { $0 != path } : [path] + pinnedFiles
        persistPinned?(root, pinnedFiles)
    }

    public func removePinnedFile(_ path: String) {
        guard let root = root, pinnedFiles.contains(path) else { return }
        pinnedFiles.removeAll { $0 == path }
        persistPinned?(root, pinnedFiles)
    }

    public func removePinnedFilesWithPrefix(_ prefix: String) {
        guard let root = root else { return }
        let filtered = pinnedFiles.filter { $0 != prefix && !$0.hasPrefix(prefix + "/") }
        guard filtered.count != pinnedFiles.count else { return }
        pinnedFiles = filtered
        persistPinned?(root, pinnedFiles)
    }

    public func rewritePinnedPath(_ oldPath: String, to newPath: String) {
        guard let root = root else { return }
        var changed = false
        let rewritten = pinnedFiles.map { p -> String in
            if p == oldPath { changed = true; return newPath }
            if p.hasPrefix(oldPath + "/") { changed = true; return newPath + p.dropFirst(oldPath.count) }
            return p
        }
        guard changed else { return }
        var seen = Set<String>()
        pinnedFiles = rewritten.filter { seen.insert($0).inserted }
        persistPinned?(root, pinnedFiles)
    }

    public func removeRecentWorkspace(_ path: String) {
        recentWorkspaces.removeAll { $0 == path }
    }
}

// MARK: - Daily note (daily-note.ts) and jump-to-bottom

public enum DailyNote {
    /// `YYYY.MM.DD` in local time.
    public static func todayStamp(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return String(format: "%d.%02d.%02d", c.year!, c.month!, c.day!)
    }

    public static func heading(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        "## \(todayStamp(now, timeZone: timeZone))"
    }

    /// A document that already has a `## YYYY.MM.DD` line.
    public static func isDatedNotebook(_ doc: String) -> Bool {
        AppRegex.test(doc, "^## [0-9]{4}\\.[0-9]{2}\\.[0-9]{2}\(AppRegex.ws)*$", multiline: true)
    }

    /// 1-based line number of the exact heading line (trailing whitespace ignored), 0 if absent.
    public static func findHeadingLine(_ doc: String, heading: String) -> Int {
        for (i, line) in doc.components(separatedBy: "\n").enumerated() where AppRegex.replace(line, "\(AppRegex.ws)+$", "") == heading {
            return i + 1
        }
        return 0
    }

    /// Text inserted at the end: pads to exactly one blank line above.
    static func appendInsert(_ doc: String, heading: String) -> String {
        let leading: String
        if doc.hasSuffix("\n\n") || doc.utf16.suffix(2).elementsEqual([10, 10]) { leading = "" }
        else if doc.utf16.last == 10 { leading = "\n" }
        else { leading = "\n\n" }
        return "\(leading)\(heading)\n\n"
    }

    public struct Edit: Equatable {
        /// UTF-16 offset where `text` is inserted (document end).
        public var at: Int
        public var text: String
        /// Caret after the edit (UTF-16), if the command moves it.
        public var caret: Int?
    }

    /// `ensureTodayHeading`: only for dated notebooks, idempotent.
    public static func ensureTodayHeading(_ doc: String, now: Date = Date(), timeZone: TimeZone = .current) -> Edit? {
        guard isDatedNotebook(doc) else { return nil }
        let h = heading(now, timeZone: timeZone)
        if findHeadingLine(doc, heading: h) > 0 { return nil }
        let end = doc.utf16.count
        return Edit(at: end, text: appendInsert(doc, heading: h), caret: nil)
    }

    public enum GoToResult: Equatable {
        /// Heading exists: caret goes to the end of that line (UTF-16 offset).
        case existing(caret: Int)
        case inserted(Edit)
    }

    /// `goToDailyNote` (Go to Today ⌘⇧D).
    public static func goToToday(_ doc: String, now: Date = Date(), timeZone: TimeZone = .current) -> GoToResult {
        let h = heading(now, timeZone: timeZone)
        let lineNo = findHeadingLine(doc, heading: h)
        if lineNo > 0 {
            let lines = doc.components(separatedBy: "\n")
            let offset = lines.prefix(lineNo - 1).reduce(0) { $0 + $1.utf16.count + 1 } + lines[lineNo - 1].utf16.count
            return .existing(caret: offset)
        }
        let end = doc.utf16.count
        let insert = appendInsert(doc, heading: h)
        return .inserted(Edit(at: end, text: insert, caret: end + insert.utf16.count))
    }

    /// Jump-to-bottom on return: `minutes <= 0` disables; jump when away at
    /// least `minutes`.
    public static func shouldJumpToBottom(awayMs: Double, minutes: Double) -> Bool {
        if minutes <= 0 { return false }
        return awayMs >= minutes * 60_000
    }
}

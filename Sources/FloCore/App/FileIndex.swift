import Foundation

/// One indexed openable file (`state.rs::IndexedFile`).
public struct IndexedFile: Equatable {
    public var path: String
    public var relativePath: String
    public var name: String
    public var modifiedAt: UInt64
    public init(path: String, relativePath: String, name: String, modifiedAt: UInt64) {
        self.path = path; self.relativePath = relativePath; self.name = name; self.modifiedAt = modifiedAt
    }
}

/// A symbolic link the index walk followed: `link` is its path inside the
/// workspace, `target` the real path it resolves to.
public struct SymlinkMount: Equatable {
    public var link: String
    public var target: String
    public init(link: String, target: String) { self.link = link; self.target = target }
}

/// Fuzzy-search hit (`search.rs::SearchResult`). `matchIndices` are character
/// (Unicode scalar) offsets into `relativePath`.
public struct SearchResult: Equatable {
    public var path: String
    public var filename: String
    public var relativePath: String
    public var score: UInt32
    public var matchIndices: [UInt32]
    public init(path: String, filename: String, relativePath: String, score: UInt32 = 0, matchIndices: [UInt32] = []) {
        self.path = path; self.filename = filename; self.relativePath = relativePath; self.score = score; self.matchIndices = matchIndices
    }
}

/// Gitignore-aware directory walker modelled on the `ignore` crate's
/// `WalkBuilder` defaults as used by `index_workspace_impl` and
/// `find_file_by_name_impl`: hidden entries skipped, `node_modules` skipped,
/// `.ignore` files always honoured, `.gitignore` / `.git/info/exclude` / the
/// global excludes file honoured only inside a git repository
/// (`require_git(true)`), parent directories' ignore files included.
public struct IgnoreWalker {
    public var root: String
    /// Global excludes file (git `core.excludesFile`), consulted only in a repo.
    public var globalExcludes: URL?

    public init(root: String, globalExcludes: URL? = IgnoreWalker.defaultGlobalExcludes) {
        self.root = root
        self.globalExcludes = globalExcludes
    }

    public static var defaultGlobalExcludes: URL? {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("git/ignore")
    }

    struct Layers {
        var ignoreFiles: [Gitignore] = []   // deepest first
        var gitignores: [Gitignore] = []    // deepest first
        var exclude: Gitignore?
        var global: Gitignore?

        func matched(_ path: String, isDir: Bool) -> IgnoreMatch {
            for g in ignoreFiles { let m = g.matched(path, isDir: isDir); if m != .none { return m } }
            for g in gitignores { let m = g.matched(path, isDir: isDir); if m != .none { return m } }
            if let e = exclude { let m = e.matched(path, isDir: isDir); if m != .none { return m } }
            if let g = global { let m = g.matched(path, isDir: isDir); if m != .none { return m } }
            return .none
        }
    }

    static func findRepoRoot(from dir: String) -> String? {
        var current = dir
        while true {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    static func loadIfPresent(_ path: String) -> Gitignore? {
        guard WorkspaceFS.isFile(path) else { return nil }
        let g = Gitignore(fileURL: URL(fileURLWithPath: path))
        return g.isEmpty ? nil : g
    }

    /// Visits every non-ignored regular file below `root`, in a deterministic
    /// (sorted, depth-first) order. `shouldContinue` is polled per entry; return
    /// false to stop (the cancel flag). Symbolic links are followed (files are
    /// visited at their path inside the workspace) and reported to `onSymlink`;
    /// a link back to a folder being walked is skipped.
    public func walkFiles(shouldContinue: () -> Bool = { true }, onSymlink: (SymlinkMount) -> Void = { _ in },
                          visit: (String) -> Void) {
        let root = self.root
        let repoRoot = IgnoreWalker.findRepoRoot(from: root)
        let inRepo = repoRoot != nil
        var base = Layers()
        // Parent directories (root's ancestors, outermost first → pushed so deepest is first).
        var ancestors: [String] = []
        var cur = (root as NSString).deletingLastPathComponent
        while !cur.isEmpty {
            ancestors.append(cur)
            let parent = (cur as NSString).deletingLastPathComponent
            if parent == cur { break }
            cur = parent
        }
        for dir in ancestors { // nearest first == deepest first
            if let g = IgnoreWalker.loadIfPresent((dir as NSString).appendingPathComponent(".ignore")) { base.ignoreFiles.append(g) }
            if inRepo, let repo = repoRoot, Gitignore.stripPathPrefix(repo, dir) != nil,
               let g = IgnoreWalker.loadIfPresent((dir as NSString).appendingPathComponent(".gitignore")) {
                base.gitignores.append(g)
            }
        }
        if let repo = repoRoot {
            base.exclude = IgnoreWalker.loadIfPresent((repo as NSString).appendingPathComponent(".git/info/exclude"))
            if let global = globalExcludes { base.global = IgnoreWalker.loadIfPresent(global.path) }
        }
        var walking: Set<String> = []
        _ = walk(dir: root, realDir: WorkspaceFS.canonicalize(root), ancestors: &walking, layers: base, inRepo: inRepo,
                 shouldContinue: shouldContinue, onSymlink: onSymlink, visit: visit)
    }

    /// `ancestors`: real paths of the folders on the current walk path (cycle guard).
    private func walk(dir: String, realDir: String, ancestors: inout Set<String>, layers parent: Layers, inRepo: Bool,
                      shouldContinue: () -> Bool, onSymlink: (SymlinkMount) -> Void, visit: (String) -> Void) -> Bool {
        guard ancestors.insert(realDir).inserted else { return true }
        defer { ancestors.remove(realDir) }
        var layers = parent
        if let g = IgnoreWalker.loadIfPresent((dir as NSString).appendingPathComponent(".ignore")) { layers.ignoreFiles.insert(g, at: 0) }
        if inRepo, let g = IgnoreWalker.loadIfPresent((dir as NSString).appendingPathComponent(".gitignore")) { layers.gitignores.insert(g, at: 0) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return true }
        for name in names.sorted(by: WorkspaceFS.rustStringLess) {
            if !shouldContinue() { return false }
            if name.hasPrefix(".") { continue }
            let child = (dir as NSString).appendingPathComponent(name)
            guard let kind = WorkspaceFS.entryKind(child) else { continue }
            let isDir = kind == .dir
            if layers.matched(child, isDir: isDir) == .ignore { continue }
            if isDir && name == "node_modules" { continue }
            let target = kind == .other ? nil : WorkspaceFS.symlinkTarget(child)
            if let target = target { onSymlink(SymlinkMount(link: child, target: target)) }
            if isDir {
                let childReal = target ?? (realDir as NSString).appendingPathComponent(name)
                if !walk(dir: child, realDir: childReal, ancestors: &ancestors, layers: layers, inRepo: inRepo,
                         shouldContinue: shouldContinue, onSymlink: onSymlink, visit: visit) { return false }
            } else if kind == .file {
                visit(child)
            }
        }
        return true
    }
}

/// The workspace file index (`WorkspaceState.file_index` + `dirs_with_markdown`)
/// and the operations the watcher and commands perform on it.
public final class FileIndex {
    public private(set) var root: String
    public private(set) var files: [IndexedFile] = []
    public private(set) var dirsWithSupportedFiles: Set<String> = []
    /// Symbolic links the last full build followed (the watcher also watches their targets).
    public private(set) var symlinks: [SymlinkMount] = []
    public private(set) var isReady = false
    private var recentCache: [IndexedFile]?

    public init(root: String) { self.root = root }

    /// `index_workspace_impl`. `isCancelled` is checked per entry; a cancelled
    /// walk returns what it found so far (callers should discard it).
    public static func build(root: String, extensions: SupportedExtensions, walker: IgnoreWalker? = nil,
                             isCancelled: () -> Bool = { false }) -> (files: [IndexedFile], dirs: Set<String>, symlinks: [SymlinkMount]) {
        var files: [IndexedFile] = []
        var symlinks: [SymlinkMount] = []
        let w = walker ?? IgnoreWalker(root: root)
        if isCancelled() { return ([], [], []) }
        w.walkFiles(shouldContinue: { !isCancelled() }, onSymlink: { symlinks.append($0) }) { path in
            guard extensions.isSupported(path) else { return }
            files.append(IndexedFile(path: path, relativePath: FileIndex.relative(path, root: root),
                                     name: (path as NSString).lastPathComponent, modifiedAt: WorkspaceFS.modifiedTime(path)))
        }
        return (files, rebuildDirs(files, root: root), symlinks)
    }

    /// Build synchronously and mark ready.
    public func rebuild(extensions: SupportedExtensions, walker: IgnoreWalker? = nil) {
        let result = FileIndex.build(root: root, extensions: extensions, walker: walker)
        install(files: result.files, dirs: result.dirs, symlinks: result.symlinks)
    }

    public func install(files: [IndexedFile], dirs: Set<String>, symlinks: [SymlinkMount] = []) {
        self.files = files
        self.dirsWithSupportedFiles = dirs
        self.symlinks = symlinks
        recentCache = nil
        isReady = true
    }

    public func reset(root: String) {
        self.root = root
        files = []
        dirsWithSupportedFiles = []
        symlinks = []
        recentCache = nil
        isReady = false
    }

    static func relative(_ path: String, root: String) -> String {
        Gitignore.stripPathPrefix(root, path) ?? path
    }

    /// `register_ancestors`.
    public static func registerAncestors(_ dirs: inout Set<String>, filePath: String, root: String) {
        var dir = (filePath as NSString).deletingLastPathComponent
        while !dir.isEmpty {
            if dirs.contains(dir) { break }
            dirs.insert(dir)
            if dir == root { break }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
    }

    public static func rebuildDirs(_ files: [IndexedFile], root: String) -> Set<String> {
        var dirs = Set<String>()
        for f in files { registerAncestors(&dirs, filePath: f.path, root: root) }
        return dirs
    }

    // MARK: Recents

    /// `recent_files_slice`: newest mtime first, ties by relative path.
    public func recentFilesSlice(offset: Int, limit: Int) -> [IndexedFile] {
        if recentCache == nil {
            recentCache = files.sorted { a, b in
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
                return WorkspaceFS.rustStringLess(a.relativePath, b.relativePath)
            }
        }
        return Array(recentCache!.dropFirst(offset).prefix(limit))
    }

    /// `read_recent_files` (limit clamped 1…100, default 8).
    public func readRecentFiles(limit: Int? = nil, offset: Int? = nil, extensions: SupportedExtensions) -> [DirEntry] {
        let l = min(100, max(1, limit ?? 8))
        return recentFilesSlice(offset: offset ?? 0, limit: l).compactMap { WorkspaceFS.fileEntry($0.path, extensions: extensions) }
    }

    public func updateModifiedAt(_ path: String, _ modifiedAt: UInt64) {
        guard let idx = files.firstIndex(where: { $0.path == path }) else { return }
        if files[idx].modifiedAt != modifiedAt {
            files[idx].modifiedAt = modifiedAt
            recentCache = nil
        }
    }

    // MARK: Watcher maintenance (watcher.rs)

    public func add(_ path: String, modifiedAt: UInt64? = nil) {
        let mtime = modifiedAt ?? WorkspaceFS.modifiedTime(path)
        if let idx = files.firstIndex(where: { $0.path == path }) {
            if files[idx].modifiedAt != mtime { files[idx].modifiedAt = mtime; recentCache = nil }
            return
        }
        files.append(IndexedFile(path: path, relativePath: FileIndex.relative(path, root: root),
                                 name: (path as NSString).lastPathComponent, modifiedAt: mtime))
        recentCache = nil
        FileIndex.registerAncestors(&dirsWithSupportedFiles, filePath: path, root: root)
    }

    public func remove(_ path: String) {
        let before = files.count
        files.removeAll { $0.path == path }
        if files.count != before { recentCache = nil }
        dirsWithSupportedFiles = FileIndex.rebuildDirs(files, root: root)
    }

    public func removeSubtree(_ dir: String) {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        let before = files.count
        files.removeAll { $0.path.hasPrefix(prefix) || $0.path == dir }
        if files.count != before { recentCache = nil }
        dirsWithSupportedFiles = FileIndex.rebuildDirs(files, root: root)
    }

    public func addSubtree(_ dir: String, extensions: SupportedExtensions, walker: IgnoreWalker? = nil) {
        let found = FileIndex.build(root: dir, extensions: extensions, walker: walker ?? IgnoreWalker(root: dir)).files
        var added: [String] = []
        for f in found where !files.contains(where: { $0.path == f.path }) {
            files.append(IndexedFile(path: f.path, relativePath: FileIndex.relative(f.path, root: root), name: f.name, modifiedAt: f.modifiedAt))
            added.append(f.path)
        }
        guard !added.isEmpty else { return }
        recentCache = nil
        for p in added { FileIndex.registerAncestors(&dirsWithSupportedFiles, filePath: p, root: root) }
    }

    // MARK: Search

    public func fuzzySearch(_ query: String, limit: Int = 50) -> [SearchResult] {
        FuzzySearch.search(query, in: files, limit: limit)
    }
}

public enum FuzzySearch {
    /// `fuzzy_search_from`: case-insensitive substring over the relative path,
    /// also trying spaces→hyphens and hyphens→spaces. Score: +1,000,000 when
    /// the match starts in the filename, + (10,000 − byte offset), + (1,000 −
    /// path length in chars). Stable sort, highest first, then truncate.
    public static func search(_ query: String, in index: [IndexedFile], limit: Int) -> [SearchResult] {
        if query.isEmpty { return [] }
        let normalized = query.lowercased()
        var needles = [normalized]
        let hyphen = normalized.replacingOccurrences(of: " ", with: "-")
        if !needles.contains(hyphen) { needles.append(hyphen) }
        let space = normalized.replacingOccurrences(of: "-", with: " ")
        if !needles.contains(space) { needles.append(space) }
        let needleBytes = needles.map { Array($0.utf8) }

        var results: [SearchResult] = []
        for file in index {
            let haystack = file.relativePath.lowercased()
            let hay = Array(haystack.utf8)
            var best: (Int, Int)? // (byteStart, needleIndex)
            for (ni, n) in needleBytes.enumerated() {
                guard let start = WorkspaceFS.findBytes(hay, n) else { continue }
                if best == nil || start < best!.0 { best = (start, ni) }
            }
            guard let (byteStart, ni) = best else { continue }
            let charStart = String(decoding: hay[..<byteStart], as: UTF8.self).unicodeScalars.count
            let charLen = needles[ni].unicodeScalars.count
            let origBytes = Array(file.relativePath.utf8)
            let filenameStart = (origBytes.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 }) ?? 0
            let inFilename = byteStart >= filenameStart
            var score: UInt32 = 0
            if inFilename { score += 1_000_000 }
            score += byteStart >= 10_000 ? 0 : UInt32(10_000 - byteStart)
            let pathLen = min(file.relativePath.unicodeScalars.count, 1_000)
            score += UInt32(1_000 - pathLen)
            results.append(SearchResult(path: file.path, filename: file.name, relativePath: file.relativePath, score: score,
                                        matchIndices: (charStart..<(charStart + charLen)).map { UInt32($0) }))
        }
        // Stable sort by score desc.
        let sorted = results.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map { $0.element }
        return Array(sorted.prefix(limit))
    }

    /// `find_file_by_name_impl`: case-insensitive exact basename; fewest path
    /// components wins, ties broken lexicographically.
    public static func findFileByName(root: String, fileName: String, walker: IgnoreWalker? = nil) -> String? {
        let target = fileName.lowercased()
        var matches: [String] = []
        (walker ?? IgnoreWalker(root: root)).walkFiles { path in
            if (path as NSString).lastPathComponent.lowercased() == target { matches.append(path) }
        }
        return matches.min { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            return da != db ? da < db : WorkspaceFS.rustStringLess(a, b)
        }
    }
}

import Foundation

/// A raw filesystem event (what FSEvents / `notify` report), reduced to the
/// distinctions the watcher logic cares about.
public struct RawFSEvent: Equatable {
    public enum Kind: Equatable {
        case created
        case createdFolder
        case modifiedData
        /// Rename / move (`Modify(Name)`) — a membership change.
        case modifiedName
        case modifiedOther
        case removed
        case removedFolder
        case other
    }

    public var kind: Kind
    public var paths: [String]
    public init(kind: Kind, paths: [String]) { self.kind = kind; self.paths = paths }

    /// `event_kind_str`.
    var kindString: String? {
        switch kind {
        case .created, .createdFolder: return "created"
        case .modifiedData, .modifiedName, .modifiedOther: return "modified"
        case .removed, .removedFolder: return "deleted"
        case .other: return nil
        }
    }

    var isFolderEvent: Bool { kind == .createdFolder || kind == .removedFolder }
    var isMembershipChange: Bool {
        switch kind {
        case .created, .createdFolder, .removed, .removedFolder, .modifiedName: return true
        default: return false
        }
    }
}

public enum FileChangeKind: String, Equatable { case created, modified, deleted, renamed }

/// What the watcher tells the UI (`fs:file-changed`, `fs:directory-changed`,
/// `settings:changed`) plus the "rebuild the gitignore matcher" signal.
public enum WatcherOutput: Equatable {
    case fileChanged(path: String, kind: FileChangeKind)
    case directoryChanged(path: String, kind: FileChangeKind)
    case settingsChanged
    case rebuildIgnore
}

/// Own-write suppression: a path written by the app is ignored for 2 s
/// (every event in that window, not just the first).
public struct SelfWriteTracker {
    public static let ttlMs: Double = 2000
    private(set) var writes: [String: Double] = [:]
    public init() {}

    public mutating func recordWrite(_ path: String, nowMs: Double) {
        writes[path] = nowMs
        writes = writes.filter { nowMs - $0.value < SelfWriteTracker.ttlMs }
    }

    public func isSelfWrite(_ path: String, nowMs: Double) -> Bool {
        guard let at = writes[path] else { return false }
        return nowMs - at < SelfWriteTracker.ttlMs
    }

    public var trackedCount: Int { writes.count }
}

/// Port of the workspace watcher thread in `watcher.rs` as a pure state
/// machine: feed events and clock ticks, get outputs. Events are batched and
/// flushed at most once per 300 ms (checked on each event and on idle ticks).
public final class WorkspaceWatcherModel {
    public static let debounceMs: Double = 300

    public let root: String
    public var ignore: WorkspaceIgnore
    public var extensions: SupportedExtensions
    public var selfWrites = SelfWriteTracker()
    public let index: FileIndex?
    /// Filesystem probes (injectable for tests).
    public var isDirectory: (String) -> Bool = WorkspaceFS.isDirectory
    public var exists: (String) -> Bool = WorkspaceFS.exists
    public var modifiedTime: (String) -> UInt64 = WorkspaceFS.modifiedTime

    private var pending: [RawFSEvent] = []
    private var lastEmitMs: Double

    public init(root: String, ignore: WorkspaceIgnore = .bootstrap(), extensions: SupportedExtensions, index: FileIndex?, startMs: Double) {
        self.root = root
        self.ignore = ignore
        self.extensions = extensions
        self.index = index
        self.lastEmitMs = startMs
    }

    public func recordWrite(_ path: String, nowMs: Double) { selfWrites.recordWrite(path, nowMs: nowMs) }

    /// An event arrived (the `recv` branch).
    public func ingest(_ event: RawFSEvent, nowMs: Double) -> [WatcherOutput] {
        pending.append(event)
        return tick(nowMs: nowMs)
    }

    /// Idle timeout (the 300 ms `recv_timeout`).
    public func tick(nowMs: Double) -> [WatcherOutput] {
        if pending.isEmpty || nowMs - lastEmitMs < WorkspaceWatcherModel.debounceMs { return [] }
        let batch = pending
        pending = []
        var out: [WatcherOutput] = []
        var rebuildIgnore = false
        for event in batch {
            for path in event.paths {
                if WorkspaceWatcherModel.shouldIgnore(path, root: root) { continue }
                if WorkspaceIgnore.isGitignorePath(path) { rebuildIgnore = true; continue }
                let isDir = event.isFolderEvent || isDirectory(path)
                if ignore.isIgnored(path, isDir: isDir) { continue }
                if selfWrites.isSelfWrite(path, nowMs: nowMs) { continue }
                if !isDir && extensions.isSupported(path) && exists(path) {
                    index?.updateModifiedAt(path, modifiedTime(path))
                }
                guard let kindStr = event.kindString, let kind = FileChangeKind(rawValue: kindStr) else { continue }
                if isDir {
                    out.append(.directoryChanged(path: path, kind: kind))
                } else {
                    if WorkspaceWatcherModel.isConfigFile(path) {
                        out.append(.settingsChanged)
                        continue
                    }
                    out.append(.fileChanged(path: path, kind: kind))
                }
                guard event.isMembershipChange else { continue }
                let supported = extensions.isSupported(path)
                let pathExists = exists(path)
                if let index = index {
                    if supported {
                        if pathExists { index.add(path, modifiedAt: modifiedTime(path)) } else { index.remove(path) }
                    } else if pathExists && isDir {
                        index.addSubtree(path, extensions: extensions)
                    } else if !pathExists {
                        index.removeSubtree(path)
                    }
                }
                if !isDir {
                    let parent = (path as NSString).deletingLastPathComponent
                    if !parent.isEmpty { out.append(.directoryChanged(path: parent, kind: .modified)) }
                }
            }
        }
        if rebuildIgnore { out.append(.rebuildIgnore) }
        lastEmitMs = nowMs
        return out
    }

    /// Workspace switched away (epoch changed): drop the batch.
    public func discardPending(nowMs: Double) {
        pending = []
        lastEmitMs = nowMs
    }

    /// `should_ignore`: `.git`, `node_modules`, `.DS_Store` and dot-entries
    /// below the root (`.writer` and `.gitignore` pass through).
    public static func shouldIgnore(_ path: String, root: String) -> Bool {
        guard let rel = Gitignore.stripPathPrefix(root, path) else { return false }
        for comp in rel.split(separator: "/") {
            let name = String(comp)
            if name == ".git" || name == "node_modules" || name == ".DS_Store" { return true }
            if name == ".writer" || name == ".gitignore" { continue }
            if name.hasPrefix(".") && name.count > 1 { return true }
        }
        return false
    }

    /// `.writer/config` changes reload settings instead of emitting a file change.
    public static func isConfigFile(_ path: String) -> Bool {
        let ns = path as NSString
        return ns.lastPathComponent == "config" && (ns.deletingLastPathComponent as NSString).lastPathComponent == ".writer"
    }
}

/// Compact-window single-file watcher (`start_file_watcher`): only events for
/// that exact path, own writes suppressed, no index / ignore logic.
public final class StandaloneFileWatcherModel {
    public let file: String
    public var selfWrites = SelfWriteTracker()
    private var pending: [RawFSEvent] = []
    private var lastEmitMs: Double

    public init(file: String, startMs: Double) { self.file = file; lastEmitMs = startMs }

    public func ingest(_ event: RawFSEvent, nowMs: Double) -> [WatcherOutput] {
        pending.append(event)
        return tick(nowMs: nowMs)
    }

    public func tick(nowMs: Double) -> [WatcherOutput] {
        if pending.isEmpty || nowMs - lastEmitMs < WorkspaceWatcherModel.debounceMs { return [] }
        var out: [WatcherOutput] = []
        for event in pending {
            guard let k = event.kindString, let kind = FileChangeKind(rawValue: k) else { continue }
            for path in event.paths where path == file && !selfWrites.isSelfWrite(path, nowMs: nowMs) {
                out.append(.fileChanged(path: path, kind: kind))
            }
        }
        pending = []
        lastEmitMs = nowMs
        return out
    }
}

/// Frontend reaction to `fs:file-changed` (`use-file-watcher.ts`).
@MainActor
public final class FileChangeReconciler {
    public enum Decision: Equatable {
        case notOpen
        case ignoredDeletion
        case saveInFlight
        case reread
    }

    private weak var editor: EditorStore?
    private let reader: EditorStore.Reader
    /// Bumped on every file event (sidebar metadata refresh).
    public var onSidebarMetadataChanged: (() -> Void)?

    public init(editor: EditorStore, reader: @escaping EditorStore.Reader) {
        self.editor = editor
        self.reader = reader
    }

    public func decide(path: String, kind: FileChangeKind) -> Decision {
        guard let editor = editor, editor.file(path) != nil else { return .notOpen }
        if kind == .deleted { return .ignoredDeletion }
        if editor.saveEngine.isSaveInFlight(path) { return .saveInFlight }
        return .reread
    }

    /// Returns true when the buffer was replaced from disk.
    @discardableResult
    public func handleFileChanged(path: String, kind: FileChangeKind) async -> Bool {
        onSidebarMetadataChanged?()
        guard decide(path: path, kind: kind) == .reread, let editor = editor, WorkspaceFS.viewerKind(path) == nil else { return false }
        editor.saveEngine.cancelSave(path)
        guard let content = try? await reader(path) else { return false }
        guard let latest = editor.file(path), content.content != latest.diskContent else { return false }
        editor.reloadFromDisk(path, rawContent: content.content)
        return true
    }
}

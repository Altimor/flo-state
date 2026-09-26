import Foundation

/// A folder / file open request (drop, Dock, argv, Finder) — `PendingOpenPayload`.
public struct PendingOpen: Equatable {
    public var workspace: String?
    public var file: String?
    public init(workspace: String? = nil, file: String? = nil) { self.workspace = workspace; self.file = file }

    /// `open_target.rs::resolve_path`: a directory → workspace payload; an
    /// openable file → file payload; anything else → nil. Paths canonicalized.
    public static func resolve(_ path: String, extensions: SupportedExtensions = .default) -> PendingOpen? {
        if WorkspaceFS.isDirectory(path) { return PendingOpen(workspace: WorkspaceFS.canonicalize(path)) }
        if WorkspaceFS.isFile(path) && extensions.isSupported(path) { return PendingOpen(file: WorkspaceFS.canonicalize(path)) }
        return nil
    }
}

public struct WorkspaceInfo: Equatable {
    public var root: String
    public var name: String
}

/// What the first window should show (`get_startup_state`).
public enum StartupPlan: Equatable {
    /// Compact window for a single file.
    case standaloneFile(String)
    /// Restore a workspace. `openFile` set → open it as a tab; `keepSession`
    /// false → the saved session is discarded (explicit workspace+file open).
    case workspace(root: String, openFile: String?, keepSession: Bool)
    /// Welcome screen.
    case empty
}

/// Workspace open / startup decisions (port of `workspace.rs` +
/// `startup.rs` minus the Tauri plumbing).
public enum WorkspaceBootstrap {
    /// `prepare_workspace_state` (synchronous part): canonicalize, load the
    /// workspace settings layer, record the recent workspace.
    public static func open(_ path: String, settings: AppSettings?, recents: RecentWorkspacesStore?) throws -> WorkspaceInfo {
        let root = try WorkspaceFS.canonicalizeWorkspaceRoot(path)
        let name = (root as NSString).lastPathComponent
        settings?.loadWorkspace(root: URL(fileURLWithPath: root))
        try? recents?.record(root)
        return WorkspaceInfo(root: root, name: name.isEmpty ? root : name)
    }

    /// `active_session_path`: the active tab's file path, for prefetching.
    public static func activeSessionPath(_ session: SessionData?) -> String? {
        guard let s = session, let i = s.activeIndex, i >= 0, i < s.tabs.count else { return nil }
        let loc = s.tabs[i].location
        guard loc.kind == "file", case let .string(p)? = loc.payload.first(where: { $0.0 == "path" })?.1 else { return nil }
        return p
    }

    /// `get_startup_state`'s choice of what to open.
    public static func plan(startupOpen: PendingOpen?, recentWorkspaces: [String], restoreWorkspace: Bool,
                            isDirectory: (String) -> Bool = WorkspaceFS.isDirectory) -> StartupPlan {
        var open = startupOpen
        var reopenedInWorkspace = false
        if let o = open, o.workspace == nil, let file = o.file {
            // A bare file inside a known workspace reopens that workspace.
            let owner = recentWorkspaces.first { isDirectory($0) && Gitignore.stripPathPrefix($0, file) != nil }
            reopenedInWorkspace = owner != nil
            open = PendingOpen(workspace: owner, file: file)
        }
        if let o = open, o.workspace == nil, let file = o.file { return .standaloneFile(file) }
        if let o = open, let ws = o.workspace {
            return .workspace(root: ws, openFile: o.file, keepSession: o.file == nil || reopenedInWorkspace)
        }
        if restoreWorkspace, let first = recentWorkspaces.first, isDirectory(first) {
            return .workspace(root: first, openFile: nil, keepSession: true)
        }
        return .empty
    }

    /// Where a file opened from Finder lands (commit fa649ea): the window
    /// whose workspace contains it, else a compact window.
    public static func owningWorkspace(of file: String, among roots: [String]) -> String? {
        roots.first { file != $0 && Gitignore.stripPathPrefix($0, file) != nil }
    }
}

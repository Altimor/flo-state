import Foundation

/// Where the native app keeps its app-data files. Same file names and JSON
/// formats as the Tauri app's `{app_data}` dir so they are interchangeable.
public struct AppDataDirectory {
    public static let configFileName = "config"
    public static let sessionsFileName = "sessions.json"
    public static let recentWorkspacesFileName = "recent_workspaces.json"
    public static let recentFilesFileName = "recent_files.json"

    /// Files copied from the web app's data dir on first run.
    public static let importedFileNames = [configFileName, sessionsFileName, recentWorkspacesFileName, recentFilesFileName]

    public let baseURL: URL

    public init(baseURL: URL) { self.baseURL = baseURL }

    public static var defaultBaseURL: URL {
        applicationSupport.appendingPathComponent("FloStateNative", isDirectory: true)
    }

    /// The Tauri app's data dir (bundle identifier `com.writer-computer`).
    public static var legacyBaseURL: URL {
        applicationSupport.appendingPathComponent("com.writer-computer", isDirectory: true)
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    public var configURL: URL { baseURL.appendingPathComponent(Self.configFileName) }
    public var sessionsURL: URL { baseURL.appendingPathComponent(Self.sessionsFileName) }
    public var recentWorkspacesURL: URL { baseURL.appendingPathComponent(Self.recentWorkspacesFileName) }
    public var recentFilesURL: URL { baseURL.appendingPathComponent(Self.recentFilesFileName) }

    /// Creates the directory. On first run (directory absent) copies the web
    /// app's files over from `legacyURL` when it exists. Returns the names of
    /// the files imported (empty when nothing was imported).
    @discardableResult
    public func prepare(importingFrom legacyURL: URL? = AppDataDirectory.legacyBaseURL) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue { return [] }
        try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        guard let legacy = legacyURL, fm.fileExists(atPath: legacy.path) else { return [] }
        var imported: [String] = []
        for name in Self.importedFileNames {
            let src = legacy.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = baseURL.appendingPathComponent(name)
            do {
                try fm.copyItem(at: src, to: dst)
                imported.append(name)
            } catch {
                continue
            }
        }
        return imported
    }
}

/// Write-to-temp + rename in the same directory.
enum AtomicFile {
    static func write(_ data: Data, to url: URL, tempName: String) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(tempName)
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}

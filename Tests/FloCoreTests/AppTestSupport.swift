import Foundation
import XCTest
@testable import FloCore

/// Temp directory helpers for the App* test suites.
enum AppTestFS {
    /// A fresh canonical (`/private/var/...`) temp directory.
    static func makeTempDir(_ name: String = "app") -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("flo-\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return WorkspaceFS.canonicalize(base.path)
    }

    static func write(_ path: String, _ content: String) {
        let url = URL(fileURLWithPath: path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: url)
    }

    static func read(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func mkdir(_ path: String) {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    static func setMTime(_ path: String, _ secs: TimeInterval) {
        try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: secs)], ofItemAtPath: path)
    }
}

/// A walker that never consults the user's global git excludes.
func isolatedWalker(_ root: String) -> IgnoreWalker { IgnoreWalker(root: root, globalExcludes: nil) }

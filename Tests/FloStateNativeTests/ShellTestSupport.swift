import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

enum TFS {
    static func tempDir(_ name: String = "shell") -> String {
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
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
}

/// A workspace + app-data dir pair with a model wired to a manual clock.
@MainActor
final class ShellFixture {
    let root: String
    let data: String
    let scheduler = ManualScheduler()
    let model: ShellModel
    var alerts: [String] = []

    init(files: [String: String] = [:], config: String = "", session: SessionData? = nil) {
        root = TFS.tempDir("ws")
        data = TFS.tempDir("data")
        for (rel, content) in files { TFS.write(root + "/" + rel, content) }
        TFS.write(data + "/config", config)
        if let s = session {
            let store = SessionStore(url: URL(fileURLWithPath: data + "/sessions.json"))
            try! store.save(root: root, tabs: s.tabs, activeIndex: s.activeIndex)
        }
        model = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)), scheduler: scheduler, importLegacy: false)
        model.watcherEnabled = false
        model.systemIsDark = { false }
        model.alert = { [unowned self] in self.alerts.append($0) }
        model.confirm = { _ in true }
        model.copyToPasteboard = { [unowned self] in self.pasteboard = $0 }
        model.revealInFinder = { _ in }
    }
    var pasteboard: String?

    func p(_ rel: String) -> String { root + "/" + rel }

    func open(file: String? = nil, keepSession: Bool = true) async {
        await model.openWorkspace(root, openFile: file.map(p), keepSession: keepSession)
    }

    /// Let spawned Tasks run.
    func settle(_ n: Int = 20) async {
        for _ in 0..<n { await Task.yield() }
        try? await Task.sleep(nanoseconds: 60_000_000)
        for _ in 0..<n { await Task.yield() }
    }

    static func fileTab(_ path: String) -> SessionTab {
        SessionTab(location: SerializedLocation(kind: "file", payload: [("path", .string(path))]))
    }
}

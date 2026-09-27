import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// Opening one note from a busy folder (e.g. ~/Downloads) must not turn that
/// folder into a workspace: no scan, nothing added to the sidebar.
@MainActor
final class OpenSingleFileTests: XCTestCase {
    func testColdLaunchWithOneFileDoesNotScanItsFolder() async {
        let f = ShellFixture(files: ["note.md": "# Note\n", "other1.md": "x", "other2.md": "y", "sub/deep.md": "z"])
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [f.p("note.md")], offscreen: true)
        app.startup()
        await app.waitForPendingOpens()
        for _ in 0..<20 { await Task.yield() }
        let m = app.windows.first?.model
        XCTAssertNil(m?.root)
        for c in app.windows { c.window?.close() }
    }

    func testOpenFileWhileRunningWithNoWorkspace() async {
        let f = ShellFixture(files: ["note.md": "# Note\n", "other1.md": "x"])
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [], offscreen: true)
        app.startup()
        await app.waitForPendingOpens()
        app.open(paths: [f.p("note.md")])
        await app.waitForPendingOpens()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(app.windows.allSatisfy { $0.model.root == nil })
        for c in app.windows { c.window?.close() }
    }

    /// Welcome screen "Open File…" (live bug: it opened the note's folder as a
    /// workspace, scanning e.g. all of ~/Downloads into the sidebar and recents).
    func testWelcomeOpenFileOpensJustTheNote() async {
        let f = ShellFixture(files: ["note.md": "# Note\n", "other1.md": "x", "sub/deep.md": "z"])
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [], offscreen: true)
        app.startup()
        await app.waitForPendingOpens()
        XCTAssertEqual(app.windows.count, 1, "welcome window")
        app.windows[0].model.openPickedFile(f.p("note.md"))
        await app.waitForPendingOpens()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(app.windows.count, 1, "the empty welcome window is replaced")
        let m = app.windows[0].model
        XCTAssertNil(m.root, "no workspace, no folder scan")
        XCTAssertNil(m.index)
        XCTAssertEqual(m.editor.tabs.map(\.location), [.file(f.p("note.md"))])
        XCTAssertEqual(RecentWorkspacesStore(appData: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data))).load(), [])
        for c in app.windows { c.window?.close() }
    }

    /// Live bug (0.1.2): New Note did nothing when no folder was open.
    func testNewNoteWithNothingOpenAsksWhereAndOpensIt() async {
        let f = ShellFixture()
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [], offscreen: true)
        app.startup()
        await app.waitForPendingOpens()
        let target = f.p("Untitled.md")
        app.windows[0].model.chooseNewNotePath = { target }
        app.windows[0].model.perform(.newNote)
        await app.waitForPendingOpens()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(TFS.exists(target))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.windows[0].model.editor.tabs.map(\.location), [.file(target)])
        XCTAssertNil(app.windows[0].model.root)
        for c in app.windows { c.window?.close() }
    }

    func testNewNoteInCompactWindowCreatesNextToTheFile() async {
        let f = ShellFixture(files: ["note.md": "# Note\n"])
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [f.p("note.md")], offscreen: true)
        app.startup()
        await app.waitForPendingOpens()
        let m = app.windows[0].model
        XCTAssertTrue(m.isCompact)
        m.perform(.newNote)
        XCTAssertEqual(m.palette?.intent, .createFile)
        m.setPaletteQuery("Second")
        m.runSelectedPaletteItem()
        await app.waitForPendingOpens()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(TFS.exists(f.p("Second.md")))
        for c in app.windows { c.window?.close() }
    }
}

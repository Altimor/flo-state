import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// Launch / quit / reopen vs. the stored session. Regression: a hidden launch
/// (`open -g -j`) quit ~20s later wiped the workspace's session, and AppKit
/// showed its own Open panel.
@MainActor
final class LaunchSessionTests: XCTestCase {
    private func sessionsURL(_ f: ShellFixture) -> URL { URL(fileURLWithPath: f.data + "/sessions.json") }
    private func stored(_ f: ShellFixture) -> [SerializedLocation]? {
        SessionStore(url: sessionsURL(f)).load(root: f.root)?.tabs.map { $0.location }
    }
    private func twoTabFixture() -> ShellFixture {
        let f = ShellFixture(files: ["a.md": "# Alpha\n", "b.md": "Beta\n"])
        try! SessionStore(url: sessionsURL(f)).save(root: f.root, tabs: [ShellFixture.fileTab(f.p("a.md")), ShellFixture.fileTab(f.p("b.md"))], activeIndex: 1)
        return f
    }

    // MARK: model: quitting during startup

    func testQuitDuringStartupKeepsStoredSession() async {
        let f = twoTabFixture()
        let before = stored(f)
        XCTAssertEqual(before?.count, 2)
        let open = Task { await f.open() }
        // quit before the open ran, and at every step while it restores
        f.model.windowWillClose()
        XCTAssertEqual(stored(f), before)
        for _ in 0..<5 {
            await Task.yield()
            f.model.windowWillClose()
            f.scheduler.advance(byMs: 1000)
            XCTAssertEqual(stored(f), before, "no empty / partial session written while restoring")
        }
        await open.value
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.file(f.p("a.md")), .file(f.p("b.md"))])
        XCTAssertEqual(f.model.sessionAutosaver.state, .armed)
        // quitting after restore saves normally
        f.model.windowWillClose()
        XCTAssertEqual(stored(f), before)
        XCTAssertEqual(SessionStore(url: sessionsURL(f)).load(root: f.root)?.activeIndex, 1)
    }

    func testLauncherBeforeRestoreIsNeverSaved() async {
        let f = twoTabFixture()
        let before = stored(f)
        // a window/tab created before the workspace restore: root known, restore not done
        await f.open()
        f.model.sessionAutosaver.disarm()
        f.model.editor.reset()
        f.model.editor.ensureLauncherTab()
        f.scheduler.advance(byMs: 1000)
        f.model.windowWillClose()
        XCTAssertEqual(stored(f), before)
    }

    func testFailedRestoreKeepsStoredSessionUntilUserChangesTabs() async {
        let f = twoTabFixture()
        try! FileManager.default.removeItem(atPath: f.p("a.md"))
        try! FileManager.default.removeItem(atPath: f.p("b.md"))
        let before = stored(f)
        await f.open()
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.launcher], "unreadable files → launcher")
        f.scheduler.advance(byMs: 1000)
        f.model.windowWillClose()
        XCTAssertEqual(stored(f), before, "a failed restore never replaces the session with a launcher")
        // the user's next tab change is saved normally
        TFS.write(f.p("c.md"), "c")
        try! await f.model.editor.openFileInTabOrFocus(f.p("c.md"))
        f.model.windowWillClose()
        XCTAssertEqual(stored(f), [ShellFixture.fileTab(f.p("c.md")).location])
    }

    func testNoStoredSessionLauncherQuitWritesNothing() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open()
        f.model.windowWillClose()
        XCTAssertNil(stored(f))
    }

    // MARK: app delegate: hidden launch, reopen, no AppKit Open panel

    private func makeApp(_ f: ShellFixture) -> AppDelegate {
        try! RecentWorkspacesStore(url: URL(fileURLWithPath: f.data + "/recent_workspaces.json")).record(f.root)
        return AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [], offscreen: true)
    }

    /// `open -g -j`: startup runs with no visible / key window and no
    /// activation; it restores the last workspace and its tabs all the same.
    func testHiddenLaunchRestoresLastWorkspaceTabs() async {
        let f = twoTabFixture()
        let app = makeApp(f)
        app.startup()
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.reopenAction(hasVisibleWindows: false), .showExisting, "reopen while restoring never starts a second startup")
        await app.waitForPendingOpens()
        let m = app.windows[0].model
        XCTAssertEqual(m.root, f.root)
        XCTAssertEqual(m.editor.tabs.map { $0.location }, [.file(f.p("a.md")), .file(f.p("b.md"))])
        XCTAssertEqual(m.editor.activeFilePath, f.p("b.md"))
        XCTAssertFalse(app.windows[0].window!.isVisible, "offscreen test windows are never ordered front")
        // Dock click with the (hidden) window: shows it, no new window / startup
        XCTAssertEqual(app.reopenAction(hasVisibleWindows: false), .showExisting)
        XCTAssertFalse(app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(app.windows.count, 1)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(stored(f)?.count, 2)
        for c in app.windows { c.window?.close() }
    }

    func testQuitRightAfterHiddenLaunchKeepsSession() async {
        let f = twoTabFixture()
        let before = stored(f)
        let app = makeApp(f)
        app.startup()
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(stored(f), before)
        await app.waitForPendingOpens()
        for c in app.windows { c.window?.close() }
        XCTAssertEqual(stored(f), before)
    }

    func testReopenWithNoWindowsRestoresLastWorkspace() async {
        let f = twoTabFixture()
        let app = makeApp(f)
        XCTAssertEqual(app.reopenAction(hasVisibleWindows: false), .startup)
        XCTAssertEqual(app.reopenAction(hasVisibleWindows: true), .none)
        XCTAssertFalse(app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false),
                       "false: AppKit must not add its untitled-document / Open panel flow")
        await app.waitForPendingOpens()
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.windows[0].model.editor.tabs.count, 2)
        for c in app.windows { c.window?.close() }
    }

    func testNoAppKitOpenPanelAtLaunch() {
        let f = ShellFixture()
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [], offscreen: true)
        XCTAssertFalse(app.applicationShouldOpenUntitledFile(NSApplication.shared))
        XCTAssertTrue(app.applicationOpenUntitledFile(NSApplication.shared), "handled: nothing for AppKit to do")
        XCTAssertTrue(app.windows.isEmpty)
        let suite = "flostate-launch-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        FloApp.registerLaunchDefaults(d)
        XCTAssertEqual(d.object(forKey: "NSShowAppCentricOpenPanelInsteadOfUntitledFile") as? Bool, false)
        d.removePersistentDomain(forName: suite)
    }
}

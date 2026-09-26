import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

@MainActor
final class ShellWorkspaceTests: XCTestCase {
    func testOpenWorkspaceWithoutSessionShowsLauncher() async {
        let f = ShellFixture(files: ["a.md": "# Alpha\n", "b.md": "Beta\n"])
        await f.open()
        XCTAssertEqual(f.model.root, f.root)
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.launcher])
        XCTAssertEqual(f.model.workspaceName, (f.root as NSString).lastPathComponent)
        XCTAssertEqual(f.model.editor.windowTitle(), "New Tab")
        // recorded as a recent workspace
        XCTAssertEqual(f.model.recentWorkspacesStore.load().first, f.root)
    }

    func testSessionRestoreAndDebouncedSave() async {
        let f = ShellFixture(files: ["a.md": "# Alpha\n", "b.md": "Beta\n"])
        let session = SessionData(tabs: [ShellFixture.fileTab(f.p("a.md")), ShellFixture.fileTab(f.p("b.md"))], activeIndex: 1)
        try! SessionStore(url: URL(fileURLWithPath: f.data + "/sessions.json")).save(root: f.root, tabs: session.tabs, activeIndex: 1)
        await f.open()
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.file(f.p("a.md")), .file(f.p("b.md"))])
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("b.md"))
        XCTAssertEqual(f.model.editor.tabTitle(f.model.editor.tabs[0]), "Alpha")
        XCTAssertEqual(f.model.editor.tabTitle(f.model.editor.tabs[1]), "b.md")
        // switching tabs saves the session after 500ms
        f.model.perform(.selectTab(1))
        f.scheduler.advance(byMs: 499)
        XCTAssertEqual(SessionStore(url: URL(fileURLWithPath: f.data + "/sessions.json")).load(root: f.root)?.activeIndex, 1)
        f.scheduler.advance(byMs: 1)
        XCTAssertEqual(SessionStore(url: URL(fileURLWithPath: f.data + "/sessions.json")).load(root: f.root)?.activeIndex, 0)
    }

    func testRestoreOpenFilesOffIgnoresSession() async {
        let f = ShellFixture(files: ["a.md": "x"], config: "workspace.restore-open-files = false\n")
        try! SessionStore(url: URL(fileURLWithPath: f.data + "/sessions.json")).save(root: f.root, tabs: [ShellFixture.fileTab(f.p("a.md"))], activeIndex: 0)
        await f.open()
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.launcher])
    }

    func testOpenWorkspaceWithFileOpensTab() async {
        let f = ShellFixture(files: ["a.md": "# A\n", "sub/b.md": "# B\n"])
        await f.open(file: "sub/b.md")
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("sub/b.md"))
    }

    func testOpeningSecondWorkspaceGoesToAnotherWindow() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open()
        var elsewhere: String?
        f.model.openWorkspaceElsewhere = { elsewhere = $0 }
        await f.model.openWorkspace("/tmp")
        XCTAssertEqual(elsewhere, "/tmp")
        XCTAssertEqual(f.model.root, f.root)
    }

    func testCloseWorkspaceFlushesSessionAndClears() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open()
        try! await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        f.model.closeWorkspace()
        XCTAssertNil(f.model.root)
        XCTAssertTrue(f.model.editor.tabs.isEmpty)
        XCTAssertFalse(f.model.sidebarVisible)
        let saved = SessionStore(url: URL(fileURLWithPath: f.data + "/sessions.json")).load(root: f.root)
        XCTAssertEqual(saved?.tabs.first?.location.kind, "file")
    }
}

@MainActor
final class ShellAutosaveTests: XCTestCase {
    func testEditsAutosaveThrottledWithFinalNewline() async {
        let f = ShellFixture(files: ["a.md": "# A"])
        await f.open(file: "a.md")
        let path = f.p("a.md")
        f.model.editor.updateContent(path, "# A!")
        // first save is immediate (more than 1s since the last)
        XCTAssertEqual(TFS.read(path), "# A!\n")
        XCTAssertEqual(f.model.editor.file(path)?.isDirty, false)
        // save.ts drops the controller once idle, so a later edit saves at once too
        f.model.editor.updateContent(path, "# A!!")
        XCTAssertEqual(TFS.read(path), "# A!!\n")
        XCTAssertEqual(f.model.editor.windowTitle(), f.model.editor.tabTitle(f.model.editor.activeTab!))
    }

    func testTrimTrailingWhitespaceSetting() async {
        let f = ShellFixture(files: ["a.md": "x"], config: "files.trim-trailing-whitespace = true\nfiles.insert-final-newline = false\n")
        await f.open(file: "a.md")
        f.model.editor.updateContent(f.p("a.md"), "x   \ny\t")
        XCTAssertEqual(TFS.read(f.p("a.md")), "x\ny")
    }

    func testFrontmatterPreservedOnSave() async {
        let f = ShellFixture(files: ["a.md": "---\ntitle: T\n---\nbody"])
        await f.open(file: "a.md")
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.content, "body")
        f.model.editor.updateContent(f.p("a.md"), "body2")
        XCTAssertEqual(TFS.read(f.p("a.md")), "---\ntitle: T\n---\nbody2\n")
    }

    func testCloseFlushesThrottledEdits() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open(file: "a.md")
        // a failed write leaves the buffer dirty; closing retries it
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root)
        f.model.editor.updateContent(f.p("a.md"), "two")
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root)
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.isDirty, true)
        f.model.windowWillClose()
        XCTAssertEqual(TFS.read(f.p("a.md")), "two\n")
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.isDirty, false)
        XCTAssertFalse(f.model.editor.saveEngine.hasController(f.p("a.md")))
    }

    func testReadOnlyNeverWrites() async {
        let f = ShellFixture(files: ["a.md": "x"])
        f.model.readOnly = true
        await f.open(file: "a.md")
        f.model.editor.updateContent(f.p("a.md"), "changed")
        f.scheduler.advance(byMs: 5000)
        XCTAssertEqual(TFS.read(f.p("a.md")), "x")
    }
}

@MainActor
final class ShellWatcherTests: XCTestCase {
    func testExternalChangeReloadsBuffer() async {
        let f = ShellFixture(files: ["a.md": "one"])
        await f.open(file: "a.md")
        TFS.write(f.p("a.md"), "two")
        f.model.handleWatcherOutputs([.fileChanged(path: f.p("a.md"), kind: .modified)])
        await f.settle()
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.content, "two")
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.reloadVersion, 1)
    }

    func testDeletionIsIgnored() async {
        let f = ShellFixture(files: ["a.md": "one"])
        await f.open(file: "a.md")
        try? FileManager.default.removeItem(atPath: f.p("a.md"))
        f.model.handleWatcherOutputs([.fileChanged(path: f.p("a.md"), kind: .deleted)])
        await f.settle()
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.content, "one")
    }

    func testDirectoryChangeRefreshesTree() async {
        let f = ShellFixture(files: ["a.md": "one"])
        await f.open()
        XCTAssertEqual(f.model.flatTree().map { $0.entry.name }, ["a.md"])
        TFS.write(f.p("b.md"), "# Bee")
        f.model.handleWatcherOutputs([.directoryChanged(path: f.root, kind: .modified)])
        XCTAssertEqual(f.model.flatTree().map { $0.entry.name }, ["a.md", "b.md"])
        XCTAssertEqual(f.model.label(for: f.model.flatTree()[1].entry), "Bee")
    }

    func testWorkspaceConfigChangeReloadsSettings() async {
        let f = ShellFixture(files: ["a.md": "one"])
        await f.open()
        XCTAssertEqual(f.model.values.editorFontSize, 16)
        TFS.write(f.p(".writer/config"), "editor.font-size = 20\n")
        var sawFont = false
        f.model.observers.append { if $0 == .editorFont { sawFont = true } }
        f.model.handleWatcherOutputs([.settingsChanged])
        XCTAssertEqual(f.model.values.editorFontSize, 20)
        XCTAssertTrue(sawFont)
    }

    /// Real FSEvents end to end: an external write reaches the open buffer.
    func testFSEventsEndToEnd() async throws {
        let f = ShellFixture(files: ["a.md": "one"])
        f.model.watcherEnabled = true
        let real = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), importLegacy: false)
        await real.openWorkspace(f.root, openFile: f.p("a.md"))
        try await Task.sleep(nanoseconds: 700_000_000)
        TFS.write(f.p("a.md"), "external")
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if real.editor.file(f.p("a.md"))?.content == "external" { break }
        }
        XCTAssertEqual(real.editor.file(f.p("a.md"))?.content, "external")
        real.windowWillClose()
    }

    func testOwnWritesAreSuppressed() async throws {
        let f = ShellFixture(files: ["a.md": "one"])
        let real = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), importLegacy: false)
        await real.openWorkspace(f.root, openFile: f.p("a.md"))
        real.editor.updateContent(f.p("a.md"), "mine")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(real.editor.file(f.p("a.md"))?.reloadVersion, 0)
        XCTAssertEqual(TFS.read(f.p("a.md")), "mine\n")
        real.windowWillClose()
    }

    func testFSEventFlagMapping() {
        typealias F = FSEventStreamEventFlags
        let created = F(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        XCTAssertEqual(FSEventsStream.map(path: "/x", flags: created, exists: { _ in true }).kind, .created)
        let dirCreated = F(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        XCTAssertEqual(FSEventsStream.map(path: "/x", flags: dirCreated, exists: { _ in true }).kind, .createdFolder)
        let removed = F(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        XCTAssertEqual(FSEventsStream.map(path: "/x", flags: removed, exists: { _ in false }).kind, .removed)
        // created + removed in one window but present again → not a removal
        let churn = F(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified)
        XCTAssertEqual(FSEventsStream.map(path: "/x", flags: churn, exists: { _ in true }).kind, .modifiedData)
        let renamed = F(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        XCTAssertEqual(FSEventsStream.map(path: "/x", flags: renamed, exists: { _ in true }).kind, .modifiedName)
        let modified = F(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        XCTAssertEqual(FSEventsStream.map(path: "/x", flags: modified, exists: { _ in true }).kind, .modifiedData)
    }
}

@MainActor
final class ShellTabTests: XCTestCase {
    func fixture() async -> ShellFixture {
        let f = ShellFixture(files: ["a.md": "# A\n", "b.md": "# B\n", "c.md": "# C\n", "d/e.md": "# E\n"])
        await f.open()
        return f
    }

    func testTreeClickFillsLauncherThenOpensNewTabsAndFocusesExisting() async {
        let f = await fixture()
        let entries = f.model.flatTree().map { $0.entry }
        let a = entries.first { $0.name == "a.md" }!, b = entries.first { $0.name == "b.md" }!
        f.model.clickTreeRow(a)
        await f.settle()
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.file(f.p("a.md"))], "launcher filled in place")
        f.model.clickTreeRow(b)
        await f.settle()
        XCTAssertEqual(f.model.editor.tabs.count, 2)
        f.model.clickTreeRow(a)
        await f.settle()
        XCTAssertEqual(f.model.editor.tabs.count, 2, "existing tab focused")
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"))
    }

    func testPinnedClickNavigatesInPlaceWithHistory() async {
        let f = await fixture()
        try! await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.model.editor.openFile(f.p("b.md"))
        XCTAssertEqual(f.model.editor.tabs.count, 1)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("b.md"))
        f.model.perform(.back)
        await f.settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"))
        f.model.perform(.forward)
        await f.settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("b.md"))
    }

    func testCloseRulesAndLastTabClosesWindow() async {
        let f = await fixture()
        for n in ["a.md", "b.md", "c.md"] { try! await f.model.editor.openFileInTabOrFocus(f.p(n)) }
        XCTAssertEqual(f.model.editor.tabs.count, 3) // launcher was filled by a.md
        f.model.perform(.selectTab(2))
        f.model.perform(.closeTab)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("c.md"), "right neighbour becomes active")
        f.model.perform(.closeTab)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"), "else the left one")
        var closed = false
        f.model.requestWindowClose = { closed = true }
        f.model.perform(.closeTab)
        XCTAssertTrue(closed)
        XCTAssertTrue(f.model.editor.tabs.isEmpty)
    }

    func testCycleAndNumberShortcuts() async {
        let f = await fixture()
        for n in ["a.md", "b.md", "c.md"] { try! await f.model.editor.openFileInTabOrFocus(f.p(n)) }
        f.model.perform(.selectTab(1))
        f.model.perform(.previousTab)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("c.md"), "wraps around")
        f.model.perform(.nextTab)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"))
        f.model.perform(.selectTab(9))
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"), "out of range is a no-op")
        f.model.perform(.selectTab(3))
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("c.md"))
    }

    func testNewTabAndSettingsOpenTheWindowNotATab() async {
        let f = await fixture()
        try! await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        f.model.perform(.newTab)
        XCTAssertEqual(f.model.editor.activeTab?.location, .launcher)
        XCTAssertEqual(f.model.editor.windowTitle(), "New Tab")
        var opened = 0
        f.model.openSettingsWindow = { opened += 1 }
        f.model.perform(.openPreferences)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.file(f.p("a.md")), .launcher], "no settings tab")
    }

    func testRestoredSettingsTabsArePurged() async {
        let f = ShellFixture(files: ["a.md": "x"])
        let settingsTab = SessionTab(location: SerializedLocation(kind: "settings", payload: []))
        try! SessionStore(url: URL(fileURLWithPath: f.data + "/sessions.json")).save(root: f.root, tabs: [ShellFixture.fileTab(f.p("a.md")), settingsTab], activeIndex: 1)
        await f.open()
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.file(f.p("a.md"))])
        let g = ShellFixture(files: ["a.md": "x"])
        try! SessionStore(url: URL(fileURLWithPath: g.data + "/sessions.json")).save(root: g.root, tabs: [settingsTab], activeIndex: 0)
        var closed = false
        g.model.requestWindowClose = { closed = true }
        await g.open()
        XCTAssertEqual(g.model.editor.tabs.map { $0.location }, [.launcher], "the last one becomes a launcher")
        XCTAssertFalse(closed)
    }

    func testStepFileStopsAtEnds() async {
        let f = await fixture()
        // visible order: d (folder, collapsed), a, b, c
        f.model.perform(.stepFile(1))
        await f.settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"), "off-tree starts at the top")
        f.model.perform(.stepFile(1)); await f.settle()
        f.model.perform(.stepFile(1)); await f.settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("c.md"))
        f.model.perform(.stepFile(1)); await f.settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("c.md"), "no wrap")
        f.model.toggleDirectory(f.p("d"))
        f.model.perform(.stepFile(-1)); await f.settle()
        f.model.perform(.stepFile(-1)); await f.settle()
        f.model.perform(.stepFile(-1)); await f.settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("d/e.md"), "walks into expanded folders")
        XCTAssertEqual(f.model.editor.tabs.count, 1, "steps in the current tab")
    }

    func testTabContextMenuItems() async {
        let f = await fixture()
        try! await f.model.editor.openFileInTabOrFocus(f.p("d/e.md"))
        let tab = f.model.editor.activeTab!
        let menu = ShellMenus.tabMenu(model: f.model, tab: tab)!
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }, ["Close", "Close others", "Close all", "-", "Reveal in sidebar", "Copy path"])
        (menu.items[5] as! ClosureMenuItem).fire()
        XCTAssertEqual(f.pasteboard, "d/e.md")
        f.model.setSetting("appearance.sidebar-visible", .bool(false))
        (menu.items[4] as! ClosureMenuItem).fire()
        XCTAssertTrue(f.model.isExpanded(f.p("d")))
        XCTAssertTrue(f.model.sidebarPreferenceVisible)
        XCTAssertNil(ShellMenus.tabMenu(model: f.model, tab: Tab(id: "x", location: .settings)))
    }
}

@MainActor
final class ShellSidebarTests: XCTestCase {
    func testAutoHideBelow850WithoutTouchingPreference() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open()
        f.model.windowWidth = 1200
        XCTAssertTrue(f.model.sidebarVisible)
        XCTAssertEqual(f.model.tabStripLeft, 252) // 240 + 12
        f.model.windowWidth = 849
        XCTAssertFalse(f.model.sidebarVisible)
        XCTAssertTrue(f.model.sidebarPreferenceVisible)
        XCTAssertEqual(f.model.tabStripLeft, 132)
        f.model.windowWidth = 850
        XCTAssertTrue(f.model.sidebarVisible)
        // toggling while narrow flips only the preference (quirk 6)
        f.model.windowWidth = 800
        f.model.perform(.toggleSidebar)
        XCTAssertFalse(f.model.sidebarPreferenceVisible)
        f.model.windowWidth = 1200
        XCTAssertFalse(f.model.sidebarVisible)
        XCTAssertTrue(TFS.read(f.data + "/config")!.contains("appearance.sidebar-visible = false"))
    }

    func testSidebarWidthClamp() {
        XCTAssertEqual(Metrics.clampSidebarWidth(240, viewport: 1200), 240)
        XCTAssertEqual(Metrics.clampSidebarWidth(100, viewport: 1200), 220)
        XCTAssertEqual(Metrics.clampSidebarWidth(500, viewport: 1200), 420)
        XCTAssertEqual(Metrics.clampSidebarWidth(500, viewport: 1000), 350)
        XCTAssertEqual(Metrics.clampSidebarWidth(500, viewport: 600), 280)
        XCTAssertEqual(Metrics.clampSidebarWidth(313.4, viewport: 1400), 313)
    }

    func testTreeOrderLabelsAndHiddenEntries() async {
        let f = ShellFixture(files: ["b.md": "# Bee Title\n", "A.md": "plain", ".hidden.md": "x", "img.png": "x",
                                     "Zdir/x.md": "# X", "empty/readme.txt2": "x", "node/y.md": "# Y"])
        await f.open()
        XCTAssertEqual(f.model.flatTree().map { $0.entry.name }, ["node", "Zdir", "A.md", "b.md"])
        let labels = f.model.flatTree().map { f.model.label(for: $0.entry) }
        XCTAssertEqual(labels, ["node", "Zdir", "A", "Bee Title"])
        f.model.setSetting("appearance.sidebar-file-label", .string("filename"))
        XCTAssertEqual(f.model.label(for: f.model.flatTree()[3].entry), "b")
    }

    func testSidebarLayoutMatchesWebOffsets() {
        let e = { (n: String) in DirEntry(name: n, path: "/r/" + n, isDir: false, isMarkdown: true, modifiedAt: 0, title: nil) }
        let items: [SidebarItem] = [.header(.recents, collapsed: false), .row(e("a"), depth: 0, section: .recents),
                                    .row(e("b"), depth: 0, section: .recents), .showMore(.recents), .gap(16),
                                    .row(e("c"), depth: 0, section: .tree), .row(e("d"), depth: 1, section: .tree)]
        let placed = SidebarLayout.place(items).placed.map { $0.y }
        // web: header 73-65=8, rows 32 (+4 under header), 1px gaps, 16px between blocks
        XCTAssertEqual(placed, [8, 32, 65, 98, 146, 179])
    }

    func testRecentsSectionRequiresTenFilesAndSkipsPinned() async {
        var files: [String: String] = [:]
        for i in 0..<9 { files["f\(i).md"] = "\(i)" }
        let f = ShellFixture(files: files)
        await f.open()
        XCTAssertTrue(f.model.recentsSection().files.isEmpty, "fewer than 10 files → no Recents")
        let g = ShellFixture(files: files.merging(["f9.md": "9", "f10.md": "10"]) { a, _ in a })
        for i in 0...10 { try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000_000 + i))], ofItemAtPath: g.p("f\(i).md")) }
        await g.open()
        XCTAssertEqual(g.model.recentsSection().files.map { $0.name }, ["f10.md", "f9.md", "f8.md", "f7.md"])
        XCTAssertTrue(g.model.recentsSection().hasMore)
        g.model.togglePinned(g.p("f9.md"))
        XCTAssertEqual(g.model.pinnedSection().files.map { $0.name }, ["f9.md"])
        XCTAssertEqual(g.model.recentsSection().files.map { $0.name }, ["f10.md", "f8.md", "f7.md", "f6.md"])
        g.model.recentVisibleCount += 4
        XCTAssertEqual(g.model.recentsSection().files.count, 8)
        // pinned persisted per workspace
        XCTAssertEqual(PinnedStore(url: URL(fileURLWithPath: g.data + "/sidebar_pinned.json")).load(root: g.root), [g.p("f9.md")])
        g.model.setSetting("appearance.sidebar-show-recents", .bool(false))
        XCTAssertTrue(g.model.recentsSection().files.isEmpty)
    }

    func testNewFileNewFolderRenameDeleteMove() async {
        let f = ShellFixture(files: ["dir/x.md": "# X", "top.md": "# Top"])
        await f.open()
        f.model.createFileInFolder(f.p("dir"))
        XCTAssertEqual(TFS.read(f.p("dir/Untitled.md")), "# ")
        XCTAssertEqual(f.model.renamingPath, f.p("dir/Untitled.md"))
        XCTAssertTrue(f.model.isExpanded(f.p("dir")))
        f.model.createFileInFolder(f.p("dir"))
        XCTAssertTrue(TFS.exists(f.p("dir/Untitled 2.md")))
        let entry = f.model.entries(f.p("dir")).first { $0.name == "Untitled.md" }!
        f.model.submitRename(entry, "  Renamed  ")
        XCTAssertNil(f.model.renamingPath)
        XCTAssertTrue(TFS.exists(f.p("dir/Renamed.md")))
        let e2 = f.model.entries(f.p("dir")).first { $0.name == "Untitled 2.md" }!
        f.model.submitRename(e2, "Renamed")
        XCTAssertEqual(f.alerts.last, "A file named \"Renamed.md\" already exists.")
        f.model.createFolderInFolder(f.p("dir"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.p("dir/Untitled Folder")))
        // move top.md into dir
        let top = f.model.entries(f.root).first { $0.name == "top.md" }!
        try! await f.model.editor.openFileInTabOrFocus(top.path)
        XCTAssertEqual(f.model.moveEntry(top, into: f.p("dir")), .moved(f.p("dir/top.md")))
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("dir/top.md"), "open tab follows the move")
        XCTAssertEqual(f.model.moveEntry(f.model.entries(f.p("dir")).first { $0.name == "top.md" }!, into: f.p("dir")), .skipped)
        // folder rename rewrites open tab paths
        let dir = f.model.entries(f.root).first { $0.name == "dir" }!
        f.model.submitRename(dir, "dir2")
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("dir2/top.md"))
        XCTAssertTrue(f.model.isExpanded(f.p("dir2")))
        // delete (to Trash) removes tab references
        let moved = f.model.entries(f.p("dir2")).first { $0.name == "top.md" }!
        f.model.deleteEntry(moved)
        XCTAssertFalse(TFS.exists(f.p("dir2/top.md")), "\(f.alerts)")
        XCTAssertEqual(f.model.editor.tabs.map { $0.location }, [.launcher])
    }

    func testDeleteDirtyFileAsksForConfirmation() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open(file: "a.md")
        // a failing write keeps the buffer dirty
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root)
        defer { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root) }
        f.model.editor.updateContent(f.p("a.md"), "dirty")
        XCTAssertNotNil(f.model.editor.file(f.p("a.md"))?.saveError)
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.isDirty, true)
        var asked: String?
        f.model.confirm = { asked = $0; return false }
        f.model.deleteEntry(f.model.entries(f.root)[0])
        XCTAssertEqual(asked, "\"a.md\" has unsaved changes. Delete anyway?")
        XCTAssertTrue(TFS.exists(f.p("a.md")))
    }

    func testDuplicate() async {
        let f = ShellFixture(files: ["n.md": "# N\n"])
        await f.open()
        await f.model.duplicate(f.p("n.md"))
        XCTAssertEqual(TFS.read(f.p("n copy.md")), "# N\n")
        await f.model.duplicate(f.p("n.md"))
        XCTAssertTrue(TFS.exists(f.p("n copy 2.md")))
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("n copy 2.md"))
    }

    func testSelectionShiftAndCommandClick() async {
        let f = ShellFixture(files: ["a.md": "", "b.md": "", "c.md": "", "d.md": ""])
        await f.open()
        let e = f.model.flatTree().map { $0.entry }
        f.model.pressRow(e[0], modifier: .none)
        f.model.pressRow(e[2], modifier: .shift)
        XCTAssertEqual(f.model.selectedPaths, Set(e[0...2].map { $0.path }))
        f.model.pressRow(e[1], modifier: .command)
        XCTAssertEqual(f.model.selectedPaths, [e[0].path, e[2].path])
        // pressing a selected row with ≥2 selected drags the whole selection
        XCTAssertEqual(f.model.pressRow(e[2], modifier: .none).map { $0.path }, [e[0].path, e[2].path])
        // pressing an unselected row discards the selection
        XCTAssertEqual(f.model.pressRow(e[3], modifier: .none).map { $0.path }, [e[3].path])
        XCTAssertTrue(f.model.selectedPaths.isEmpty)
    }

    func testTreeMoveRules() {
        let dir = DirEntry(name: "d", path: "/r/d", isDir: true, isMarkdown: false, modifiedAt: 0, title: nil)
        let file = DirEntry(name: "f.md", path: "/r/d/f.md", isDir: false, isMarkdown: true, modifiedAt: 0, title: nil)
        XCTAssertEqual(TreeMove.resolveDropDir(nil, root: "/r"), "/r")
        XCTAssertEqual(TreeMove.resolveDropDir(dir, root: "/r"), "/r/d")
        XCTAssertEqual(TreeMove.resolveDropDir(file, root: "/r"), "/r/d")
        XCTAssertFalse(TreeMove.canMoveInto("/r/d/f.md", isDir: false, destDir: "/r/d"))
        XCTAssertFalse(TreeMove.canMoveInto("/r/d", isDir: true, destDir: "/r/d/sub"))
        XCTAssertTrue(TreeMove.canMoveInto("/r/d/f.md", isDir: false, destDir: "/r"))
        let rows = [("/r/a", 0), ("/r/d", 0), ("/r/d/x", 1), ("/r/d/y", 1), ("/r/z", 0)].map { (path: $0.0, depth: $0.1) }
        XCTAssertEqual(TreeMove.resolveDropRange(rows, destDir: "/r/d", root: "/r").map { [$0.0, $0.1] }, ["/r/d", "/r/d/y"])
        XCTAssertEqual(TreeMove.resolveDropRange(rows, destDir: "/r", root: "/r").map { [$0.0, $0.1] }, ["/r/a", "/r/z"])
    }

    func testContextMenuItemOrder() async {
        let f = ShellFixture(files: ["d/x.md": ""])
        await f.open()
        func titles(_ m: NSMenu) -> [String] { m.items.map { $0.isSeparatorItem ? "-" : $0.title } }
        let d = f.model.entries(f.root)[0]
        XCTAssertEqual(titles(ShellMenus.folderMenu(model: f.model, entry: d)),
                       ["New File", "New Folder", "-", "Copy relative path", "Copy absolute path", "-", "Reveal in Finder", "-", "Rename...", "Delete"])
        let x = f.model.entries(f.p("d"))[0]
        XCTAssertEqual(titles(ShellMenus.fileMenu(model: f.model, entry: x, inlineRename: true)),
                       ["Open", "Open in new tab", "Pin", "-", "Duplicate", "-", "Copy relative path", "Copy absolute path", "-", "Reveal in Finder", "-", "Rename...", "Delete"])
        f.model.togglePinned(x.path)
        XCTAssertEqual(ShellMenus.fileMenu(model: f.model, entry: x, inlineRename: true).items[2].title, "Unpin")
        XCTAssertEqual(titles(ShellMenus.bulkMenu(model: f.model, paths: ["/a", "/b"])), ["Copy 2 relative paths", "Copy 2 absolute paths", "-", "Delete 2 items"])
        let surface = ShellMenus.sidebarSurfaceMenu(model: f.model)
        XCTAssertEqual(surface.items.map { "\($0.title):\($0.state == .on)" }, ["Search:false", "Recents:true"])
        (surface.items[0] as! ClosureMenuItem).fire()
        XCTAssertTrue(f.model.values.appearanceSidebarShowSearch)
        (ShellMenus.fileMenu(model: f.model, entry: x, inlineRename: true).items[6] as! ClosureMenuItem).fire()
        XCTAssertEqual(f.pasteboard, "d/x.md")
        let ws = ShellMenus.workspaceMenu(model: f.model)
        XCTAssertEqual(titles(ws).suffix(2), ["Open Folder…", "Close Workspace"])
    }
}

@MainActor
final class ShellLinkTests: XCTestCase {
    func testMarkdownAndWikiLinkResolution() async {
        let f = ShellFixture(files: ["a.md": "", "notes/b.md": "", "notes/index.md": "", "Unique Name.md": "", "x/dup.md": "", "y/dup.md": ""])
        await f.open()
        let a = f.p("a.md")
        XCTAssertEqual(f.model.linkAction(href: "notes/b.md#part", from: a), .navigate(f.p("notes/b.md"), anchor: "part"))
        XCTAssertEqual(f.model.linkAction(href: "notes", from: a), .navigate(f.p("notes/index.md"), anchor: nil), "extensionless probes /index.md")
        XCTAssertEqual(f.model.linkAction(href: "#intro", from: a), .scrollToAnchor("intro"))
        XCTAssertEqual(f.model.linkAction(href: "https://x.com", from: a), .openURL("https://x.com"))
        XCTAssertEqual(f.model.linkAction(href: "img.png", from: a), .openPath(f.p("img.png")))
        XCTAssertEqual(f.model.wikiLinkAction("unique name", from: a), .navigate(f.p("Unique Name.md"), anchor: nil))
        XCTAssertEqual(f.model.wikiLinkAction("dup", from: a), .none, "ambiguous stems don't resolve")
        XCTAssertEqual(f.model.wikiLinkAction("x/dup", from: a), .navigate(f.p("x/dup.md"), anchor: nil))
        var opened: URL?
        f.model.openExternal = { opened = $0 }
        f.model.perform(link: .openURL("https://x.com"))
        XCTAssertEqual(opened?.absoluteString, "https://x.com")
        f.model.perform(link: .scrollToAnchor("nope"))
        XCTAssertEqual(f.model.anchorWarning, "Heading \"#nope\" not found in this document")
        try! await f.model.editor.openFileInTabOrFocus(a)
        f.model.perform(link: .navigate(f.p("notes/b.md"), anchor: nil))
        await f.settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("notes/b.md"))
        XCTAssertEqual(f.model.editor.tabs.count, 1, "in-place navigation")
        XCTAssertTrue(f.model.editor.canNavigateBack)
    }
}

@MainActor
final class ShellPaletteTests: XCTestCase {
    func testCommandListAndFiltering() async {
        let f = ShellFixture(files: ["Master Journal.md": "", "notes/master-plan.md": "", "other.md": ""])
        await f.open()
        XCTAssertEqual(f.model.paletteCommands().map { $0.title },
                       ["Toggle Sidebar", "Create New File", "Close Current Tab", "Close All Tabs", "Open Workspace",
                        "Close Workspace", "Toggle Dark Mode", "Settings"])
        try! await f.model.editor.openFileInTabOrFocus(f.p("other.md"))
        XCTAssertTrue(f.model.paletteCommands().map { $0.title }.contains("Open File in Compact Window"))
        XCTAssertEqual(f.model.paletteCommands().last?.subtitle, "App preferences")
        f.model.perform(.openFileSearch)
        var v = f.model.paletteView()!
        XCTAssertEqual(v.heading, "Suggested")
        XCTAssertEqual(v.placeholder, "Search...")
        f.model.setPaletteQuery("tab")
        v = f.model.paletteView()!
        XCTAssertEqual(v.items.map { $0.title }, ["Close Current Tab", "Close All Tabs"])
        XCTAssertEqual(v.heading, "Results")
        f.model.setPaletteQuery("master")
        v = f.model.paletteView()!
        // filename matches first; highlights on the relative path
        XCTAssertEqual(v.items.map { $0.title }, ["Master Journal.md", "master-plan.md"])
        XCTAssertEqual(v.items[0].highlights, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(v.items[1].subtitle, "notes/master-plan.md")
        f.model.setPaletteQuery("master plan")
        XCTAssertEqual(f.model.paletteView()!.items.map { $0.title }, ["master-plan.md"], "spaces also match hyphens")
        f.model.setPaletteQuery("zzz")
        XCTAssertEqual(f.model.paletteView()!.empty, "No results found.")
    }

    func testSelectionAndRunFile() async {
        let f = ShellFixture(files: ["alpha.md": "", "alps.md": ""])
        await f.open()
        f.model.perform(.search)
        f.model.setPaletteQuery("alp")
        f.model.movePaletteSelection(1)
        f.model.movePaletteSelection(5)
        XCTAssertEqual(f.model.palette?.selected, 1)
        let target = f.model.paletteView()!.items[1]
        f.model.runSelectedPaletteItem()
        XCTAssertNil(f.model.palette)
        await f.settle()
        if case let .file(p) = target.kind { XCTAssertEqual(f.model.editor.activeFilePath, p) } else { XCTFail() }
    }

    func testCreateMode() async {
        let f = ShellFixture(files: ["a.md": ""])
        await f.open()
        f.model.perform(.newNote)
        var v = f.model.paletteView()!
        XCTAssertEqual(v.placeholder, "Create a new note...")
        XCTAssertEqual(v.empty, "Type a note name to create it.")
        f.model.setPaletteQuery("  My note ")
        v = f.model.paletteView()!
        XCTAssertEqual(v.heading, "Create note")
        XCTAssertEqual(v.items.map { $0.title }, ["Create: My note.md"])
        f.model.runSelectedPaletteItem()
        await f.settle()
        XCTAssertEqual(TFS.read(f.p("My note.md")), "# ")
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("My note.md"))
        XCTAssertTrue(f.model.flatTree().contains { $0.entry.name == "My note.md" })
    }

    func testPaletteCommandsRun() async {
        let f = ShellFixture(files: ["a.md": ""])
        await f.open()
        f.model.perform(.search)
        f.model.runPaletteItem(PaletteItem(kind: .command("toggle-theme"), title: ""))
        XCTAssertEqual(f.model.values.appearanceTheme, .light)
        f.model.perform(.toggleTheme)
        XCTAssertEqual(f.model.values.appearanceTheme, .dark)
        XCTAssertEqual(f.model.mode, .dark)
        f.model.perform(.toggleTheme)
        XCTAssertEqual(f.model.values.appearanceTheme, .system)
        f.model.perform(.search)
        f.model.runPaletteItem(PaletteItem(kind: .command("new-file"), title: ""))
        XCTAssertEqual(f.model.palette?.intent, .createFile)
        var opened = false
        f.model.openSettingsWindow = { opened = true }
        f.model.runPaletteItem(PaletteItem(kind: .command("open-settings"), title: ""))
        XCTAssertTrue(opened)
        XCTAssertNil(f.model.palette)
        f.model.runPaletteItem(PaletteItem(kind: .command("toggle-sidebar"), title: ""))
        XCTAssertFalse(f.model.sidebarPreferenceVisible)
    }

    func testPaletteGeometry() {
        XCTAssertEqual(PaletteGeometry.dialogRect(window: CGSize(width: 1400, height: 900)), CGRect(x: 420, y: 144, width: 560, height: 0))
        XCTAssertEqual(PaletteGeometry.dialogRect(window: CGSize(width: 500, height: 600)).width, 450)
        let v = ShellModel.PaletteView(heading: "Suggested", empty: nil,
                                       items: [PaletteItem(kind: .command("a"), title: "A", subtitle: "Command"),
                                               PaletteItem(kind: .create("/x"), title: "Create: x.md")], placeholder: "")
        let l = PaletteGeometry.layout(v)
        XCTAssertEqual(l.heading, 6)
        XCTAssertEqual(l.items, [34.5, 93.5])
        XCTAssertEqual(l.content, 139)
    }
}

@MainActor
final class ShellMenuAndKeyTests: XCTestCase {
    func testMenuStructure() {
        let router = MenuRouter()
        let menu = MainMenu.build(target: router)
        XCTAssertEqual(menu.items.map { $0.title }, ["Flo State", "File", "Edit", "View", "Window"])
        func items(_ i: Int) -> [String] { menu.items[i].submenu!.items.map { $0.isSeparatorItem ? "-" : $0.title } }
        XCTAssertEqual(items(1), ["New Note", "New Tab", "Go to File…", "-", "Go to Today", "Search…", "-", "Close Tab"])
        XCTAssertEqual(items(3), ["Toggle Sidebar", "Toggle Sidebar", "Toggle Typewriter Scrolling", "-", "Increase Font Size", "Decrease Font Size",
                                  "Reset Font Size", "-", "Collapse All Headings", "Expand All Headings", "-", "Back", "Forward",
                                  "-", "Previous File", "Next File"])
        XCTAssertTrue(menu.items[3].submenu!.items[1].isHidden, "Cmd-. is a hidden alternate")
        XCTAssertEqual(items(2), ["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Select All", "-", "Substitutions"])
        XCTAssertEqual(items(4), ["Minimize", "Enter Full Screen", "-", "Show Previous Tab", "Show Next Tab", "Show Previous Tab",
                                  "Show Next Tab", "Go to Tab", "-", "Close Window"])
        XCTAssertEqual(menu.items[4].submenu!.items.first { $0.title == "Go to Tab" }!.submenu!.items.map { $0.keyEquivalent }, (1...9).map { "\($0)" })
        XCTAssertTrue(items(0).contains("Settings…"), "macOS 13+ naming")
        XCTAssertFalse(items(0).contains("Preferences…"))
        let keys = menu.items[1].submenu!.items.filter { !$0.isSeparatorItem }.map { "\($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")\($0.keyEquivalent)" }
        XCTAssertEqual(keys, ["n", "t", "o", "⇧d", "k", "w"])
        let back = menu.items[3].submenu!.items.first { $0.title == "Back" }!
        XCTAssertEqual(back.keyEquivalent, "", "Alt-←/→ stay with the editor")
    }

    func testMenuRoutesToFocusedModel() async {
        let f = ShellFixture(files: ["a.md": ""])
        await f.open()
        let router = MenuRouter()
        router.focusedModel = { f.model }
        let menu = MainMenu.build(target: router)
        let view = menu.items[3].submenu!
        router.menuAction(view.items.first { $0.title == "Toggle Typewriter Scrolling" }!)
        XCTAssertFalse(f.model.typewriterScrolling)
        router.menuAction(view.items.first { $0.title == "Increase Font Size" }!)
        XCTAssertEqual(f.model.values.editorFontSize, 17)
        router.menuAction(view.items.first { $0.title == "Reset Font Size" }!)
        XCTAssertEqual(f.model.values.editorFontSize, 16)
        router.menuAction(menu.items[1].submenu!.items.first { $0.title == "New Note" }!)
        XCTAssertEqual(f.model.palette?.intent, .createFile)
        router.menuAction(menu.items[1].submenu!.items.first { $0.title == "Search…" }!)
        XCTAssertEqual(f.model.palette?.intent, .search)
        let prefs = menu.items[0].submenu!.items.first { $0.title == "Settings…" }!
        XCTAssertEqual(prefs.keyEquivalent, ",")
        var appLevel = 0
        router.appAction = { a in if a == .openPreferences { appLevel += 1; return true }; return false }
        router.menuAction(prefs)
        XCTAssertEqual(appLevel, 1, "Settings… is handled by the app, even with no window")
        XCTAssertEqual(router.log, [.toggleTypewriter, .fontSizeIncrease, .fontSizeReset, .newNote, .search, .openPreferences])
        var editorCmds: [ShellModel.EditorCommandRequest] = []
        f.model.editorCommand = { editorCmds.append($0) }
        router.menuAction(menu.items[1].submenu!.items.first { $0.title == "Go to Today" }!)
        router.menuAction(view.items.first { $0.title == "Collapse All Headings" }!)
        XCTAssertEqual(editorCmds, [.goToToday, .collapseAll])
    }

    func testMenuAcceleratorsWinOverEditor() {
        func w(_ c: UInt16, shift: Bool = false, opt: Bool = false) -> Bool {
            MainMenu.menuWins(keyCode: c, command: true, shift: shift, option: opt, control: false)
        }
        XCTAssertTrue(w(40), "Cmd-K is Search…, never Insert link")
        XCTAssertTrue(w(45)); XCTAssertTrue(w(17)); XCTAssertTrue(w(13)); XCTAssertTrue(w(42)); XCTAssertTrue(w(43))
        XCTAssertTrue(w(2, shift: true)); XCTAssertTrue(w(8, opt: true))
        XCTAssertTrue(w(24)); XCTAssertTrue(w(27)); XCTAssertTrue(w(29))
        XCTAssertTrue(w(123, opt: true)); XCTAssertTrue(w(124, opt: true))
        XCTAssertFalse(w(11), "Cmd-B stays with the editor")
        XCTAssertFalse(w(8), "Cmd-C is copy")
        XCTAssertFalse(w(123), "Cmd-← is the editor's")
        XCTAssertFalse(MainMenu.menuWins(keyCode: 40, command: false, shift: false, option: false, control: true))
    }

    func testFontSizeClamps() async {
        let f = ShellFixture(config: "editor.font-size = 32\n")
        f.model.perform(.fontSizeIncrease)
        XCTAssertEqual(f.model.values.editorFontSize, 32)
        f.model.setSetting("editor.font-size", .number(10))
        f.model.perform(.fontSizeDecrease)
        XCTAssertEqual(f.model.values.editorFontSize, 10)
    }

    func testKeyShortcuts() {
        func k(_ code: UInt16, cmd: Bool = false, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) -> ShellKeys.Key {
            ShellKeys.Key(keyCode: code, chars: "", command: cmd, shift: shift, option: opt, control: ctrl)
        }
        XCTAssertEqual(ShellKeys.action(k(33, cmd: true, shift: true), editorFocused: true, compact: false), .previousTab)
        XCTAssertEqual(ShellKeys.action(k(30, cmd: true, shift: true), editorFocused: true, compact: false), .nextTab)
        XCTAssertEqual(ShellKeys.action(k(48, ctrl: true), editorFocused: true, compact: false), .nextTab)
        XCTAssertEqual(ShellKeys.action(k(48, shift: true, ctrl: true), editorFocused: true, compact: false), .previousTab)
        XCTAssertEqual(ShellKeys.action(k(18, cmd: true), editorFocused: true, compact: false), .selectTab(1))
        XCTAssertEqual(ShellKeys.action(k(25, cmd: true), editorFocused: true, compact: false), .selectTab(9))
        XCTAssertEqual(ShellKeys.action(k(126, cmd: true, opt: true), editorFocused: true, compact: false), .stepFile(-1))
        XCTAssertEqual(ShellKeys.action(k(125, cmd: true, opt: true), editorFocused: true, compact: false), .stepFile(1))
        XCTAssertEqual(ShellKeys.action(k(31, cmd: true), editorFocused: true, compact: false), .openFileSearch)
        XCTAssertEqual(ShellKeys.action(k(47, cmd: true), editorFocused: true, compact: false), .toggleSidebar)
        // Alt-←/→ only outside editable targets
        XCTAssertNil(ShellKeys.action(k(123, opt: true), editorFocused: true, compact: false))
        XCTAssertEqual(ShellKeys.action(k(123, opt: true), editorFocused: false, compact: false), .back)
        XCTAssertEqual(ShellKeys.action(k(124, opt: true), editorFocused: false, compact: false), .forward)
        XCTAssertNil(ShellKeys.action(k(123, shift: true, opt: true), editorFocused: false, compact: false))
        // compact windows: no tab shortcuts
        XCTAssertNil(ShellKeys.action(k(18, cmd: true), editorFocused: true, compact: true))
        XCTAssertNil(ShellKeys.action(k(0, cmd: true), editorFocused: true, compact: false), "Cmd-A is the editor's")
    }
}

@MainActor
final class ShellGeometryTests: XCTestCase {
    func testTabGeometry() {
        XCTAssertEqual(TabGeometry.width(titleWidth: 69.38, hasError: false), 97.38, accuracy: 0.001)
        XCTAssertEqual(TabGeometry.width(titleWidth: 400, hasError: false), 180)
        XCTAssertEqual(TabGeometry.width(titleWidth: 50, hasError: true), 90)
        let l = TabGeometry.layout(widths: [97.38, 83.82, 132.59])
        XCTAssertEqual(l.tabs[1], 101.38, accuracy: 0.001)
        XCTAssertEqual(l.plus, 97.38 + 83.82 + 132.59 + 12, accuracy: 0.001)
    }

    func testTabTitleWidthMatchesChrome() {
        // Chrome measures "Top Priority" at 13px SF as 69.38px (tab 97.38 − 28)
        let w = TextStyle(font: NSFont.systemFont(ofSize: 13), color: .black).width("Top Priority")
        XCTAssertEqual(w, 69.38, accuracy: 0.05)
    }

    func testRailTicks() {
        let t = RailGeometry.ticks(count: 3, active: 1, areaWidth: 1087, areaHeight: 900)
        // stack = 3 + 2·6 = 15, centred on 450
        XCTAssertEqual(t[0], CGRect(x: 1045, y: 442.5, width: 10, height: 1))
        XCTAssertEqual(t[1], CGRect(x: 1035, y: 449.5, width: 20, height: 1))
        XCTAssertEqual(t[2].minY, 456.5)
    }

    func testFooterMetrics() {
        let s = DocumentStats(words: 19317, characters: 106526, paragraphs: 235)
        var v = SettingsValues([:])
        XCTAssertTrue(FooterMetrics.visible(s, v).isEmpty)
        v = SettingsValues(["statusbar.show-words": .bool(true), "statusbar.show-paragraphs": .bool(true)])
        XCTAssertEqual(FooterMetrics.visible(s, v).map { $0.label }, ["words", "paragraphs"])
        XCTAssertEqual(FooterMetrics.format(19317), "19,317")
        XCTAssertEqual(FooterMetrics.format(5), "5")
    }

    func testFontStackHelpers() {
        XCTAssertEqual(FontStackEdit.firstFamily("\"Proxima Nova\", -apple-system, sans-serif"), "Proxima Nova")
        XCTAssertEqual(FontStackEdit.stackWithFamily("Menlo", "\"SF Pro\", Menlo, ui-sans-serif"), "Menlo, ui-sans-serif")
        XCTAssertEqual(FontStackEdit.stackWithFamily("Proxima Nova", "\"SF Pro\", ui-sans-serif"), "\"Proxima Nova\", ui-sans-serif")
        XCTAssertEqual(FontStack.families("\"SF Pro\", -apple-system-body, 'A B', x"), ["SF Pro", "-apple-system-body", "A B", "x"])
        XCTAssertEqual(FontStack.font("\"No Such Font\", ui-sans-serif", size: 13).fontName, NSFont.systemFont(ofSize: 13).fontName)
    }

    func testSettingsPanesCoverEverySettingOnce() {
        XCTAssertEqual(SettingsPanes.all.map { $0.title }, ["General", "Editor", "Appearance", "Theme", "Files"])
        let keys = SettingsPanes.allKeys
        XCTAssertEqual(keys.count, Set(keys).count, "no duplicates")
        XCTAssertTrue(Set(keys).isDisjoint(with: SettingsPanes.hiddenKeys))
        XCTAssertEqual(Set(keys).union(SettingsPanes.hiddenKeys), Set(SettingsSchema.all.map { $0.key }),
                       "every schema key is either shown or explicitly hidden")
        XCTAssertEqual(SettingControl.sentenceCase("Font Size"), "Font size")
        XCTAssertEqual(SettingControl.sentenceCase("UI font"), "UI font")
        XCTAssertEqual(SettingsPanes.optionTitle("appearance.theme", "system"), "Match System")
        XCTAssertEqual(SettingsPanes.optionTitle("appearance.editor-width", "full"), "Wide")
        XCTAssertEqual(SettingsPanes.presetTitle("Writer"), "Flo State")
        XCTAssertEqual(SettingsPanes.presetName("Flo State"), "Writer")
    }


    func testTextWrapAndSVG() {
        let lines = TextWrap.lines("Font family and fallback stack used throughout the app", font: .systemFont(ofSize: 13), width: 250)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined(separator: " "), "Font family and fallback stack used throughout the app")
        let p = SVGPath.parse("M4.5 3.5L7.5 6L4.5 8.5")
        XCTAssertEqual(p.boundingBox, CGRect(x: 4.5, y: 3.5, width: 3, height: 5))
        let rel = SVGPath.parse("M1 1h2v2H1z")
        XCTAssertEqual(rel.boundingBox, CGRect(x: 1, y: 1, width: 2, height: 2))
    }

    func testDailyAndJumpToBottomPolicy() {
        XCTAssertTrue(DailyNote.shouldJumpToBottom(awayMs: 10 * 60_000, minutes: 10))
        XCTAssertFalse(DailyNote.shouldJumpToBottom(awayMs: 9 * 60_000, minutes: 10))
        XCTAssertFalse(DailyNote.shouldJumpToBottom(awayMs: 1e12, minutes: 0))
        let dir = TFS.tempDir("ui")
        let s = UIStateStore(url: URL(fileURLWithPath: dir + "/ui_state.json"))
        XCTAssertEqual(s.lastActivatedAt(), 0)
        s.markActivated(1234)
        XCTAssertEqual(s.lastActivatedAt(), 1234)
    }

    func testLaunchPathParsing() {
        XCTAssertEqual(FloApp.launchPaths(["bin", "-NSDocumentRevisionsDebugMode", "YES", "/a/b.md", "--flag"]), ["/a/b.md"])
    }
}


final class FloStateCLITests: XCTestCase {
    func testParse() {
        XCTAssertEqual(try FloStateCLI.parse(["flostate"]).get(), .open(nil))
        XCTAssertEqual(try FloStateCLI.parse(["flostate", "-h"]).get(), .help)
        XCTAssertEqual(try FloStateCLI.parse(["flostate", "--version"]).get(), .version)
        XCTAssertEqual(try FloStateCLI.parse(["flostate", "notes"]).get(), .open("notes"))
        if case .failure(let e) = FloStateCLI.parse(["flostate", "a", "b"]) { XCTAssertEqual(e, .tooManyArgs) } else { XCTFail() }
        if case .failure(let e) = FloStateCLI.parse(["flostate", "--nope"]) { XCTAssertEqual(e, .unknownFlag("--nope")) } else { XCTFail() }
        XCTAssertTrue(FloStateCLI.isCLIInvocation("/usr/local/bin/flostate"))
        XCTAssertFalse(FloStateCLI.isCLIInvocation("/Applications/Flo State.app/Contents/MacOS/FloStateNative"))
        XCTAssertEqual(FloStateCLI.bundlePath(forBinary: "/Applications/Flo State.app/Contents/MacOS/FloStateNative"), "/Applications/Flo State.app")
    }

    func testRunOpensTargetsInTheApp() {
        let dir = TFS.tempDir("cli")
        TFS.write(dir + "/n.md", "x")
        TFS.write(dir + "/img.png", "x")
        var launched: [[String]] = []
        let env = ["FLOSTATE_APP_PATH": "/Apps/Flo State.app"]
        func run(_ a: [String]) -> Int32 {
            FloStateCLI.run(a, cwd: dir, out: { _ in }, err: { _ in }, env: env, launch: { launched.append($0); return true })
        }
        XCTAssertEqual(run(["flostate", "."]), 0)
        XCTAssertEqual(launched.last, ["-a", "/Apps/Flo State.app", dir])
        XCTAssertEqual(run(["flostate", "n.md"]), 0)
        XCTAssertEqual(launched.last, ["-a", "/Apps/Flo State.app", dir + "/n.md"])
        XCTAssertEqual(run(["flostate"]), 0)
        XCTAssertEqual(launched.last, ["-a", "/Apps/Flo State.app"])
        XCTAssertEqual(run(["flostate", "missing.md"]), 3)
        XCTAssertEqual(run(["flostate", "img.png"]), 3, "not a folder or markdown file")
        XCTAssertEqual(run(["flostate", "-x"]), 2)
        XCTAssertEqual(launched.count, 3)
        XCTAssertEqual(FloStateCLI.run(["flostate", "."], cwd: dir, out: { _ in }, err: { _ in }, env: env, launch: { _ in false }), 3)
    }

    func testInstallUninstallInTempDir() throws {
        let dir = TFS.tempDir("clibin")
        let src = dir + "/app/FloStateNative"
        TFS.write(src, "bin")
        let target = dir + "/bin/flostate"
        XCTAssertEqual(FloStateCLI.state(target: target, source: src), .missing)
        try FloStateCLI.install(source: src, target: target, elevate: { _ in XCTFail("no elevation needed"); return false })
        XCTAssertEqual(FloStateCLI.state(target: target, source: src), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target), src)
        XCTAssertEqual(FloStateCLI.state(target: target, source: dir + "/other"), .stale)
        try FloStateCLI.install(source: src, target: target)   // idempotent over our own link
        try FloStateCLI.uninstall(source: src, target: target)
        XCTAssertEqual(FloStateCLI.state(target: target, source: src), .missing)
        TFS.write(target, "someone else's")
        XCTAssertEqual(FloStateCLI.state(target: target, source: src), .foreign)
        XCTAssertThrowsError(try FloStateCLI.install(source: src, target: target))
        XCTAssertThrowsError(try FloStateCLI.uninstall(source: src, target: target))
        XCTAssertEqual(TFS.read(target), "someone else's", "never clobbers a foreign file")
    }

    @MainActor
    func testMenuHasCLIItemAndUpdateItemOnlyWithAFeed() {
        let menu = MainMenu.build(target: MenuRouter())
        let titles = menu.items[0].submenu!.items.map { $0.title }
        XCTAssertTrue(titles.contains(FloStateCLI.installLabel) || titles.contains(FloStateCLI.uninstallLabel))
        XCTAssertFalse(titles.contains("Check for Updates…"), "no update feed: no dead item")
        let i = titles.firstIndex(of: "Settings…")!
        XCTAssertTrue(titles[i + 1].contains("'flostate' Command Line Tool"), "right after Settings… like legacy")
        // with an updater (bundled app): right after About, like legacy
        let item = NSMenuItem(title: MainMenu.checkForUpdatesTitle, action: nil, keyEquivalent: "")
        let withUpdates = MainMenu.build(target: MenuRouter(), updateItem: item).items[0].submenu!.items.map { $0.title }
        XCTAssertEqual(withUpdates[1], "Check for Updates…")
        XCTAssertTrue(withUpdates[0].hasPrefix("About "))
    }

    func testUpdaterFeedOverrideAndConfiguration() {
        let d = UserDefaults(suiteName: "flostate.test.\(UUID())")!
        XCTAssertNil(AppUpdater.feedOverride(env: [:], defaults: d))
        d.set("http://localhost:1/b.xml", forKey: AppUpdater.feedOverrideDefault)
        XCTAssertEqual(AppUpdater.feedOverride(env: [:], defaults: d), "http://localhost:1/b.xml")
        XCTAssertEqual(AppUpdater.feedOverride(env: [AppUpdater.feedOverrideEnv: "http://localhost:2/a.xml"], defaults: d), "http://localhost:2/a.xml")
        XCTAssertFalse(AppUpdater.isConfigured(.main), "test runner is not an updatable app")
    }
}

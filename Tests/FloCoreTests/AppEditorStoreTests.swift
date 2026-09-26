import XCTest
@testable import FloCore

/// In-memory file system for store tests.
@MainActor
final class FakeFiles {
    var contents: [String: String] = [:]
    var reads: [String] = []
    var failing: Set<String> = []
    struct ReadError: Error {}

    func read(_ path: String) async throws -> FileContent {
        reads.append(path)
        if failing.contains(path) { throw ReadError() }
        guard let c = contents[path] else { throw ReadError() }
        return FileContent(path: path, content: c, modifiedAt: 1)
    }
}

/// Holds write completions so tests control when a write finishes.
@MainActor
final class DeferredWriter {
    var payloads: [(path: String, content: String)] = []
    var completions: [(Result<Void, Error>) -> Void] = []
    var autoComplete = false

    func write(_ path: String, _ content: String, _ done: @escaping @MainActor (Result<Void, Error>) -> Void) {
        payloads.append((path, content))
        if autoComplete { done(.success(())) } else { completions.append(done) }
    }

    func resolve(_ i: Int) { completions[i](.success(())) }
    func reject(_ i: Int, _ e: Error) { completions[i](.failure(e)) }
}

@MainActor
final class AppEditorStoreTests: XCTestCase {
    var files: FakeFiles!
    var writer: DeferredWriter!
    var scheduler: ManualScheduler!
    var store: EditorStore!
    var closeRequests = 0
    var processing = SaveProcessing(trimTrailingWhitespace: false, insertFinalNewline: false)

    override func setUp() async throws {
        files = FakeFiles()
        writer = DeferredWriter()
        writer.autoComplete = true
        scheduler = ManualScheduler()
        let engine = SaveEngine(scheduler: scheduler, processing: { [unowned self] in self.processing }, writer: { [unowned self] p, c, d in self.writer.write(p, c, d) })
        store = EditorStore(reader: { [unowned self] p in try await self.files.read(p) }, saveEngine: engine, displayDate: { _ in nil })
        store.openGraceNanoseconds = 5_000_000_000
        closeRequests = 0
        store.onRequestWindowClose = { [unowned self] in self.closeRequests += 1 }
    }

    func tabPaths() -> [String] { store.tabs.compactMap { $0.location.primaryPath } }

    // stores.test.ts — editor-store
    func testOpenFileLoadsAndActivates() async {
        files.contents["/test/file.md"] = "Hello"
        await store.openFile("/test/file.md")
        XCTAssertEqual(store.activeFilePath, "/test/file.md")
        XCTAssertEqual(tabPaths(), ["/test/file.md"])
        XCTAssertEqual(store.file("/test/file.md")?.content, "Hello")
        XCTAssertEqual(store.file("/test/file.md")?.isLoading, false)
    }

    func testOpenFileDerivesFrontmatterTitle() async {
        files.contents["/test/file.md"] = "---\ntitle: Hello\n---\n\n# Hello\n\nBody"
        await store.openFile("/test/file.md")
        let f = store.file("/test/file.md")!
        XCTAssertEqual(f.title, "Hello")
        XCTAssertEqual(f.titleSource, .frontmatter)
        XCTAssertEqual(f.content, "\n# Hello\n\nBody")
        XCTAssertEqual(f.stats.words, 2)
    }

    func testUpdateFrontmatterNil() async {
        files.contents["/test/file.md"] = "---\ntitle: Hello\n---\n\n# From Body\n\nBody"
        await store.openFile("/test/file.md")
        writer.autoComplete = false
        store.updateFrontmatter("/test/file.md", nil)
        let f = store.file("/test/file.md")!
        XCTAssertNil(f.frontmatter)
        XCTAssertTrue(f.isDirty)
        XCTAssertEqual(f.title, "From Body")
        XCTAssertEqual(f.titleSource, .h1)
    }

    func testOpenNewTabAppendsLauncher() {
        store.openNewTab()
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].location, .launcher)
        XCTAssertNil(store.activeFilePath)
    }

    func testOpenFileInTabOrFocusFillsLauncher() async throws {
        files.contents["/test/a.md"] = "# Note"
        store.openNewTab()
        let launcher = store.activeTabId
        try await store.openFileInTabOrFocus("/test/a.md")
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].id, launcher)
        XCTAssertEqual(store.tabs[0].location, .file("/test/a.md"))
    }

    func testOpenFileInTabOrFocusOpensNewTabFromFileTab() async throws {
        files.contents["/test/a.md"] = "# A"
        files.contents["/test/b.md"] = "# B"
        store.openNewTab()
        try await store.openFileInTabOrFocus("/test/a.md")
        try await store.openFileInTabOrFocus("/test/b.md")
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.tabs[1].location, .file("/test/b.md"))
    }

    func testOpenFileInTabOrFocusFocusesExisting() async throws {
        files.contents["/test/a.md"] = "# A"
        store.openNewTab()
        try await store.openFileInTabOrFocus("/test/a.md")
        let first = store.activeTabId
        store.openNewTab()
        try await store.openFileInTabOrFocus("/test/a.md")
        XCTAssertEqual(store.activeTabId, first)
        XCTAssertEqual(store.tabs.filter { $0.location.isFile }.count, 1)
    }

    func testClosingLastTabClosesWindow() async throws {
        files.contents["/test/a.md"] = "# A"
        store.openNewTab()
        try await store.openFileInTabOrFocus("/test/a.md")
        store.closeTab(store.tabs[0].id)
        XCTAssertEqual(closeRequests, 1)
        XCTAssertEqual(store.tabs, [])
        XCTAssertNil(store.activeTabId)
        XCTAssertNil(store.activeFilePath)
        XCTAssertTrue(store.openFiles.isEmpty)
    }

    func testClosingNonLastTabKeepsWindow() async throws {
        files.contents["/test/a.md"] = "# A"
        files.contents["/test/b.md"] = "# B"
        store.openNewTab()
        try await store.openFileInTabOrFocus("/test/a.md")
        try await store.openFileInTabOrFocus("/test/b.md")
        store.closeTab(store.tabs[0].id)
        XCTAssertEqual(closeRequests, 0)
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testCloseActivatesRightNeighbourElseLeft() async throws {
        for p in ["/a.md", "/b.md", "/c.md"] { files.contents[p] = p }
        await store.openFile("/a.md")
        try await store.openFileInNewTab("/b.md")
        try await store.openFileInNewTab("/c.md")
        store.setActiveFile("/b.md")
        store.closeFile("/b.md")
        XCTAssertEqual(store.activeFilePath, "/c.md", "right neighbour")
        store.closeFile("/c.md")
        XCTAssertEqual(store.activeFilePath, "/a.md", "left when there is no right")
        XCTAssertFalse(store.openFiles.keys.contains("/b.md"), "pruned")
    }

    func testClosingInactiveTabKeepsActive() async throws {
        for p in ["/a.md", "/b.md"] { files.contents[p] = p }
        await store.openFile("/a.md")
        try await store.openFileInNewTab("/b.md")
        store.closeTab(store.tabs[0].id)
        XCTAssertEqual(store.activeFilePath, "/b.md")
    }

    func testDirtyFilesAreNotPrunedOnClose() async throws {
        writer.autoComplete = false
        for p in ["/a.md", "/b.md"] { files.contents[p] = p }
        await store.openFile("/a.md")
        try await store.openFileInNewTab("/b.md")
        store.updateContent("/b.md", "edited")
        store.closeFile("/b.md")
        XCTAssertNotNil(store.file("/b.md"))
    }

    func testEnsureLauncherTab() {
        store.ensureLauncherTab()
        XCTAssertEqual(store.tabs.map { $0.location }, [.launcher])
        store.ensureLauncherTab()
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testCloseFileRemovesAndActivatesPrevious() async throws {
        files.contents["/a.md"] = "a"
        files.contents["/b.md"] = "b"
        await store.openFile("/a.md")
        try await store.openFileInNewTab("/b.md")
        store.closeFile("/b.md")
        XCTAssertEqual(tabPaths(), ["/a.md"])
        XCTAssertEqual(store.activeFilePath, "/a.md")
        XCTAssertNil(store.file("/b.md"))
    }

    func testNavigateHistory() async {
        files.contents["/a.md"] = "a"
        files.contents["/b.md"] = "b"
        await store.openFile("/a.md")
        await store.navigateToFile("/b.md")
        XCTAssertEqual(store.tabs[0], Tab(id: store.tabs[0].id, location: .file("/b.md"), back: [.file("/a.md")], forward: []))
        await store.navigateBack()
        XCTAssertEqual(store.tabs[0].location, .file("/a.md"))
        XCTAssertEqual(store.tabs[0].forward, [.file("/b.md")])
        XCTAssertEqual(store.activeFilePath, "/a.md")
        await store.navigateForward()
        XCTAssertEqual(store.tabs[0].location, .file("/b.md"))
        XCTAssertEqual(store.tabs[0].back, [.file("/a.md")])
        XCTAssertEqual(store.tabs[0].forward, [])
        await store.navigateToFile("/b.md")
        XCTAssertEqual(store.tabs[0].back, [.file("/a.md")], "same file is a no-op")
    }

    func testOpenFileNavigatesInPlaceInActiveFileTab() async {
        files.contents["/a.md"] = "a"
        files.contents["/b.md"] = "b"
        await store.openFile("/a.md")
        await store.openFile("/b.md")
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].back, [.file("/a.md")])
        XCTAssertNotNil(store.file("/a.md"), "history keeps the file referenced")
    }

    func testNavigationFailureReverts() async {
        files.contents["/a.md"] = "a"
        await store.openFile("/a.md")
        await store.navigateToFile("/missing.md")
        XCTAssertEqual(store.tabs[0].location, .file("/a.md"))
        XCTAssertEqual(store.tabs[0].back, [])
        XCTAssertEqual(store.activeFilePath, "/a.md")
        XCTAssertNil(store.file("/missing.md"))
    }

    func testLauncherReuseAndDuplicateFileTab() async {
        files.contents["/a.md"] = "a"
        store.openNewTab()
        let launcherId = store.activeTabId
        await store.openFile("/a.md")
        XCTAssertEqual(store.tabs[0].id, launcherId)
        XCTAssertEqual(store.activeTabId, launcherId)
        store.openNewTab()
        await store.openFile("/a.md")
        XCTAssertEqual(tabPaths(), ["/a.md", "/a.md"])
    }

    func testLauncherFailureRestoresLauncher() async {
        store.openNewTab()
        let id = store.activeTabId!
        await store.openFile("/missing.md")
        XCTAssertEqual(store.tabs, [Tab(id: id, location: .launcher)])
        XCTAssertNil(store.activeFilePath)
    }

    func testBackForwardNoOpOnLauncher() async {
        store.openNewTab()
        await store.navigateBack()
        await store.navigateForward()
        XCTAssertEqual(store.tabs.map { $0.location }, [.launcher])
        XCTAssertNil(store.activeFilePath)
    }

    func testSetActiveFileAndCycling() async throws {
        for p in ["/a.md", "/b.md", "/c.md"] { files.contents[p] = p }
        await store.openFile("/a.md")
        try await store.openFileInNewTab("/b.md")
        try await store.openFileInNewTab("/c.md")
        store.setActiveFile("/a.md")
        XCTAssertEqual(store.activeFilePath, "/a.md")
        store.cycleTab(by: -1)
        XCTAssertEqual(store.activeFilePath, "/c.md", "wraps around")
        store.cycleTab(by: 1)
        XCTAssertEqual(store.activeFilePath, "/a.md")
        store.activateTab(number: 2)
        XCTAssertEqual(store.activeFilePath, "/b.md")
        store.activateTab(number: 9)
        XCTAssertEqual(store.activeFilePath, "/b.md")
    }

    func testUpdateContentAndMarkSaved() async {
        writer.autoComplete = false
        files.contents["/test.md"] = "original"
        await store.openFile("/test.md")
        store.updateContent("/test.md", "modified")
        XCTAssertTrue(store.file("/test.md")!.isDirty)
        XCTAssertEqual(store.file("/test.md")!.content, "modified")
        store.markSaved("/test.md", diskContent: "modified")
        XCTAssertFalse(store.file("/test.md")!.isDirty)
        XCTAssertEqual(store.file("/test.md")!.diskContent, "modified")
    }

    func testSessionSnapshotOmitsLaunchers() async {
        files.contents["/a.md"] = "a"
        await store.openFile("/a.md")
        store.openNewTab()
        let snap = store.sessionSnapshot()
        XCTAssertEqual(snap.tabs, [SessionTab(location: SerializedLocation(kind: "file", payload: [("path", .string("/a.md"))]))])
        XCTAssertNil(snap.activeIndex)
    }

    func testOpenFileInNewTabDuplicatesAndFails() async throws {
        files.contents["/a.md"] = "a"
        await store.openFile("/a.md")
        try await store.openFileInNewTab("/a.md")
        XCTAssertEqual(tabPaths(), ["/a.md", "/a.md"])
        XCTAssertEqual(store.activeTabId, store.tabs.last?.id)
        do {
            try await store.openFileInNewTab("/missing.md")
            XCTFail("should throw")
        } catch {}
        XCTAssertEqual(tabPaths(), ["/a.md", "/a.md"])
    }

    func testOpenFileWithNoTabsFailing() async {
        await store.openFile("/missing.md")
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(closeRequests, 0)
    }

    func testOpenCompactFileReplacesTabs() async throws {
        for p in ["/a.md", "/b.md", "/c.md"] { files.contents[p] = p }
        await store.openFile("/a.md")
        try await store.openFileInNewTab("/b.md")
        await store.openCompactFile("/c.md")
        XCTAssertEqual(tabPaths(), ["/c.md"])
        XCTAssertEqual(store.activeFilePath, "/c.md")
        XCTAssertEqual(Set(store.openFiles.keys), ["/c.md"])
    }

    func testOpenCompactFileUsesPrefetch() async {
        await store.openCompactFile("/p.md", prefetched: FileContent(path: "/p.md", content: "# Pre"))
        XCTAssertEqual(store.file("/p.md")?.title, "Pre")
        XCTAssertEqual(files.reads, [])
    }

    func testRemovePathReferencesClosesMatchingTabsAndStripsHistory() async throws {
        for p in ["/a.md", "/b.md", "/c.md"] { files.contents[p] = p }
        await store.openFile("/a.md")          // tab1: a
        await store.navigateToFile("/b.md")    // tab1: b (back a)
        await store.navigateToFile("/c.md")    // tab1: c (back a, b)
        try await store.openFileInNewTab("/b.md") // tab2: b
        store.removePathReferences("/b.md")
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.tabs[0].location, .file("/c.md"))
        XCTAssertEqual(store.tabs[0].back, [.file("/a.md")])
        XCTAssertEqual(store.activeTabId, store.tabs[0].id)
        store.removePathReferences("/c.md")
        XCTAssertEqual(store.tabs.map { $0.location }, [.launcher], "launcher ensured")
    }

    func testRemovePathsWithPrefix() async throws {
        for p in ["/w/dir/a.md", "/w/dir/sub/b.md", "/w/dirx/c.md", "/w/d.md"] { files.contents[p] = p }
        await store.openFile("/w/d.md")
        await store.navigateToFile("/w/dir/a.md")
        try await store.openFileInNewTab("/w/dir/sub/b.md")
        try await store.openFileInNewTab("/w/dirx/c.md")
        store.removePathsWithPrefix("/w/dir")
        XCTAssertEqual(tabPaths(), ["/w/dirx/c.md"], "sibling prefix kept")
        XCTAssertFalse(store.openFiles.keys.contains { $0.hasPrefix("/w/dir/") })
        store.removePathsWithPrefix("/w/dirx/")
        XCTAssertEqual(store.tabs.map { $0.location }, [.launcher])
    }

    func testRewritePathPrefix() async throws {
        for p in ["/w/dir/a.md", "/w/dir/sub/b.md", "/w/dirx/c.md"] { files.contents[p] = p }
        await store.openFile("/w/dir/a.md")
        await store.navigateToFile("/w/dir/sub/b.md")
        try await store.openFileInNewTab("/w/dirx/c.md")
        store.setActiveTab(store.tabs[0].id)
        store.rewritePathPrefix("/w/dir", to: "/w/moved")
        XCTAssertEqual(store.tabs[0].location, .file("/w/moved/sub/b.md"))
        XCTAssertEqual(store.tabs[0].back, [.file("/w/moved/a.md")])
        XCTAssertEqual(store.tabs[1].location, .file("/w/dirx/c.md"))
        XCTAssertEqual(store.activeFilePath, "/w/moved/sub/b.md")
        XCTAssertEqual(store.file("/w/moved/a.md")?.path, "/w/moved/a.md")
        XCTAssertNil(store.file("/w/dir/a.md"))
    }

    func testRenameOpenFileReschedulesDirtySave() async {
        writer.autoComplete = false
        files.contents["/a.md"] = "a"
        await store.openFile("/a.md")
        store.updateContent("/a.md", "x") // immediate write in flight for /a.md
        store.renameOpenFile("/a.md", to: "/b.md")
        XCTAssertEqual(store.tabs[0].location, .file("/b.md"))
        XCTAssertEqual(store.activeFilePath, "/b.md")
        XCTAssertEqual(writer.payloads.map { $0.path }, ["/a.md", "/b.md"])
    }

    func testRestoreSession() async {
        files.contents["/a.md"] = "# A"
        files.contents["/b.md"] = "# B"
        let tabs = [
            SessionTab(location: SerializedLocation(kind: "file", payload: [("path", .string("/a.md"))]), back: [SerializedLocation(kind: "file", payload: [("path", .string("/b.md"))])]),
            SessionTab(location: SerializedLocation(kind: "settings", payload: [])),
            SessionTab(location: SerializedLocation(kind: "future-kind", payload: [("x", .int(1))])),
            SessionTab(location: SerializedLocation(kind: "file", payload: [("path", .string("/missing.md"))])),
        ]
        await store.restoreSession(tabs, activeIndex: 0, prefetchedActiveFile: FileContent(path: "/a.md", content: "# A"))
        XCTAssertEqual(store.tabs.map { $0.location }, [.file("/a.md"), .settings], "unknown kinds and failed files dropped")
        XCTAssertEqual(store.tabs[0].back, [.file("/b.md")])
        XCTAssertEqual(store.activeFilePath, "/a.md")
        XCTAssertFalse(files.reads.contains("/a.md"), "prefetched active file is not re-read")
        XCTAssertEqual(store.file("/b.md")?.title, "B")
    }

    func testRestoreEmptySessionEnsuresLauncher() async {
        await store.restoreSession([], activeIndex: nil)
        XCTAssertEqual(store.tabs.map { $0.location }, [.launcher])
    }

    func testRestoreSessionAllFailing() async {
        await store.restoreSession([SessionTab(location: SerializedLocation(kind: "file", payload: [("path", .string("/x.md"))]))], activeIndex: 3)
        XCTAssertEqual(store.tabs.map { $0.location }, [.launcher])
    }

    func testOpenSettingsTabFocusesOrReplacesLauncher() {
        store.openNewTab()
        let id = store.activeTabId
        store.openSettingsTab()
        XCTAssertEqual(store.tabs, [Tab(id: id!, location: .settings)])
        store.openNewTab()
        store.openSettingsTab()
        XCTAssertEqual(store.activeTabId, id)
        XCTAssertEqual(store.tabs.count, 2)
    }

    func testReloadFromDisk() async {
        files.contents["/a.md"] = "---\ntitle: T\n---\nbody"
        await store.openFile("/a.md")
        store.updateCursorPos("/a.md", 3)
        store.updateContent("/a.md", "local edit")
        store.reloadFromDisk("/a.md", rawContent: "# New\n")
        let f = store.file("/a.md")!
        XCTAssertEqual(f.content, "# New\n")
        XCTAssertNil(f.frontmatter)
        XCTAssertFalse(f.isDirty)
        XCTAssertEqual(f.reloadVersion, 1)
        XCTAssertEqual(f.diskContent, "# New\n")
        XCTAssertEqual(f.title, "New")
        XCTAssertEqual(f.cursorPos, 3)
        XCTAssertEqual(clampCaret(80, length: 5), 5)
    }

    func testTitles() async {
        XCTAssertEqual(store.windowTitle(), "Flo State")
        files.contents["/n/note.md"] = "# Heading"
        await store.openFile("/n/note.md")
        XCTAssertEqual(store.windowTitle(), "Heading")
        XCTAssertEqual(store.tabTitle(store.tabs[0]), "Heading")
        writer.autoComplete = false
        store.updateContent("/n/note.md", "")
        XCTAssertEqual(store.windowTitle(), "note.md")
        XCTAssertEqual(store.tabTitle(store.tabs[0]), "note.md")
    }

    func testObserversReceivePreviousState() async {
        var changes = 0
        store.observers.append { _ in changes += 1 }
        store.openNewTab()
        XCTAssertGreaterThan(changes, 0)
    }
}

@MainActor
final class AppSaveEngineTests: XCTestCase {
    var files: FakeFiles!
    var writer: DeferredWriter!
    var scheduler: ManualScheduler!
    var store: EditorStore!
    var processing = SaveProcessing(trimTrailingWhitespace: false, insertFinalNewline: false)

    override func setUp() async throws {
        files = FakeFiles()
        writer = DeferredWriter()
        scheduler = ManualScheduler()
        let engine = SaveEngine(scheduler: scheduler, processing: { [unowned self] in self.processing }, writer: { [unowned self] p, c, d in self.writer.write(p, c, d) })
        store = EditorStore(reader: { [unowned self] p in try await self.files.read(p) }, saveEngine: engine, displayDate: { _ in nil })
        files.contents["/test.md"] = "initial"
        await store.openFile("/test.md")
    }

    // save.test.ts
    func testNewerEditsStayDirtyUntilFollowUpSave() {
        store.updateContent("/test.md", "first draft")
        XCTAssertEqual(writer.payloads.map { $0.content }, ["first draft"])
        store.updateContent("/test.md", "second draft")
        XCTAssertEqual(writer.payloads.map { $0.content }, ["first draft"], "one write in flight")
        writer.resolve(0)
        let mid = store.file("/test.md")!
        XCTAssertEqual(mid.content, "second draft")
        XCTAssertEqual(mid.diskContent, "first draft")
        XCTAssertTrue(mid.isDirty)
        scheduler.advance(byMs: 999)
        XCTAssertEqual(writer.payloads.count, 1)
        scheduler.advance(byMs: 1)
        XCTAssertEqual(writer.payloads.map { $0.content }, ["first draft", "second draft"])
        writer.resolve(1)
        let saved = store.file("/test.md")!
        XCTAssertEqual(saved.diskContent, "second draft")
        XCTAssertFalse(saved.isDirty)
        XCTAssertFalse(store.saveEngine.hasController("/test.md"), "controller cleaned up")
    }

    func testThrottleOneSecondPerPath() {
        store.updateContent("/test.md", "a")
        store.updateContent("/test.md", "b")
        store.updateContent("/test.md", "c")
        XCTAssertEqual(writer.payloads.count, 1)
        scheduler.advance(byMs: 300)
        writer.resolve(0)
        XCTAssertTrue(store.saveEngine.hasPendingTimer("/test.md"))
        scheduler.advance(byMs: 699)
        XCTAssertEqual(writer.payloads.count, 1, "follow-up waits for 1s since the last save started")
        scheduler.advance(byMs: 1)
        XCTAssertEqual(writer.payloads.map { $0.content }, ["a", "c"], "edits coalesce into one write")
        writer.resolve(1)
        XCTAssertFalse(store.saveEngine.hasController("/test.md"), "idle controllers are dropped")
        store.updateContent("/test.md", "d")
        XCTAssertEqual(writer.payloads.last?.content, "d", "a fresh controller saves immediately")
    }

    func testCancelSaveDropsPendingTimer() {
        store.updateContent("/test.md", "a")
        store.updateContent("/test.md", "b")
        writer.resolve(0)
        XCTAssertTrue(store.saveEngine.hasPendingTimer("/test.md"))
        store.saveEngine.cancelSave("/test.md")
        scheduler.advance(byMs: 5000)
        XCTAssertEqual(writer.payloads.count, 1)
        XCTAssertFalse(store.saveEngine.hasController("/test.md"))
    }

    func testWriteErrorSetsSaveError() {
        struct Boom: Error, CustomStringConvertible { var description: String { "disk full" } }
        store.updateContent("/test.md", "a")
        writer.reject(0, Boom())
        XCTAssertEqual(store.file("/test.md")?.saveError, "disk full")
        XCTAssertTrue(store.file("/test.md")!.isDirty)
        XCTAssertFalse(store.saveEngine.isSaveInFlight("/test.md"))
        store.updateContent("/test.md", "b")
        scheduler.advance(byMs: 1000)
        writer.resolve(1)
        XCTAssertNil(store.file("/test.md")?.saveError, "a successful save clears the error")
    }

    func testCleanFileIsNotWritten() {
        store.saveEngine.scheduleSave("/test.md")
        XCTAssertEqual(writer.payloads.count, 0)
        XCTAssertFalse(store.saveEngine.hasController("/test.md"))
    }

    func testFrontmatterAndProcessingApplied() {
        processing = SaveProcessing(trimTrailingWhitespace: true, insertFinalNewline: true)
        store.updateFrontmatter("/test.md", "title: T  ")
        XCTAssertEqual(writer.payloads.last?.content, "---\ntitle: T\n---\ninitial\n")
        writer.resolve(0)
        XCTAssertEqual(store.file("/test.md")?.diskContent, "---\ntitle: T\n---\ninitial\n")
        XCTAssertFalse(store.file("/test.md")!.isDirty, "processed text is compared, not raw")
    }

    func testProcessingRules() {
        XCTAssertEqual(SaveProcessing(trimTrailingWhitespace: true, insertFinalNewline: false).apply("a  \nb\t\r\n\u{00A0}\n c "), "a\nb\n\n c")
        XCTAssertEqual(SaveProcessing(trimTrailingWhitespace: false, insertFinalNewline: true).apply(""), "\n")
        XCTAssertEqual(SaveProcessing(trimTrailingWhitespace: false, insertFinalNewline: true).apply("x\r\n"), "x\r\n")
        XCTAssertEqual(SaveProcessing(trimTrailingWhitespace: false, insertFinalNewline: true).apply("x"), "x\n")
        XCTAssertEqual(SaveProcessing(settings: SettingsValues([:])), SaveProcessing(trimTrailingWhitespace: false, insertFinalNewline: true))
    }

    func testPerPathIndependence() async throws {
        files.contents["/other.md"] = "o"
        try await store.openFileInNewTab("/other.md")
        store.updateContent("/test.md", "t1")
        store.updateContent("/other.md", "o1")
        XCTAssertEqual(writer.payloads.map { $0.path }, ["/test.md", "/other.md"])
    }
}

@MainActor
final class AppFileWatchReconcilerTests: XCTestCase {
    func makeStore() async -> (EditorStore, FakeFiles, DeferredWriter, ManualScheduler) {
        let files = FakeFiles()
        let writer = DeferredWriter()
        let scheduler = ManualScheduler()
        let engine = SaveEngine(scheduler: scheduler, processing: { SaveProcessing(trimTrailingWhitespace: false, insertFinalNewline: false) },
                                writer: { p, c, d in writer.write(p, c, d) })
        let store = EditorStore(reader: { p in try await files.read(p) }, saveEngine: engine, displayDate: { _ in nil })
        files.contents["/a.md"] = "disk v1"
        await store.openFile("/a.md")
        return (store, files, writer, scheduler)
    }

    func testReloadsWhenDiskDiffers() async {
        let (store, files, _, _) = await makeStore()
        let r = FileChangeReconciler(editor: store, reader: { p in try await files.read(p) })
        var bumps = 0
        r.onSidebarMetadataChanged = { bumps += 1 }
        store.updateContent("/a.md", "unsaved")  // write in flight (deferred writer)
        XCTAssertEqual(r.decide(path: "/a.md", kind: .modified), .saveInFlight)
        let fresh = await makeStore()
        let r2 = FileChangeReconciler(editor: fresh.0, reader: { p in try await fresh.1.read(p) })
        fresh.1.contents["/a.md"] = "disk v2"
        let reloaded = await r2.handleFileChanged(path: "/a.md", kind: .modified)
        XCTAssertTrue(reloaded)
        XCTAssertEqual(fresh.0.file("/a.md")?.content, "disk v2")
        XCTAssertEqual(fresh.0.file("/a.md")?.reloadVersion, 1)
        _ = await r.handleFileChanged(path: "/zzz.md", kind: .modified)
        XCTAssertEqual(bumps, 1)
    }

    func testNoReloadWhenSameAsDiskContent() async {
        let (store, files, _, _) = await makeStore()
        let r = FileChangeReconciler(editor: store, reader: { p in try await files.read(p) })
        let reloaded = await r.handleFileChanged(path: "/a.md", kind: .modified)
        XCTAssertFalse(reloaded)
        XCTAssertEqual(store.file("/a.md")?.reloadVersion, 0)
    }

    func testDecisions() async {
        let (store, files, writer, scheduler) = await makeStore()
        let r = FileChangeReconciler(editor: store, reader: { p in try await files.read(p) })
        XCTAssertEqual(r.decide(path: "/nope.md", kind: .modified), .notOpen)
        XCTAssertEqual(r.decide(path: "/a.md", kind: .deleted), .ignoredDeletion)
        XCTAssertEqual(r.decide(path: "/a.md", kind: .created), .reread)
        // A pending (not in-flight) save is cancelled and unsaved edits are replaced.
        store.updateContent("/a.md", "edit 1")
        store.updateContent("/a.md", "edit 2")
        writer.resolve(0)
        XCTAssertTrue(store.saveEngine.hasPendingTimer("/a.md"))
        files.contents["/a.md"] = "external"
        let reloaded = await r.handleFileChanged(path: "/a.md", kind: .modified)
        XCTAssertTrue(reloaded)
        XCTAssertEqual(store.file("/a.md")?.content, "external")
        XCTAssertFalse(store.file("/a.md")!.isDirty)
        scheduler.advance(byMs: 5000)
        XCTAssertEqual(writer.payloads.count, 1, "cancelled save never fires")
    }
}

@MainActor
final class AppSessionAndRecentsTests: XCTestCase {
    var dir: String!
    override func setUp() async throws { dir = AppTestFS.makeTempDir("sess") }
    override func tearDown() async throws { AppTestFS.remove(dir) }

    func testSessionStoreFormatAndKeying() throws {
        let store = SessionStore(url: URL(fileURLWithPath: dir + "/sessions.json"))
        let tab = SessionTab(location: SerializedLocation(kind: "file", payload: [("path", .string("/w/a.md"))]),
                             back: [SerializedLocation(kind: "file", payload: [("path", .string("/w/b.md"))])])
        try store.save(root: "/w/", tabs: [tab], activeIndex: 0)
        XCTAssertEqual(AppTestFS.read(dir + "/sessions.json"), """
        {
          "/w": {
            "tabs": [
              {
                "location": {
                  "kind": "file",
                  "path": "/w/a.md"
                },
                "back": [
                  {
                    "kind": "file",
                    "path": "/w/b.md"
                  }
                ],
                "forward": []
              }
            ],
            "active_index": 0
          }
        }
        """)
        XCTAssertEqual(store.load(root: "/w"), SessionData(tabs: [tab], activeIndex: 0))
        XCTAssertEqual(store.load(root: "/w//"), SessionData(tabs: [tab], activeIndex: 0))
        try store.save(root: "/other", tabs: [tab], activeIndex: nil)
        XCTAssertNil(store.load(root: "/other")!.activeIndex)
        try store.save(root: "/w", tabs: [], activeIndex: nil)
        XCTAssertNil(store.load(root: "/w"), "empty session deletes the key")
        XCTAssertNotNil(store.load(root: "/other"))
    }

    func testSessionStoreReadsWebAppFileAndKeepsUnknownFields() throws {
        AppTestFS.write(dir + "/sessions.json", #"{"/ws":{"tabs":[{"location":{"kind":"file","path":"/ws/a.md","extra":true}},{"location":{"kind":"graph","zoom":2},"back":[],"forward":[]}],"active_index":1}}"#)
        let store = SessionStore(url: URL(fileURLWithPath: dir + "/sessions.json"))
        let s = store.load(root: "/ws")!
        XCTAssertEqual(s.activeIndex, 1)
        XCTAssertEqual(s.tabs.count, 2)
        XCTAssertEqual(s.tabs[1].location.kind, "graph")
        XCTAssertEqual(s.tabs[0].location.json, .object([("kind", .string("file")), ("path", .string("/ws/a.md")), ("extra", .bool(true))]))
        AppTestFS.write(dir + "/sessions.json", "not json")
        XCTAssertNil(store.load(root: "/ws"))
    }

    func makeEditor(_ scheduler: ManualScheduler) -> (EditorStore, FakeFiles) {
        let files = FakeFiles()
        let engine = SaveEngine(scheduler: scheduler, processing: { SaveProcessing() }, writer: { _, _, d in d(.success(())) })
        return (EditorStore(reader: { p in try await files.read(p) }, saveEngine: engine, displayDate: { _ in nil }), files)
    }

    func testAutosaverDebounceAndFlush() async {
        let scheduler = ManualScheduler()
        let (editor, files) = makeEditor(scheduler)
        let store = SessionStore(url: URL(fileURLWithPath: dir + "/sessions.json"))
        var root: String? = "/ws"
        var enabled = true
        let saver = SessionAutosaver(editor: editor, store: store, scheduler: scheduler, root: { root }, restoreOpenFiles: { enabled })
        files.contents["/ws/a.md"] = "a"
        await editor.openFile("/ws/a.md")
        editor.openNewTab()
        XCTAssertEqual(saver.saveCount, 0)
        scheduler.advance(byMs: 499)
        XCTAssertEqual(saver.saveCount, 0)
        scheduler.advance(byMs: 1)
        XCTAssertEqual(saver.saveCount, 1, "one debounced save for the burst")
        XCTAssertEqual(store.load(root: "/ws")?.tabs.count, 1, "launcher not saved")
        XCTAssertNil(store.load(root: "/ws")?.activeIndex)
        editor.updateCursorPos("/ws/a.md", 1)
        scheduler.advance(byMs: 1000)
        XCTAssertEqual(saver.saveCount, 1, "content-only changes don't trigger a session save")
        editor.setActiveFile("/ws/a.md")
        saver.flush()
        XCTAssertEqual(saver.saveCount, 2)
        XCTAssertEqual(store.load(root: "/ws")?.activeIndex, 0)
        XCTAssertFalse(saver.hasPendingSave)
        enabled = false
        editor.openNewTab()
        scheduler.advance(byMs: 500)
        XCTAssertEqual(saver.saveCount, 2, "restore-open-files off: nothing saved")
        enabled = true
        root = nil
        saver.flush()
        XCTAssertEqual(saver.saveCount, 2, "no root (compact window): nothing saved")
        XCTAssertNil(SessionAutosaver.loadSession(store: store, root: "/ws", restoreOpenFiles: false))
    }

    func testRecentWorkspaces() throws {
        let s = RecentWorkspacesStore(url: URL(fileURLWithPath: dir + "/recent_workspaces.json"))
        XCTAssertEqual(s.load(), [])
        for i in 0..<12 { try s.record("/w\(i)") }
        XCTAssertEqual(s.load().count, 10)
        XCTAssertEqual(s.load().first, "/w11")
        try s.record("/w5")
        XCTAssertEqual(Array(s.load().prefix(2)), ["/w5", "/w11"])
        try s.remove("/w11")
        XCTAssertFalse(s.load().contains("/w11"))
        XCTAssertTrue(AppTestFS.read(dir + "/recent_workspaces.json")!.hasPrefix("[\n  \"/w5\",\n"))
    }

    func testRecentFilesPushAndFormats() throws {
        var list = [RecentEntry(path: "/a.md", openedAt: 1), RecentEntry(path: "/b.md", openedAt: 2)]
        RecentFilesStore.push(&list, path: "/c.md", openedAt: 99)
        XCTAssertEqual(list.map { $0.path }, ["/c.md", "/a.md", "/b.md"])
        RecentFilesStore.push(&list, path: "/b.md", openedAt: 100)
        XCTAssertEqual(list.map { $0.path }, ["/b.md", "/c.md", "/a.md"])
        XCTAssertEqual(list[0].openedAt, 100)
        var big = (0..<30).map { RecentEntry(path: "/file-\($0).md", openedAt: UInt64($0)) }
        RecentFilesStore.push(&big, path: "/newest.md", openedAt: 1000)
        XCTAssertEqual(big.count, 30)
        XCTAssertFalse(big.contains { $0.path == "/file-29.md" })

        let store = RecentFilesStore(url: URL(fileURLWithPath: dir + "/recent_files.json"))
        AppTestFS.write(dir + "/recent_files.json", #"["/a.md", "/b.md"]"#)
        XCTAssertEqual(store.load(), [RecentEntry(path: "/a.md", openedAt: 0), RecentEntry(path: "/b.md", openedAt: 0)])
        AppTestFS.write(dir + "/recent_files.json", "garbage")
        XCTAssertEqual(store.load(), [])
    }

    func testRecentFilesRecordFilterAndList() throws {
        let store = RecentFilesStore(url: URL(fileURLWithPath: dir + "/app/recent_files.json"))
        AppTestFS.write(dir + "/notes/one.md", "# One")
        AppTestFS.write(dir + "/notes/two.md", "two")
        AppTestFS.write(dir + "/notes/x.txt", "x")
        try store.record(dir + "/notes/one.md", now: Date(timeIntervalSince1970: 100))
        try store.record(dir + "/notes/x.txt", now: Date(timeIntervalSince1970: 101))
        try store.record(dir + "/notes/missing.md", now: Date(timeIntervalSince1970: 102))
        try store.record(dir + "/notes/two.md", now: Date(timeIntervalSince1970: 103))
        XCTAssertEqual(store.load().map { $0.path }, [dir + "/notes/two.md", dir + "/notes/one.md"])
        AppTestFS.remove(dir + "/notes/two.md")
        let listed = store.list()
        XCTAssertEqual(listed, [RecentFile(path: dir + "/notes/one.md", name: "one.md", title: "One", openedAt: 100)])
        XCTAssertEqual(store.load().count, 2, "unstat-able entries hidden but kept")
        try store.remove(dir + "/notes/two.md")
        XCTAssertEqual(store.load().count, 1)
        let raw = AppTestFS.read(dir + "/app/recent_files.json")!
        XCTAssertTrue(raw.contains("\"opened_at\": 100"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/app/recent_files.json.tmp"))
    }

    func testRecentFilesRecorder() async {
        let scheduler = ManualScheduler()
        let (editor, files) = makeEditor(scheduler)
        var recorded: [String] = []
        _ = RecentFilesRecorder(editor: editor, record: { recorded.append($0) })
        files.contents["/a.md"] = "a"
        files.contents["/b.md"] = "b"
        await editor.openFile("/a.md")
        try? await editor.openFileInNewTab("/b.md")
        editor.setActiveFile("/b.md")
        editor.setActiveFile("/a.md")
        XCTAssertEqual(recorded, ["/a.md", "/b.md", "/a.md"])
    }
}

final class AppWorkspaceTreeTests: XCTestCase {
    func entry(_ path: String, dir: Bool = false) -> DirEntry {
        DirEntry(name: (path as NSString).lastPathComponent, path: path, isDir: dir, isMarkdown: !dir, modifiedAt: 0, title: nil)
    }

    func makeModel() -> (WorkspaceTreeModel, () -> [String]) {
        var reads: [String] = []
        let listing: [String: [DirEntry]] = [
            "/ws": [entry("/ws/a", dir: true), entry("/ws/b", dir: true), entry("/ws/x.md")],
            "/ws/a": [entry("/ws/a/sub", dir: true), entry("/ws/a/1.md")],
            "/ws/a/sub": [entry("/ws/a/sub/2.md")],
            "/ws/b": [entry("/ws/b/3.md")],
        ]
        let m = WorkspaceTreeModel(readDirectory: { p in reads.append(p); return listing[p] ?? [] })
        m.open(root: "/ws", entries: listing["/ws"]!, recentWorkspaces: ["/ws"], pinned: ["/ws/x.md", "/elsewhere/y.md", "/ws/x.md"])
        return (m, { reads })
    }

    // stores.test.ts — workspace-store
    func testToggleDirectory() throws {
        let (m, reads) = makeModel()
        try m.toggleDirectory("/ws/a")
        XCTAssertTrue(m.expandedDirs.contains("/ws/a"))
        XCTAssertNotNil(m.directoryCache["/ws/a"])
        try m.toggleDirectory("/ws/a")
        XCTAssertFalse(m.expandedDirs.contains("/ws/a"))
        try m.toggleDirectory("/ws/a")
        XCTAssertEqual(reads(), ["/ws/a"], "cached listing reused")
    }

    func testInvalidateAndDirectoryChanged() throws {
        let (m, reads) = makeModel()
        try m.toggleDirectory("/ws/a")
        m.invalidatePath("/ws/a")
        XCTAssertNil(m.directoryCache["/ws/a"])
        try m.refreshDirectory("/ws/a")
        m.handleDirectoryChanged("/ws/a/sub")
        XCTAssertEqual(reads().suffix(1), ["/ws/a"], "hidden dir invalidated, expanded parent refreshed")
        XCTAssertNil(m.directoryCache["/ws/a/sub"])
        XCTAssertEqual(m.sidebarMetadataVersion, 1)
        m.handleDirectoryChanged("/ws/b")
        XCTAssertEqual(reads().last, "/ws", "root is always refreshed in place")
    }

    func testPinnedFiles() {
        let (m, _) = makeModel()
        XCTAssertEqual(m.pinnedFiles, ["/ws/x.md"], "normalized: inside root, deduped")
        var persisted: [[String]] = []
        m.persistPinned = { _, list in persisted.append(list) }
        m.togglePinnedFile("/ws/a/1.md")
        XCTAssertEqual(m.pinnedFiles, ["/ws/a/1.md", "/ws/x.md"])
        m.togglePinnedFile("/ws/a/1.md")
        XCTAssertEqual(m.pinnedFiles, ["/ws/x.md"])
        m.togglePinnedFile("/outside.md")
        XCTAssertEqual(m.pinnedFiles, ["/ws/x.md"])
        m.togglePinnedFile("/ws/a/sub/2.md")
        m.rewritePinnedPath("/ws/a", to: "/ws/z")
        XCTAssertEqual(m.pinnedFiles, ["/ws/z/sub/2.md", "/ws/x.md"])
        m.removePinnedFilesWithPrefix("/ws/z")
        XCTAssertEqual(m.pinnedFiles, ["/ws/x.md"])
        m.removePinnedFile("/ws/x.md")
        XCTAssertEqual(m.pinnedFiles, [])
        XCTAssertEqual(persisted.count, 6)
        XCTAssertEqual(WorkspaceTreeModel.pinnedFilesPreferenceKey("/ws"), "workspace:/ws:sidebar-pinned-files")
    }

    func testRewriteExpandedDir() throws {
        let (m, _) = makeModel()
        try m.toggleDirectory("/ws/a")
        try m.toggleDirectory("/ws/a/sub")
        m.rewriteExpandedDir("/ws/a", to: "/ws/renamed")
        XCTAssertEqual(m.expandedDirs, ["/ws/renamed", "/ws/renamed/sub"])
        XCTAssertNotNil(m.directoryCache["/ws/renamed/sub"])
        XCTAssertNil(m.directoryCache["/ws/a"])
        m.rewriteExpandedDir("/ws/b", to: "/ws/c")
        XCTAssertNil(m.directoryCache["/ws/c"], "no-op when the folder is not expanded")
    }

    func testVisibleOrderStepping() throws {
        let (m, _) = makeModel()
        XCTAssertEqual(m.visibleFiles(), ["/ws/x.md"])
        try m.expandAncestors(of: "/ws/a/sub/2.md")
        XCTAssertEqual(m.visibleFiles(), ["/ws/a/sub/2.md", "/ws/a/1.md", "/ws/x.md"])
        XCTAssertEqual(m.stepFile(from: "/ws/a/1.md", by: 1), "/ws/x.md")
        XCTAssertNil(m.stepFile(from: "/ws/x.md", by: 1), "stops at the end")
        XCTAssertNil(m.stepFile(from: "/ws/a/sub/2.md", by: -1))
    }

    func testCloseAndRecents() {
        let (m, _) = makeModel()
        m.removeRecentWorkspace("/ws")
        XCTAssertEqual(m.recentWorkspaces, [])
        m.close()
        XCTAssertNil(m.root)
        XCTAssertTrue(m.directoryCache.isEmpty)
    }
}

import XCTest
@testable import FloCore

final class AppIndexAndSearchTests: XCTestCase {
    var dir: String!
    override func setUp() { dir = AppTestFS.makeTempDir("search") }
    override func tearDown() { AppTestFS.remove(dir) }

    func setupWorkspace() {
        AppTestFS.write(dir + "/readme.md", "# Readme")
        AppTestFS.write(dir + "/notes.md", "# Notes")
        AppTestFS.write(dir + "/data.txt", "not indexed")
        AppTestFS.write(dir + "/docs/guide.md", "# Guide")
        AppTestFS.write(dir + "/.git/config.md", "git")
    }

    func build() -> (files: [IndexedFile], dirs: Set<String>) {
        let r = FileIndex.build(root: dir, extensions: .schemaDefault, walker: isolatedWalker(dir))
        return (r.files, r.dirs)
    }

    // search.rs tests
    func testIndexCountsAndSkipsHidden() {
        setupWorkspace()
        let (files, dirs) = build()
        XCTAssertEqual(files.map { $0.relativePath }.sorted(), ["docs/guide.md", "notes.md", "readme.md"])
        XCTAssertFalse(files.contains { $0.relativePath.contains(".git") })
        XCTAssertTrue(dirs.contains(dir))
        XCTAssertTrue(dirs.contains(dir + "/docs"))
        XCTAssertFalse(dirs.contains(dir + "/.git"))
    }

    func testCancelledWalkReturnsNothing() {
        setupWorkspace()
        let r = FileIndex.build(root: dir, extensions: .schemaDefault, walker: isolatedWalker(dir), isCancelled: { true })
        XCTAssertTrue(r.files.isEmpty)
        XCTAssertTrue(r.dirs.isEmpty)
    }

    func testFuzzyRanksAndMatchIndices() {
        setupWorkspace()
        let files = build().files
        XCTAssertEqual(FuzzySearch.search("readme", in: files, limit: 50).first?.filename, "readme.md")
        let g = FuzzySearch.search("guide", in: files, limit: 50)
        XCTAssertEqual(g.first?.matchIndices, [5, 6, 7, 8, 9])
        XCTAssertTrue(FuzzySearch.search("", in: files, limit: 50).isEmpty)
        XCTAssertLessThanOrEqual(FuzzySearch.search("md", in: files, limit: 1).count, 1)
    }

    func testSpaceSeparatedNames() {
        AppTestFS.write(dir + "/No prior experience.md", "# Note")
        let r = FuzzySearch.search("No prior experience", in: build().files, limit: 50)
        XCTAssertEqual(r.first?.filename, "No prior experience.md")
    }

    func testScoringFormula() {
        let idx = [
            IndexedFile(path: "/w/notes/plan.md", relativePath: "notes/plan.md", name: "plan.md", modifiedAt: 0),
            IndexedFile(path: "/w/plan-b.md", relativePath: "plan-b.md", name: "plan-b.md", modifiedAt: 0),
            IndexedFile(path: "/w/planning/x.md", relativePath: "planning/x.md", name: "x.md", modifiedAt: 0),
            IndexedFile(path: "/w/My Plan B.md", relativePath: "My Plan B.md", name: "My Plan B.md", modifiedAt: 0),
        ]
        let r = FuzzySearch.search("Plan", in: idx, limit: 50)
        XCTAssertEqual(r.map { $0.relativePath }, ["plan-b.md", "My Plan B.md", "notes/plan.md", "planning/x.md"])
        XCTAssertEqual(r[0].score, 1_000_000 + 10_000 + (1_000 - 9))
        XCTAssertEqual(r[1].score, 1_000_000 + (10_000 - 3) + (1_000 - 12))
        XCTAssertEqual(r[2].score, 1_000_000 + (10_000 - 6) + (1_000 - 13))
        XCTAssertEqual(r[3].score, 10_000 + (1_000 - 13), "match in a parent directory gets no filename bonus")
        // hyphen/space variants
        let hy = FuzzySearch.search("plan b", in: idx, limit: 50)
        XCTAssertEqual(Set(hy.map { $0.relativePath }), ["plan-b.md", "My Plan B.md"])
        XCTAssertEqual(hy.first { $0.relativePath == "plan-b.md" }?.matchIndices, [0, 1, 2, 3, 4, 5])
        let sp = FuzzySearch.search("my-plan", in: idx, limit: 50)
        XCTAssertEqual(sp.map { $0.relativePath }, ["My Plan B.md"])
    }

    func testMatchIndicesAreCharacterOffsets() {
        let idx = [IndexedFile(path: "/w/été/café notes.md", relativePath: "été/café notes.md", name: "café notes.md", modifiedAt: 0)]
        let r = FuzzySearch.search("notes", in: idx, limit: 5)
        XCTAssertEqual(r.first?.matchIndices, [9, 10, 11, 12, 13])
        // Byte offset (not char offset) feeds the score: "été/café " is 12 bytes.
        XCTAssertEqual(r.first?.score, 1_000_000 + (10_000 - 12) + (1_000 - 17))
    }

    func testFindFileByName() {
        FileManager.default.createFile(atPath: dir + "/pic.png", contents: Data([0]))
        AppTestFS.mkdir(dir + "/a/b")
        FileManager.default.createFile(atPath: dir + "/a/b/pic.png", contents: Data([0]))
        AppTestFS.mkdir(dir + "/assets")
        FileManager.default.createFile(atPath: dir + "/assets/Diagram.PNG", contents: Data([0]))
        AppTestFS.mkdir(dir + "/.git")
        FileManager.default.createFile(atPath: dir + "/.git/hidden.png", contents: Data([0]))
        XCTAssertEqual(FuzzySearch.findFileByName(root: dir, fileName: "pic.png", walker: isolatedWalker(dir)), dir + "/pic.png")
        XCTAssertEqual(FuzzySearch.findFileByName(root: dir, fileName: "diagram.png", walker: isolatedWalker(dir)), dir + "/assets/Diagram.PNG")
        XCTAssertNil(FuzzySearch.findFileByName(root: dir, fileName: "nope.png", walker: isolatedWalker(dir)))
        XCTAssertNil(FuzzySearch.findFileByName(root: dir, fileName: "hidden.png", walker: isolatedWalker(dir)))
    }

    func testGitignoreOnlyHonouredInsideGitRepo() {
        AppTestFS.write(dir + "/.gitignore", "drafts/\n")
        AppTestFS.write(dir + "/drafts/wip.md", "w")
        AppTestFS.write(dir + "/a.md", "a")
        AppTestFS.write(dir + "/.ignore", "secret.md\n")
        AppTestFS.write(dir + "/secret.md", "s")
        AppTestFS.write(dir + "/node_modules/x.md", "x")
        // No .git: require_git(true) → .gitignore ignored, .ignore honoured.
        XCTAssertEqual(build().files.map { $0.relativePath }.sorted(), ["a.md", "drafts/wip.md"])
        AppTestFS.mkdir(dir + "/.git")
        XCTAssertEqual(build().files.map { $0.relativePath }.sorted(), ["a.md"])
    }

    func testRecentFilesSliceAndCacheInvalidation() {
        AppTestFS.write(dir + "/old.md", "# Old")
        AppTestFS.write(dir + "/new.md", "# New")
        AppTestFS.write(dir + "/middle.md", "# Middle")
        let index = FileIndex(root: dir)
        index.install(files: [
            IndexedFile(path: dir + "/old.md", relativePath: "old.md", name: "old.md", modifiedAt: 1),
            IndexedFile(path: dir + "/new.md", relativePath: "new.md", name: "new.md", modifiedAt: 3),
            IndexedFile(path: dir + "/middle.md", relativePath: "middle.md", name: "middle.md", modifiedAt: 2),
        ], dirs: [])
        XCTAssertEqual(index.readRecentFiles(limit: 2, offset: 0, extensions: .schemaDefault).map { $0.name }, ["new.md", "middle.md"])
        XCTAssertEqual(index.readRecentFiles(limit: 2, offset: 2, extensions: .schemaDefault).map { $0.name }, ["old.md"])
        index.updateModifiedAt(dir + "/old.md", 5)
        XCTAssertEqual(index.readRecentFiles(limit: 1, offset: 0, extensions: .schemaDefault).map { $0.name }, ["old.md"])
        XCTAssertEqual(index.readRecentFiles(limit: 0, extensions: .schemaDefault).count, 1, "limit clamps to ≥1")
    }

    // watcher.rs index maintenance tests
    func testAddIsIdempotent() {
        let index = FileIndex(root: "/ws")
        index.add("/ws/note.md", modifiedAt: 1)
        index.add("/ws/note.md", modifiedAt: 1)
        XCTAssertEqual(index.files.count, 1)
        XCTAssertTrue(index.dirsWithSupportedFiles.contains("/ws"))
    }

    func testAddSubtreeWalksRealDirectory() {
        AppTestFS.write(dir + "/nested/a.md", "# a")
        AppTestFS.write(dir + "/nested/deeper/b.md", "# b")
        AppTestFS.write(dir + "/nested/ignored.txt", "x")
        let index = FileIndex(root: dir)
        index.addSubtree(dir + "/nested", extensions: .schemaDefault, walker: isolatedWalker(dir + "/nested"))
        XCTAssertEqual(Set(index.files.map { $0.path }), [dir + "/nested/a.md", dir + "/nested/deeper/b.md"])
        XCTAssertEqual(index.files.first { $0.name == "b.md" }?.relativePath, "nested/deeper/b.md")
        XCTAssertTrue(index.dirsWithSupportedFiles.isSuperset(of: [dir + "/nested", dir + "/nested/deeper", dir]))
        index.addSubtree(dir + "/nested", extensions: .schemaDefault, walker: isolatedWalker(dir + "/nested"))
        XCTAssertEqual(index.files.count, 2)
    }

    func testRemoveSubtreeDropsOnlyDescendants() {
        let index = FileIndex(root: "/ws")
        for p in ["/ws/kept.md", "/ws/sub/inside.md", "/ws/sub/nested/x.md", "/ws/submarine/y.md"] { index.add(p, modifiedAt: 0) }
        index.removeSubtree("/ws/sub")
        XCTAssertEqual(Set(index.files.map { $0.path }), ["/ws/kept.md", "/ws/submarine/y.md"])
        XCTAssertTrue(index.dirsWithSupportedFiles.contains("/ws"))
        XCTAssertTrue(index.dirsWithSupportedFiles.contains("/ws/submarine"))
        XCTAssertFalse(index.dirsWithSupportedFiles.contains("/ws/sub"))
        index.remove("/ws/kept.md")
        XCTAssertEqual(index.files.map { $0.path }, ["/ws/submarine/y.md"])
    }
}

final class AppWatcherModelTests: XCTestCase {
    // watcher.rs should_ignore tests
    func testShouldIgnore() {
        XCTAssertTrue(WorkspaceWatcherModel.shouldIgnore("/workspace/.git/config", root: "/workspace"))
        XCTAssertTrue(WorkspaceWatcherModel.shouldIgnore("/workspace/.git/refs/heads/main", root: "/workspace"))
        XCTAssertTrue(WorkspaceWatcherModel.shouldIgnore("/workspace/.DS_Store", root: "/workspace"))
        XCTAssertTrue(WorkspaceWatcherModel.shouldIgnore("/workspace/.hidden/file.md", root: "/workspace"))
        XCTAssertFalse(WorkspaceWatcherModel.shouldIgnore("/workspace/notes/hello.md", root: "/workspace"))
        XCTAssertFalse(WorkspaceWatcherModel.shouldIgnore("/workspace/readme.md", root: "/workspace"))
        XCTAssertFalse(WorkspaceWatcherModel.shouldIgnore("/workspace/.writer/config", root: "/workspace"))
        let dot = "/Users/joel/.notes"
        XCTAssertFalse(WorkspaceWatcherModel.shouldIgnore(dot + "/foo.md", root: dot))
        XCTAssertFalse(WorkspaceWatcherModel.shouldIgnore(dot + "/docs/bar.md", root: dot))
        XCTAssertTrue(WorkspaceWatcherModel.shouldIgnore(dot + "/.cache/x", root: dot))
        XCTAssertTrue(WorkspaceWatcherModel.shouldIgnore(dot + "/.git/HEAD", root: dot))
        XCTAssertFalse(WorkspaceWatcherModel.shouldIgnore("/elsewhere/.cache/file", root: "/workspace"))
    }

    func testSelfWriteTracker() {
        var t = SelfWriteTracker()
        XCTAssertFalse(t.isSelfWrite("/test/file.md", nowMs: 0))
        t.recordWrite("/test/file.md", nowMs: 1000)
        XCTAssertTrue(t.isSelfWrite("/test/file.md", nowMs: 1000))
        XCTAssertTrue(t.isSelfWrite("/test/file.md", nowMs: 2500), "not consumed on match")
        XCTAssertEqual(t.trackedCount, 1)
        XCTAssertTrue(t.isSelfWrite("/test/file.md", nowMs: 2999))
        XCTAssertFalse(t.isSelfWrite("/test/file.md", nowMs: 3000), "expires after 2s")
        t.recordWrite("/other.md", nowMs: 5000)
        XCTAssertEqual(t.trackedCount, 1, "stale entries are pruned on record")
    }

    func makeModel(_ files: Set<String> = [], dirs: Set<String> = [], index: FileIndex? = nil) -> WorkspaceWatcherModel {
        let m = WorkspaceWatcherModel(root: "/ws", extensions: .schemaDefault, index: index, startMs: 0)
        m.exists = { files.contains($0) || dirs.contains($0) }
        m.isDirectory = { dirs.contains($0) }
        m.modifiedTime = { _ in 42 }
        return m
    }

    func testDebounceBatchesAtMostEvery300ms() {
        let m = makeModel(["/ws/a.md"])
        XCTAssertEqual(m.ingest(RawFSEvent(kind: .modifiedData, paths: ["/ws/a.md"]), nowMs: 100), [])
        XCTAssertEqual(m.ingest(RawFSEvent(kind: .modifiedData, paths: ["/ws/a.md"]), nowMs: 200), [])
        let out = m.tick(nowMs: 300)
        XCTAssertEqual(out, [.fileChanged(path: "/ws/a.md", kind: .modified), .fileChanged(path: "/ws/a.md", kind: .modified)])
        XCTAssertEqual(m.ingest(RawFSEvent(kind: .modifiedData, paths: ["/ws/a.md"]), nowMs: 400), [])
        XCTAssertEqual(m.tick(nowMs: 600).count, 1)
        XCTAssertEqual(m.tick(nowMs: 1000), [], "nothing pending")
    }

    func testFiltersAndOutputs() {
        let index = FileIndex(root: "/ws")
        let m = makeModel(["/ws/new.md", "/ws/sub/x.md", "/ws/.writer/config", "/ws/img.png"], dirs: ["/ws/sub", "/ws/folder"], index: index)
        m.recordWrite("/ws/mine.md", nowMs: 0)
        let events: [RawFSEvent] = [
            RawFSEvent(kind: .modifiedData, paths: ["/ws/.git/index"]),
            RawFSEvent(kind: .modifiedData, paths: ["/ws/node_modules/x/readme.md"]),
            RawFSEvent(kind: .modifiedData, paths: ["/ws/mine.md"]),
            RawFSEvent(kind: .created, paths: ["/ws/new.md"]),
            RawFSEvent(kind: .modifiedData, paths: ["/ws/.writer/config"]),
            RawFSEvent(kind: .modifiedData, paths: ["/ws/.gitignore"]),
            RawFSEvent(kind: .createdFolder, paths: ["/ws/folder"]),
            RawFSEvent(kind: .removed, paths: ["/ws/gone.md"]),
            RawFSEvent(kind: .other, paths: ["/ws/new.md"]),
        ]
        var out: [WatcherOutput] = []
        for e in events { out += m.ingest(e, nowMs: 100) }
        out += m.tick(nowMs: 400)
        XCTAssertEqual(out, [
            .fileChanged(path: "/ws/new.md", kind: .created),
            .directoryChanged(path: "/ws", kind: .modified),
            .settingsChanged,
            .directoryChanged(path: "/ws/folder", kind: .created),
            .fileChanged(path: "/ws/gone.md", kind: .deleted),
            .directoryChanged(path: "/ws", kind: .modified),
            .rebuildIgnore,
        ])
        XCTAssertEqual(index.files.map { $0.path }, ["/ws/new.md"])
    }

    func testRenameUpdatesIndexMembership() {
        let index = FileIndex(root: "/ws")
        index.add("/ws/old.md", modifiedAt: 1)
        let m = makeModel(["/ws/renamed.md"], index: index)
        _ = m.ingest(RawFSEvent(kind: .modifiedName, paths: ["/ws/old.md", "/ws/renamed.md"]), nowMs: 500)
        XCTAssertEqual(index.files.map { $0.path }, ["/ws/renamed.md"])
    }

    func testWorkspaceIgnoreFiltersEvents() {
        let m = makeModel(["/ws/dist/a.md"])
        m.ignore = WorkspaceIgnore(gitignores: [.init(scope: "/ws", matcher: Gitignore(root: "/ws", content: "dist/\n"))])
        XCTAssertEqual(m.ingest(RawFSEvent(kind: .modifiedData, paths: ["/ws/dist/a.md"]), nowMs: 500), [])
    }

    func testStandaloneWatcher() {
        let m = StandaloneFileWatcherModel(file: "/d/note.md", startMs: 0)
        m.selfWrites.recordWrite("/d/note.md", nowMs: 0)
        XCTAssertEqual(m.ingest(RawFSEvent(kind: .modifiedData, paths: ["/d/note.md", "/d/other.md"]), nowMs: 500), [])
        XCTAssertEqual(m.ingest(RawFSEvent(kind: .modifiedData, paths: ["/d/note.md"]), nowMs: 2500), [.fileChanged(path: "/d/note.md", kind: .modified)])
        XCTAssertEqual(m.ingest(RawFSEvent(kind: .removed, paths: ["/d/other.md"]), nowMs: 3000), [])
    }

    func testConfigFileDetection() {
        XCTAssertTrue(WorkspaceWatcherModel.isConfigFile("/ws/.writer/config"))
        XCTAssertFalse(WorkspaceWatcherModel.isConfigFile("/ws/config"))
        XCTAssertFalse(WorkspaceWatcherModel.isConfigFile("/ws/.writer/config.bak"))
    }
}

final class AppWorkspaceBootstrapTests: XCTestCase {
    func testOpenCanonicalizesLoadsSettingsAndRecords() throws {
        let dir = AppTestFS.makeTempDir("boot")
        defer { AppTestFS.remove(dir) }
        AppTestFS.write(dir + "/ws/.writer/config", "editor.font-size = 21\n")
        let settings = AppSettings(globalConfigDir: URL(fileURLWithPath: dir + "/app"))
        let recents = RecentWorkspacesStore(url: URL(fileURLWithPath: dir + "/app/recent_workspaces.json"))
        let aliased = dir.hasPrefix("/private") ? String(dir.dropFirst("/private".count)) + "/ws" : dir + "/ws"
        let info = try WorkspaceBootstrap.open(aliased, settings: settings, recents: recents)
        XCTAssertEqual(info, WorkspaceInfo(root: dir + "/ws", name: "ws"))
        XCTAssertEqual(settings.get("editor.font-size"), .number(21))
        XCTAssertEqual(recents.load(), [dir + "/ws"])
        XCTAssertThrowsError(try WorkspaceBootstrap.open(dir + "/nope", settings: nil, recents: nil))
    }

    func testActiveSessionPath() {
        let file = SerializedLocation(kind: "file", payload: [("path", .string("/w/a.md"))])
        XCTAssertEqual(WorkspaceBootstrap.activeSessionPath(SessionData(tabs: [SessionTab(location: file)], activeIndex: 0)), "/w/a.md")
        XCTAssertNil(WorkspaceBootstrap.activeSessionPath(SessionData(tabs: [SessionTab(location: file)], activeIndex: nil)))
        XCTAssertNil(WorkspaceBootstrap.activeSessionPath(SessionData(tabs: [SessionTab(location: SerializedLocation(kind: "settings", payload: []))], activeIndex: 0)))
        XCTAssertNil(WorkspaceBootstrap.activeSessionPath(nil))
    }

    func testStartupPlan() {
        let dirs: Set<String> = ["/ws", "/other"]
        let isDir: (String) -> Bool = { dirs.contains($0) }
        XCTAssertEqual(WorkspaceBootstrap.plan(startupOpen: nil, recentWorkspaces: ["/ws"], restoreWorkspace: true, isDirectory: isDir),
                       .workspace(root: "/ws", openFile: nil, keepSession: true))
        XCTAssertEqual(WorkspaceBootstrap.plan(startupOpen: nil, recentWorkspaces: ["/gone", "/ws"], restoreWorkspace: true, isDirectory: isDir), .empty,
                       "only the most recent workspace is tried")
        XCTAssertEqual(WorkspaceBootstrap.plan(startupOpen: nil, recentWorkspaces: ["/ws"], restoreWorkspace: false, isDirectory: isDir), .empty)
        XCTAssertEqual(WorkspaceBootstrap.plan(startupOpen: PendingOpen(file: "/ws/sub/a.md"), recentWorkspaces: ["/other", "/ws"], restoreWorkspace: false, isDirectory: isDir),
                       .workspace(root: "/ws", openFile: "/ws/sub/a.md", keepSession: true))
        XCTAssertEqual(WorkspaceBootstrap.plan(startupOpen: PendingOpen(file: "/tmp/a.md"), recentWorkspaces: ["/ws"], restoreWorkspace: true, isDirectory: isDir),
                       .standaloneFile("/tmp/a.md"))
        XCTAssertEqual(WorkspaceBootstrap.plan(startupOpen: PendingOpen(workspace: "/other", file: "/other/x.md"), recentWorkspaces: [], restoreWorkspace: true, isDirectory: isDir),
                       .workspace(root: "/other", openFile: "/other/x.md", keepSession: false))
        XCTAssertEqual(WorkspaceBootstrap.plan(startupOpen: PendingOpen(workspace: "/other"), recentWorkspaces: ["/ws"], restoreWorkspace: true, isDirectory: isDir),
                       .workspace(root: "/other", openFile: nil, keepSession: true))
    }

    func testOwningWorkspaceAndResolve() throws {
        XCTAssertEqual(WorkspaceBootstrap.owningWorkspace(of: "/ws/a.md", among: ["/w", "/ws"]), "/ws")
        XCTAssertNil(WorkspaceBootstrap.owningWorkspace(of: "/wsx/a.md", among: ["/ws"]))
        let dir = AppTestFS.makeTempDir("resolve")
        defer { AppTestFS.remove(dir) }
        AppTestFS.write(dir + "/note.MD", "x")
        AppTestFS.write(dir + "/image.png", "x")
        XCTAssertEqual(PendingOpen.resolve(dir), PendingOpen(workspace: dir))
        XCTAssertEqual(PendingOpen.resolve(dir + "/note.MD"), PendingOpen(file: dir + "/note.MD"))
        XCTAssertNil(PendingOpen.resolve(dir + "/image.png"))
        XCTAssertNil(PendingOpen.resolve(dir + "/missing"))
    }

    /// Files the OS hands us (Finder, Open With) open when they're a registered text type, whatever the
    /// sidebar's `files.associations` listing filter says; other files still don't.
    func testRegisteredTextTypesOpenRegardlessOfAssociations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("po-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in ["a.txt", "b.MD", "c.log", "d.png"] { FileManager.default.createFile(atPath: dir + "/" + name, contents: Data("x".utf8)) }
        let mdOnly = SupportedExtensions(patterns: ["*.md"])
        XCTAssertNotNil(PendingOpen.resolve(dir + "/a.txt", extensions: mdOnly)?.file)
        XCTAssertNotNil(PendingOpen.resolve(dir + "/b.MD", extensions: mdOnly)?.file)
        XCTAssertNotNil(PendingOpen.resolve(dir + "/c.log", extensions: mdOnly)?.file)
        XCTAssertNil(PendingOpen.resolve(dir + "/d.png", extensions: mdOnly))
    }
}

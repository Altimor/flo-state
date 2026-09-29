import XCTest
@testable import FloCore

/// Symbolic links inside a workspace: listed and indexed as what they point
/// to, written through (the link survives a save), loops not followed, and
/// watcher events at a link's real target mapped back into the workspace.
final class SymlinkTests: XCTestCase {
    var dir: String!
    var outside: String!
    let fm = FileManager.default

    override func setUp() {
        dir = AppTestFS.makeTempDir("symlink-ws")
        outside = AppTestFS.makeTempDir("symlink-out")
        AppTestFS.write(outside + "/notes/a.md", "# A")
        AppTestFS.write(outside + "/notes/deep/b.md", "# B")
        AppTestFS.write(outside + "/single.md", "# Single")
        AppTestFS.write(dir + "/local.md", "# Local")
    }

    override func tearDown() {
        AppTestFS.remove(dir)
        AppTestFS.remove(outside)
    }

    func link(_ name: String, to target: String) {
        try! fm.createSymbolicLink(atPath: dir + "/" + name, withDestinationPath: target)
    }

    func build() -> (files: [IndexedFile], dirs: Set<String>, symlinks: [SymlinkMount]) {
        FileIndex.build(root: dir, extensions: .schemaDefault, walker: isolatedWalker(dir))
    }

    func testReadDirectoryListsLinkedFolderAndFile() throws {
        link("Linked", to: outside + "/notes")
        link("single.md", to: outside + "/single.md")
        let r = try WorkspaceFS.readDirectory(dir)
        XCTAssertEqual(r.map { $0.name }, ["Linked", "local.md", "single.md"])
        XCTAssertTrue(r[0].isDir)
        XCTAssertEqual(r[0].path, dir + "/Linked")
        XCTAssertEqual(r[2].title, "Single")
    }

    func testIndexFollowsLinksAtWorkspacePaths() {
        link("Linked", to: outside + "/notes")
        link("single.md", to: outside + "/single.md")
        let r = build()
        XCTAssertEqual(r.files.map { $0.relativePath }.sorted(),
                       ["Linked/a.md", "Linked/deep/b.md", "local.md", "single.md"])
        XCTAssertTrue(r.dirs.contains(dir + "/Linked/deep"))
        XCTAssertEqual(r.symlinks, [SymlinkMount(link: dir + "/Linked", target: outside + "/notes"),
                                    SymlinkMount(link: dir + "/single.md", target: outside + "/single.md")])
    }

    func testDanglingLinkIsSkipped() throws {
        link("gone.md", to: outside + "/missing.md")
        link("Gone", to: outside + "/missing")
        XCTAssertEqual(try WorkspaceFS.readDirectory(dir).map { $0.name }, ["local.md"])
        let r = build()
        XCTAssertEqual(r.files.map { $0.relativePath }, ["local.md"])
        XCTAssertTrue(r.symlinks.isEmpty)
    }

    func testLinkBackToAncestorIsNotFollowed() throws {
        AppTestFS.write(dir + "/sub/inner.md", "# Inner")
        try fm.createSymbolicLink(atPath: dir + "/sub/up", withDestinationPath: dir)
        link("self", to: dir + "/self")   // a link to itself
        XCTAssertEqual(build().files.map { $0.relativePath }.sorted(), ["local.md", "sub/inner.md"])
        XCTAssertTrue(WorkspaceFS.dirContainsSupportedFile(dir + "/sub", ignore: nil, extensions: .schemaDefault))
        XCTAssertEqual(try WorkspaceFS.readDirectory(dir).map { $0.name }, ["sub", "local.md"])
    }

    func testTwoLinksToOneFolderBothIndexed() {
        link("One", to: outside + "/notes")
        link("Two", to: outside + "/notes")
        let paths = build().files.map { $0.relativePath }
        XCTAssertTrue(paths.contains("One/a.md"))
        XCTAssertTrue(paths.contains("Two/a.md"))
    }

    func testWriteThroughLinkedFileKeepsLink() throws {
        link("single.md", to: outside + "/single.md")
        try WorkspaceFS.writeFile(dir + "/single.md", content: "# Edited")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dir + "/single.md"), outside + "/single.md")
        XCTAssertEqual(AppTestFS.read(outside + "/single.md"), "# Edited")
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: outside).contains { $0.hasPrefix(".~") })
    }

    func testWriteInsideLinkedFolderLandsInTarget() throws {
        link("Linked", to: outside + "/notes")
        try WorkspaceFS.writeFile(dir + "/Linked/a.md", content: "# A2")
        XCTAssertEqual(AppTestFS.read(outside + "/notes/a.md"), "# A2")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: dir + "/Linked"))
    }

    func testWatchPathsSkipTargetsInsideRootOrAnotherTarget() {
        let links = [
            SymlinkMount(link: dir + "/Linked", target: outside + "/notes"),
            SymlinkMount(link: dir + "/Deep", target: outside + "/notes/deep"),
            SymlinkMount(link: dir + "/Here", target: dir + "/sub"),
            SymlinkMount(link: dir + "/Again", target: outside + "/notes"),
        ]
        XCTAssertEqual(WorkspaceWatcherModel.symlinkWatchPaths(links, root: dir), [outside + "/notes"])
    }

    func testWatcherMapsTargetEventsIntoWorkspace() {
        AppTestFS.write(dir + "/sub/x.md", "# X")
        link("Linked", to: outside + "/notes")
        link("single.md", to: outside + "/single.md")
        link("Here", to: dir + "/sub")
        let index = FileIndex(root: dir)
        index.rebuild(extensions: .schemaDefault, walker: isolatedWalker(dir))
        let w = WorkspaceWatcherModel(root: dir, extensions: .schemaDefault, index: index, startMs: 0)
        XCTAssertEqual(w.workspacePaths(outside + "/notes/deep/b.md"), [dir + "/Linked/deep/b.md"])
        XCTAssertEqual(w.workspacePaths(outside + "/single.md"), [dir + "/single.md"])
        XCTAssertEqual(w.workspacePaths(outside + "/notes-other/x.md"), [outside + "/notes-other/x.md"])
        // A target inside the root: both paths are in the workspace.
        XCTAssertEqual(w.workspacePaths(dir + "/sub/x.md"), [dir + "/sub/x.md", dir + "/Here/x.md"])
        let out = w.ingest(RawFSEvent(kind: .modifiedData, paths: [outside + "/notes/a.md"]), nowMs: 1000)
        XCTAssertEqual(out, [.fileChanged(path: dir + "/Linked/a.md", kind: .modified)])
    }
}

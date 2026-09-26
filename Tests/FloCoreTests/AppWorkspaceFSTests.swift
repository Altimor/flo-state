import XCTest
@testable import FloCore

final class AppWorkspaceFSTests: XCTestCase {
    var dir: String!
    override func setUp() { dir = AppTestFS.makeTempDir("fs") }
    override func tearDown() { AppTestFS.remove(dir) }

    func setupTestDir() {
        AppTestFS.write(dir + "/hello.md", "# Hello")
        AppTestFS.write(dir + "/world.md", "# World")
        AppTestFS.write(dir + "/readme.txt", "text")
        AppTestFS.write(dir + "/notes/note.md", "# Note")
        AppTestFS.write(dir + "/empty/data.txt", "data")
    }

    // fs.rs: test_read_directory_sorts_dirs_first / filters_markdown_only
    // (with the schema-default associations; the Rust fallback list includes .txt).
    func testReadDirectorySortsDirsFirstAndFilters() throws {
        setupTestDir()
        let r = try WorkspaceFS.readDirectory(dir)
        XCTAssertEqual(r.map { $0.name }, ["notes", "hello.md", "world.md"])
        XCTAssertTrue(r[0].isDir)
        XCTAssertNil(r[0].title)
        XCTAssertEqual(r[1].title, "Hello")
        XCTAssertEqual(r[2].title, "World")
        XCTAssertTrue(r.allSatisfy { $0.isDir || $0.isMarkdown })
    }

    func testReadDirectoryWithFallbackExtensionsIncludesTxt() throws {
        setupTestDir()
        let r = try WorkspaceFS.readDirectory(dir, extensions: .default)
        XCTAssertEqual(r.map { $0.name }, ["empty", "notes", "hello.md", "readme.txt", "world.md"])
    }

    func testReadDirectoryUsesIndexDirsWhenReady() throws {
        setupTestDir()
        let built = FileIndex.build(root: dir, extensions: .schemaDefault, walker: isolatedWalker(dir))
        let r = try WorkspaceFS.readDirectory(dir, dirsWithSupportedFiles: built.dirs)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0].name, "notes")
    }

    func testReadDirectorySkipsDotfilesIgnoredAndCaseInsensitiveSort() throws {
        AppTestFS.write(dir + "/.hidden.md", "# h")
        AppTestFS.write(dir + "/.config/x.md", "# x")
        AppTestFS.write(dir + "/b.md", "b")
        AppTestFS.write(dir + "/A.md", "a")
        AppTestFS.write(dir + "/c.MD", "c")
        AppTestFS.write(dir + "/Zeta/z.md", "z")
        AppTestFS.write(dir + "/alpha/deep/er/x.markdown", "x")
        AppTestFS.write(dir + "/dist/out.md", "o")
        AppTestFS.write(dir + "/node_modules/pkg/readme.md", "r")
        AppTestFS.write(dir + "/.gitignore", "dist/\n")
        AppTestFS.write(dir + "/onlyignored/skip.md", "s")
        AppTestFS.write(dir + "/onlyignored/.gitignore", "*.md\n")
        let ignore = WorkspaceIgnore.load(root: URL(fileURLWithPath: dir))
        let r = try WorkspaceFS.readDirectory(dir, ignore: ignore)
        XCTAssertEqual(r.map { $0.name }, ["alpha", "Zeta", "A.md", "b.md", "c.MD"])
    }

    func testReadDirectoryNotFound() {
        XCTAssertThrowsError(try WorkspaceFS.readDirectory(dir + "/missing")) {
            XCTAssertEqual($0 as? AppError, .notFound(self.dir + "/missing"))
        }
    }

    func testReadFileAndNotFound() throws {
        AppTestFS.write(dir + "/test.md", "# Test Content")
        XCTAssertEqual(try WorkspaceFS.readFile(dir + "/test.md").content, "# Test Content")
        XCTAssertThrowsError(try WorkspaceFS.readFile("/nonexistent/file.md")) { XCTAssertEqual($0 as? AppError, .notFound("/nonexistent/file.md")) }
    }

    func testWriteFileAtomicLeavesNoTemp() throws {
        let p = dir + "/output.md"
        AppTestFS.write(p, "old")
        let r = try WorkspaceFS.writeFile(p, content: "new content")
        XCTAssertEqual(r.path, p)
        XCTAssertEqual(AppTestFS.read(p), "new content")
        XCTAssertGreaterThan(r.modifiedAt, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(".~") }
        XCTAssertEqual(leftovers, [])
    }

    func testCreateFile() throws {
        let p = dir + "/a/b/new.md"
        let fc = try WorkspaceFS.createFile(p)
        XCTAssertEqual(fc.content, "# ")
        XCTAssertEqual(AppTestFS.read(p), "# ")
        XCTAssertThrowsError(try WorkspaceFS.createFile(p)) { XCTAssertEqual($0 as? AppError, .alreadyExists(p)) }
    }

    func testCreateDirectory() throws {
        let e = try WorkspaceFS.createDirectory(dir + "/x/y")
        XCTAssertTrue(e.isDir)
        XCTAssertEqual(e.name, "y")
        XCTAssertThrowsError(try WorkspaceFS.createDirectory(dir + "/x/y"))
    }

    func testRenameEntry() throws {
        AppTestFS.write(dir + "/old.md", "content")
        try WorkspaceFS.renameEntry(dir + "/old.md", to: dir + "/new.md")
        XCTAssertFalse(WorkspaceFS.exists(dir + "/old.md"))
        XCTAssertEqual(AppTestFS.read(dir + "/new.md"), "content")
        XCTAssertThrowsError(try WorkspaceFS.renameEntry("/nonexistent/old.md", to: "/nonexistent/new.md")) {
            XCTAssertEqual($0 as? AppError, .notFound("/nonexistent/old.md"))
        }
        AppTestFS.write(dir + "/other.md", "o")
        XCTAssertThrowsError(try WorkspaceFS.renameEntry(dir + "/other.md", to: dir + "/new.md")) {
            XCTAssertEqual($0 as? AppError, .alreadyExists(self.dir + "/new.md"))
        }
    }

    func testDeleteEntryMovesToTrash() throws {
        let p = dir + "/to_delete_\(UUID().uuidString.prefix(6)).md"
        AppTestFS.write(p, "delete me")
        let trashed = try WorkspaceFS.deleteEntry(p)
        XCTAssertFalse(WorkspaceFS.exists(p))
        if let t = trashed { try? FileManager.default.removeItem(at: t) }
        XCTAssertThrowsError(try WorkspaceFS.deleteEntry(p))
    }

    func testErrorStrings() {
        XCTAssertEqual(AppError.io("test error").description, "IO error: test error")
        XCTAssertEqual(AppError.notFound("file.md").description, "Not found: file.md")
        XCTAssertEqual(AppError.noWorkspace.description, "No workspace is open")
    }

    func testReadFileEntriesFiltersMissingUnsupportedAndOutsideRoot() {
        let outside = AppTestFS.makeTempDir("outside")
        defer { AppTestFS.remove(outside) }
        AppTestFS.write(dir + "/kept.md", "# Kept")
        AppTestFS.write(dir + "/note.txt", "not markdown")
        AppTestFS.write(outside + "/outside.md", "# Outside")
        let entries = WorkspaceFS.readFileEntries([dir + "/kept.md", dir + "/missing.md", dir + "/note.txt", outside + "/outside.md"], root: dir)
        XCTAssertEqual(entries.map { $0.name }, ["kept.md"])
        XCTAssertEqual(entries[0].title, "Kept")
    }

    func testCanonicalizeWorkspaceRoot() throws {
        XCTAssertThrowsError(try WorkspaceFS.canonicalizeWorkspaceRoot("/this/path/does/not/exist/ever"))
        AppTestFS.write(dir + "/a-file.md", "x")
        XCTAssertThrowsError(try WorkspaceFS.canonicalizeWorkspaceRoot(dir + "/a-file.md"))
        XCTAssertEqual(try WorkspaceFS.canonicalizeWorkspaceRoot(dir), dir)
        if dir.hasPrefix("/private") {
            XCTAssertEqual(try WorkspaceFS.canonicalizeWorkspaceRoot(String(dir.dropFirst("/private".count))), dir)
        }
    }
}

final class AppExtractTitleTests: XCTestCase {
    func t(_ s: String) -> String? { WorkspaceFS.extractTitle(text: s) }

    func testTitles() {
        XCTAssertEqual(t("# My Document\n\nSome content"), "My Document")
        XCTAssertEqual(t("---\ntitle: Front Title\n---\n\nBody"), "Front Title")
        XCTAssertEqual(t("---\ntitle: \"Quoted Title\"\n---\n\nBody"), "Quoted Title")
        XCTAssertEqual(t("---\ntitle: 'Single'\n---\n"), "Single")
        XCTAssertEqual(t("---\ntitle: FM Title\n---\n\n# Heading"), "FM Title")
        XCTAssertEqual(t("---\ndate: 2025-01-01\n---\n\n# Fallback Heading"), "Fallback Heading")
        XCTAssertNil(t(""))
        XCTAssertNil(t("Just a paragraph.\nAnother line."))
    }

    func testTitleEdgeCases() {
        XCTAssertNil(t("#NoSpace"))
        XCTAssertNil(t("# "), "empty heading")
        XCTAssertEqual(t("\n\n   # Indented  \n"), "Indented", "lines are trimmed before the check")
        XCTAssertNil(t("---\n---\n# After empty fm"), "empty frontmatter never finds a closing \\n---\\n")
        XCTAssertEqual(t("---\ntitle: \"\"\n---\n# H"), "H")
        XCTAssertEqual(t("---\ntitle: \"\n---\n"), "\"")
        XCTAssertEqual(t("---\r\ntitle: CRLF\r\n---\r\nbody"), "CRLF")
        XCTAssertEqual(t("---\n  title:   Spaced  \n---\n"), "Spaced")
        XCTAssertNil(t("---\ntitle: x"), "unterminated frontmatter → leading line must be an H1")
        XCTAssertEqual(t("## Sub\n"), nil)
    }

    func testFourKilobyteLimitAndInvalidUTF8() throws {
        let dir = AppTestFS.makeTempDir("title")
        defer { AppTestFS.remove(dir) }
        AppTestFS.write(dir + "/long.md", String(repeating: "\n", count: 5000) + "# Late")
        XCTAssertNil(WorkspaceFS.extractTitle(dir + "/long.md"))
        // A multi-byte character straddling byte 4096 makes the prefix invalid UTF-8.
        AppTestFS.write(dir + "/cut.md", "# Title\n" + String(repeating: "a", count: 4087) + "é")
        XCTAssertNil(WorkspaceFS.extractTitle(dir + "/cut.md"))
        AppTestFS.write(dir + "/ok.md", "# Title\n" + String(repeating: "a", count: 4086) + "é")
        XCTAssertEqual(WorkspaceFS.extractTitle(dir + "/ok.md"), "Title")
    }
}

final class AppSupportedExtensionsTests: XCTestCase {
    // open_target.rs: files_associations_drive_which_extensions_open
    func testAssociations() {
        let d = SupportedExtensions(patterns: [])
        XCTAssertTrue(d.isSupported("a.md"))
        XCTAssertTrue(d.isSupported("a.txt"))
        XCTAssertTrue(d.isSupported("a.csv"))
        XCTAssertFalse(d.isSupported("a.rs"))
        let c = SupportedExtensions(patterns: ["*.md", "*.rs"])
        XCTAssertTrue(c.isSupported("a.md"))
        XCTAssertTrue(c.isSupported("a.rs"))
        XCTAssertFalse(c.isSupported("a.txt"))
        let u = SupportedExtensions(patterns: ["*.TXT"])
        XCTAssertTrue(u.isSupported("a.txt"))
        XCTAssertTrue(u.isSupported("a.TxT"))
        XCTAssertTrue(SupportedExtensions(patterns: ["nonsense"]).isSupported("a.md"))
        XCTAssertFalse(d.isSupported(".md"), "dotfile has no extension")
        XCTAssertFalse(d.isSupported("/x/README"))
        XCTAssertEqual(SupportedExtensions.schemaDefault.extensions, ["md", "mdx", "markdown", "csv"])
        XCTAssertTrue(SupportedExtensions(patterns: [" *.md "]).isSupported("x.md"))
    }
}

final class AppNamingAndImageTests: XCTestCase {
    func testNewFileNaming() throws {
        var existing: Set<String> = []
        XCTAssertEqual(try WorkspaceFS.newFilePath(in: "/w", exists: existing.contains), "/w/Untitled.md")
        existing = ["/w/Untitled.md"]
        XCTAssertEqual(try WorkspaceFS.newFilePath(in: "/w", exists: existing.contains), "/w/Untitled 2.md")
        existing = ["/w/Untitled.md", "/w/Untitled 2.md", "/w/Untitled 3.md"]
        XCTAssertEqual(try WorkspaceFS.newFilePath(in: "/w", exists: existing.contains), "/w/Untitled 4.md")
        XCTAssertEqual(try WorkspaceFS.newFolderPath(in: "/w", exists: { _ in false }), "/w/Untitled Folder")
        XCTAssertEqual(try WorkspaceFS.newFolderPath(in: "/w", exists: { $0 == "/w/Untitled Folder" }), "/w/Untitled Folder 2")
        XCTAssertThrowsError(try WorkspaceFS.newFilePath(in: "/w", exists: { _ in true }))
    }

    func testDuplicateNaming() throws {
        XCTAssertEqual(try WorkspaceFS.duplicatePath(for: "/w/note.md", exists: { _ in false }), "/w/note copy.md")
        XCTAssertEqual(try WorkspaceFS.duplicatePath(for: "/w/note.md", exists: { $0 == "/w/note copy.md" }), "/w/note copy 2.md")
        XCTAssertEqual(try WorkspaceFS.duplicatePath(for: "/w/a.b.md", exists: { _ in false }), "/w/a.b copy.md")
        XCTAssertEqual(try WorkspaceFS.duplicatePath(for: "/w/Makefile", exists: { _ in false }), "/w/Makefile copy")
    }

    func testPaletteCreatePath() {
        XCTAssertEqual(WorkspaceFS.paletteCreatePath(root: "/w", rawName: "  Ideas "), "/w/Ideas.md")
        XCTAssertEqual(WorkspaceFS.paletteCreatePath(root: "/w", rawName: "x.md"), "/w/x.md")
        XCTAssertEqual(WorkspaceFS.paletteCreatePath(root: "/w", rawName: "x.markdown"), "/w/x.markdown.md")
        XCTAssertNil(WorkspaceFS.paletteCreatePath(root: "/w", rawName: "   "))
    }

    func testClipboardImageNameIsUTC() {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let uuid = UUID(uuidString: "ABCDEF01-0000-4000-8000-000000000000")!
        XCTAssertEqual(WorkspaceFS.clipboardImageFileName(date: date, format: "png", uuid: uuid), "20231114-221320-abcd.png")
        XCTAssertEqual(WorkspaceFS.clipboardImageFileName(date: date, format: "jpeg", uuid: uuid), "20231114-221320-abcd.jpg")
        XCTAssertEqual(WorkspaceFS.clipboardImageFileName(date: date, format: "webp", uuid: uuid), "20231114-221320-abcd.webp")
        XCTAssertEqual(WorkspaceFS.clipboardImageFileName(date: date, format: "gif", uuid: uuid), "20231114-221320-abcd.png")
        // Leap day.
        XCTAssertTrue(WorkspaceFS.clipboardImageFileName(date: Date(timeIntervalSince1970: 1_709_164_800), format: "png").hasPrefix("20240229-000000-"))
    }

    func testSaveClipboardImage() throws {
        let dir = AppTestFS.makeTempDir("img")
        defer { AppTestFS.remove(dir) }
        AppTestFS.write(dir + "/note.md", "# Note")
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let r = try WorkspaceFS.saveClipboardImage(markdownFilePath: dir + "/note.md", data: data, format: "png")
        XCTAssertTrue(WorkspaceFS.isDirectory(dir + "/attachments"))
        XCTAssertNotNil(r.relativePath.range(of: #"^attachments/\d{8}-\d{6}-[a-f0-9]{4}\.png$"#, options: .regularExpression))
        XCTAssertEqual(FileManager.default.contents(atPath: dir + "/" + r.relativePath), data)
        XCTAssertEqual(r.absolutePath, dir + "/" + r.relativePath)
    }

    func testImportImageFile() throws {
        let dir = AppTestFS.makeTempDir("imp")
        defer { AppTestFS.remove(dir) }
        AppTestFS.write(dir + "/note.md", "# note")
        FileManager.default.createFile(atPath: dir + "/shot.png", contents: Data([9]))
        let first = try WorkspaceFS.importImageFile(markdownFilePath: dir + "/note.md", sourcePath: dir + "/shot.png")
        let second = try WorkspaceFS.importImageFile(markdownFilePath: dir + "/note.md", sourcePath: dir + "/shot.png")
        let third = try WorkspaceFS.importImageFile(markdownFilePath: dir + "/note.md", sourcePath: dir + "/shot.png")
        XCTAssertEqual(first.relativePath, "attachments/shot.png")
        XCTAssertEqual(second.relativePath, "attachments/shot-1.png")
        XCTAssertEqual(third.relativePath, "attachments/shot-2.png")
        XCTAssertEqual(FileManager.default.contents(atPath: dir + "/attachments/shot.png"), Data([9]))
        XCTAssertThrowsError(try WorkspaceFS.importImageFile(markdownFilePath: dir + "/note.md", sourcePath: dir + "/missing.png"))
        XCTAssertTrue(WorkspaceFS.isImagePath("a.HEIC"))
        XCTAssertFalse(WorkspaceFS.isImagePath("a.md"))
    }
}

final class AppGitignoreTests: XCTestCase {
    var dir: String!
    override func setUp() { dir = AppTestFS.makeTempDir("ign") }
    override func tearDown() { AppTestFS.remove(dir) }
    func load() -> WorkspaceIgnore { WorkspaceIgnore.load(root: URL(fileURLWithPath: dir)) }

    // ignore.rs tests
    func testNodeModulesAndGitAlwaysIgnored() {
        let i = load()
        XCTAssertTrue(i.isIgnored(dir + "/node_modules", isDir: true))
        XCTAssertTrue(i.isIgnored(dir + "/node_modules/foo.md", isDir: false))
        XCTAssertTrue(i.isIgnored(dir + "/.git/HEAD", isDir: false))
    }

    func testBootstrapOnlySafetyNet() {
        AppTestFS.write(dir + "/.gitignore", "drafts/\n")
        let b = WorkspaceIgnore.bootstrap()
        XCTAssertTrue(b.isIgnored(dir + "/node_modules", isDir: true))
        XCTAssertTrue(b.isIgnored(dir + "/.git/HEAD", isDir: false))
        XCTAssertFalse(b.isIgnored(dir + "/drafts", isDir: true))
        XCTAssertFalse(b.isIgnored(dir + "/readme.md", isDir: false))
    }

    func testRootGitignore() {
        AppTestFS.write(dir + "/.gitignore", "dist/\n*.log\n")
        AppTestFS.write(dir + "/readme.md", "# Readme")
        let i = load()
        XCTAssertTrue(i.isIgnored(dir + "/dist", isDir: true))
        XCTAssertTrue(i.isIgnored(dir + "/dist/bundle.js", isDir: false))
        XCTAssertTrue(i.isIgnored(dir + "/error.log", isDir: false))
        XCTAssertFalse(i.isIgnored(dir + "/readme.md", isDir: false))
    }

    func testNestedStarStaysScoped() {
        AppTestFS.write(dir + "/.vite-hooks/_/.gitignore", "*\n")
        AppTestFS.write(dir + "/readme.md", "# Readme")
        AppTestFS.write(dir + "/docs/guide.md", "# Guide")
        AppTestFS.write(dir + "/.vite-hooks/_/hook.sh", "#!/bin/sh")
        let i = load()
        XCTAssertFalse(i.isIgnored(dir + "/readme.md", isDir: false))
        XCTAssertFalse(i.isIgnored(dir + "/docs", isDir: true))
        XCTAssertFalse(i.isIgnored(dir + "/docs/guide.md", isDir: false))
        XCTAssertTrue(i.isIgnored(dir + "/.vite-hooks/_/hook.sh", isDir: false))
    }

    func testNestedGitignore() {
        AppTestFS.write(dir + "/.gitignore", "# empty\n")
        AppTestFS.write(dir + "/docs/.gitignore", "drafts/\n")
        AppTestFS.write(dir + "/docs/drafts/wip.md", "# wip")
        AppTestFS.write(dir + "/docs/final.md", "# final")
        let i = load()
        XCTAssertTrue(i.isIgnored(dir + "/docs/drafts", isDir: true))
        XCTAssertTrue(i.isIgnored(dir + "/docs/drafts/wip.md", isDir: false))
        XCTAssertFalse(i.isIgnored(dir + "/docs/final.md", isDir: false))
    }

    func testGitignoreItselfVisibleAndUnignored() {
        AppTestFS.write(dir + "/.gitignore", "dist/\n")
        AppTestFS.write(dir + "/notes/hello.md", "# hi")
        let i = load()
        XCTAssertFalse(i.isIgnored(dir + "/.gitignore", isDir: false))
        XCTAssertFalse(i.isIgnored(dir + "/notes", isDir: true))
        XCTAssertFalse(i.isIgnored(dir + "/notes/hello.md", isDir: false))
    }

    func testIsGitignorePath() {
        XCTAssertTrue(WorkspaceIgnore.isGitignorePath("/a/b/.gitignore"))
        XCTAssertTrue(WorkspaceIgnore.isGitignorePath(".gitignore"))
        XCTAssertFalse(WorkspaceIgnore.isGitignorePath("/a/b/gitignore.txt"))
        XCTAssertFalse(WorkspaceIgnore.isGitignorePath("/a/b/.gitignore.bak"))
    }

    // Pattern semantics (gitignore + globset).
    func testPatternSemantics() {
        let g = Gitignore(root: "/r", content: ["# comment", "*.log", "!keep.log", "/anchored.md", "build/", "docs/**/tmp", "a/**", "**/deep.md", "\\#hash.md", "name\\ ", "foo[0-9].md", "[!x]y.md", "{one,two}.md"].joined(separator: "\n"))
        func m(_ p: String, _ d: Bool = false) -> IgnoreMatch { g.matchedPathOrAnyParents("/r/" + p, isDir: d) }
        XCTAssertEqual(m("x.log"), .ignore)
        XCTAssertEqual(m("sub/x.log"), .ignore)
        XCTAssertEqual(m("keep.log"), .whitelist)
        XCTAssertEqual(m("anchored.md"), .ignore)
        XCTAssertEqual(m("sub/anchored.md"), .none)
        XCTAssertEqual(m("build", true), .ignore)
        XCTAssertEqual(m("build"), .none, "dir-only pattern does not match a file")
        XCTAssertEqual(m("build/out.js"), .ignore, "parents are checked as directories")
        XCTAssertEqual(m("x/build/out.js"), .ignore)
        XCTAssertEqual(m("docs/tmp"), .ignore)
        XCTAssertEqual(m("docs/a/b/tmp"), .ignore)
        XCTAssertEqual(m("a", true), .none, "a/** matches inside, not the dir itself")
        XCTAssertEqual(m("a/x.md"), .ignore)
        XCTAssertEqual(m("deep.md"), .ignore)
        XCTAssertEqual(m("q/r/deep.md"), .ignore)
        XCTAssertEqual(m("#hash.md"), .ignore)
        XCTAssertEqual(m("name "), .ignore)
        XCTAssertEqual(m("foo7.md"), .ignore)
        XCTAssertEqual(m("fooa.md"), .none)
        XCTAssertEqual(m("ay.md"), .ignore)
        XCTAssertEqual(m("xy.md"), .none)
        XCTAssertEqual(m("one.md"), .ignore)
        XCTAssertEqual(m("two.md"), .ignore)
        XCTAssertEqual(m("three.md"), .none)
        XCTAssertEqual(m("plain.md"), .none)
    }

    func testStarDoesNotCrossSlash() {
        let g = Gitignore(root: "/r", content: "docs/*.md\n")
        XCTAssertEqual(g.matchedPathOrAnyParents("/r/docs/a.md", isDir: false), .ignore)
        XCTAssertEqual(g.matchedPathOrAnyParents("/r/docs/sub/a.md", isDir: false), .none)
    }

    func testDeeperScopeWinsIncludingWhitelist() {
        AppTestFS.write(dir + "/.gitignore", "*.md\n")
        AppTestFS.write(dir + "/keep/.gitignore", "!*.md\n")
        AppTestFS.write(dir + "/keep/a.md", "a")
        let i = load()
        XCTAssertTrue(i.isIgnored(dir + "/x.md", isDir: false))
        XCTAssertFalse(i.isIgnored(dir + "/keep/a.md", isDir: false))
    }

    func testIgnoredDirectoriesAreNotWalkedForRules() {
        AppTestFS.write(dir + "/.gitignore", "vendor/\n")
        AppTestFS.write(dir + "/vendor/.gitignore", "!important.md\n")
        let i = load()
        XCTAssertTrue(i.isIgnored(dir + "/vendor/important.md", isDir: false))
    }
}

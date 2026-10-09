import XCTest
@testable import FloCore

/// Folders and notes added outside the app (Finder) reach the index and the sidebar listing, even when
/// FSEvents coalesces a copy's create+modify into one event that reads as a plain modification.
final class ExternalAddTests: XCTestCase {
    func testFinderCopyIntoNewFolderIsIndexedAndListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flo-ext-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Projects/Alpha", withIntermediateDirectories: true)
        try "# a".write(toFile: root + "/Projects/Alpha/a.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let index = FileIndex(root: root)
        index.rebuild(extensions: .schemaDefault)
        let w = WorkspaceWatcherModel(root: root, extensions: .schemaDefault, index: index, startMs: 0)
        // Finder: a new folder, then notes and PDFs copied into it
        let dir = root + "/Projects/Alpha/Notes", pdfDir = root + "/Projects/Alpha/Attachments"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pdfDir, withIntermediateDirectories: true)
        try "# t".write(toFile: dir + "/t.md", atomically: true, encoding: .utf8)
        try Data("%PDF-1.4".utf8).write(to: URL(fileURLWithPath: pdfDir + "/doc.pdf"))
        var out = w.ingest(RawFSEvent(kind: .createdFolder, paths: [dir]), nowMs: 1000)
        out += w.tick(nowMs: 2000)
        out += w.ingest(RawFSEvent(kind: .modifiedData, paths: [dir + "/t.md", pdfDir, pdfDir + "/doc.pdf"]), nowMs: 3000)
        out += w.tick(nowMs: 4000)
        XCTAssertTrue(index.contains(dir + "/t.md"))
        XCTAssertTrue(index.contains(pdfDir + "/doc.pdf"), "PDFs are workspace files by default")
        XCTAssertTrue(index.dirsWithSupportedFiles.contains(dir))
        XCTAssertTrue(index.dirsWithSupportedFiles.contains(pdfDir))
        XCTAssertTrue(out.contains { if case .directoryChanged(dir, _) = $0 { return true }; return false }, "\(out)")
        XCTAssertTrue(out.contains { if case .directoryChanged(pdfDir, _) = $0 { return true }; return false }, "\(out)")
        let listing = try WorkspaceFS.readDirectory(root + "/Projects/Alpha", dirsWithSupportedFiles: index.dirsWithSupportedFiles)
        XCTAssertEqual(listing.filter { $0.isDir }.map { $0.name }, ["Attachments", "Notes"])
    }
}

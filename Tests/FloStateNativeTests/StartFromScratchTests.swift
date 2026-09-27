import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

@MainActor
final class StartFromScratchTests: XCTestCase {
    func testCreatesNotebookInDocumentsAndOpensWelcome() async throws {
        let f = ShellFixture()
        let docs = URL(fileURLWithPath: TFS.tempDir("docs"))
        f.model.documentsDirectory = { docs }
        f.model.startFromScratch()
        for _ in 0..<5 { await f.settle() }
        let root = WorkspaceFS.canonicalize(docs.appendingPathComponent("Notebook").path)
        XCTAssertEqual(f.model.root, root)
        XCTAssertEqual(f.model.editor.activeFilePath, root + "/Welcome.md")
        XCTAssertTrue(TFS.read(root + "/Welcome.md")?.hasPrefix("# Welcome to Flo State\n") == true)
        // a non-empty "Notebook" is never touched: the next one is "Notebook 2"
        XCTAssertEqual(StarterNotebook.folder(documents: docs).lastPathComponent, "Notebook 2")
        try? FileManager.default.removeItem(atPath: WorkspaceFS.canonicalize(docs.path))
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("Notebook"), withIntermediateDirectories: true)
        XCTAssertEqual(StarterNotebook.folder(documents: docs).lastPathComponent, "Notebook", "an empty folder is reused")
    }
}

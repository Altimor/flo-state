import XCTest
@testable import FloCore

final class ContentSearchTests: XCTestCase {
    func files(_ m: [String: String]) -> [IndexedFile] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return m.map { name, text in
            let p = dir.appendingPathComponent(name).path
            try! Data(text.utf8).write(to: URL(fileURLWithPath: p))
            return IndexedFile(path: p, relativePath: name, name: name, modifiedAt: 1)
        }
    }

    func testFindsLineOffsetsCaseAndAccentInsensitive() {
        let fs = files(["a.md": "# Title\n\nSome line\n  - Crème brûlée recipe\n", "b.md": "nothing here"])
        let hits = ContentSearch().search("creme BRULEE", in: fs)
        XCTAssertEqual(hits.count, 1)
        let h = hits[0]
        XCTAssertEqual(h.line, 4)
        let text = "# Title\n\nSome line\n  - Crème brûlée recipe\n" as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: h.offset, length: h.length)), "Crème brûlée")
        XCTAssertEqual(h.snippet, "- Crème brûlée recipe")
        let s = h.snippet as NSString
        XCTAssertEqual(s.substring(with: NSRange(location: h.highlights.first!, length: h.highlights.count)), "Crème brûlée")
    }

    func testOverridesBeatDiskAndShortQueriesReturnNothing() {
        let fs = files(["a.md": "old text"])
        let cs = ContentSearch()
        XCTAssertEqual(cs.search("x", in: fs), [])
        XCTAssertEqual(cs.search("unsaved", in: fs, overrides: [fs[0].path: "brand new unsaved words"]).count, 1)
        XCTAssertEqual(cs.search("old", in: fs, overrides: [fs[0].path: "brand new"]).count, 0)
    }

    func testRanksNoteNameThenHeadingsAndCapsPerFile() {
        let fs = files(["garden.md": "tomato\ntomato\ntomato\ntomato\n", "notes.md": "x\n# tomato plan\n", "tomato.md": "a tomato"])
        let hits = ContentSearch().search("tomato", in: fs)
        XCTAssertEqual(hits.first?.relativePath, "tomato.md")
        XCTAssertEqual(hits[1].relativePath, "notes.md")
        XCTAssertEqual(hits.filter { $0.relativePath == "garden.md" }.count, 3)
    }

    func testLongLineSnippetKeepsMatchVisible() {
        let line = String(repeating: "word ", count: 40) + "needle" + String(repeating: " tail", count: 60)
        let hits = ContentSearch().search("needle", in: files(["l.md": line]))
        let h = hits[0], s = h.snippet as NSString
        XCTAssertTrue(h.snippet.hasPrefix("…"))
        XCTAssertEqual(s.substring(with: NSRange(location: h.highlights[0], length: 6)), "needle")
        XCTAssertLessThan(s.length, 200)
    }
}

import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

/// Cmd-Shift-F: search inside notes, pick a hit, land on it with the match selected.
@MainActor
final class ContentSearchShellTests: XCTestCase {
    var wc: ShellWindowController!
    var f: ShellFixture!
    override func tearDown() async throws { wc?.window?.close(); wc = nil }

    func testSearchOpensNoteAndSelectsMatch() async throws {
        let body = (1...200).map { "line \($0) filler text" }.joined(separator: "\n") + "\nthe hidden treasure is here\n"
        f = ShellFixture(files: ["a.md": "alpha", "deep/b.md": body])
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.settle(); wc.flush()

        f.model.perform(.searchContents)
        XCTAssertEqual(f.model.palette?.intent, .fullText)
        f.model.setPaletteQuery("Hidden Treasure")
        let v = try XCTUnwrap(f.model.paletteView())
        XCTAssertEqual(v.items.count, 1)
        XCTAssertEqual(v.items[0].subtitle, "the hidden treasure is here")
        f.model.runSelectedPaletteItem()
        XCTAssertNil(f.model.palette)
        for _ in 0..<10 { await f.settle(); wc.flush(); wc.root.layoutSubtreeIfNeeded() }

        XCTAssertEqual(f.model.editor.activeFilePath, f.p("deep/b.md"))
        let c = try XCTUnwrap(wc.root.area.activeFilePane?.controller)
        let sel = c.state.selection.main
        XCTAssertEqual((c.text as NSString).substring(with: NSRange(location: sel.from, length: sel.to - sel.from)), "hidden treasure")
        XCTAssertTrue(wc.window?.firstResponder === c.textView)
        // the match is on screen
        let top = try XCTUnwrap(c.lineTop(forPosition: sel.from, in: wc.root.area.activeFilePane!))
        XCTAssertGreaterThan(top, 0); XCTAssertLessThan(top, wc.root.area.activeFilePane!.bounds.height)
    }

    func testUnsavedEditsAreSearched() async throws {
        f = ShellFixture(files: ["a.md": "alpha"])
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1200, height: 800), offscreen: true)
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("a.md"))
        await f.settle()
        f.model.editor.updateContent(f.p("a.md"), "alpha plus freshly typed words")
        f.model.perform(.searchContents)
        f.model.setPaletteQuery("freshly typed")
        XCTAssertEqual(f.model.paletteView()?.items.count, 1)
    }
}

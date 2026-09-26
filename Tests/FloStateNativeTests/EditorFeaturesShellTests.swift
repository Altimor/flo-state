import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

/// Find card, wiki autocomplete and paste hooks wired into the real shell (offscreen).
@MainActor
final class EditorFeaturesShellTests: XCTestCase {
    var wc: ShellWindowController!
    var f: ShellFixture!

    func make(_ files: [String: String]) async {
        f = ShellFixture(files: files, config: "editor.jump-to-bottom-after-minutes = 0\n")
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1400, height: 900), offscreen: true)
        await f.open()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        wc?.window?.close()
        wc = nil
    }

    func openTab(_ rel: String) async {
        try! await f.model.editor.openFileInTabOrFocus(f.p(rel))
        await f.settle()
        wc.flush(); wc.root.layoutSubtreeIfNeeded()
    }

    var area: EditorAreaView { wc.root.area }

    func testFindCardLivesInTheEditorAreaAndClosesOnTabSwitch() async {
        await make(["a.md": "alpha beta\nbeta", "b.md": "other"])
        await openTab("a.md")
        guard let c = area.activeFilePane?.controller else { return XCTFail("no editor") }
        wc.window!.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(NSRange(location: 6, length: 4))
        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: wc.window!.windowNumber,
                                  context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        XCTAssertTrue(wc.window!.performKeyEquivalent(with: ev))
        let o = area.findOverlay
        XCTAssertTrue(o.isOpen)
        XCTAssertTrue(o.superview === area)
        XCTAssertEqual(o.query, "beta")
        XCTAssertEqual(o.counterText, "1/2")
        XCTAssertEqual(area.bounds.width - o.frame.maxX, 12)
        XCTAssertEqual(area.bounds.height - o.frame.maxY, 8)
        XCTAssertEqual(o.frame.width, 560)
        // above the footer
        let idx = area.subviews.firstIndex { $0 === o }!, fidx = area.subviews.firstIndex { $0 === area.footer }!
        XCTAssertGreaterThan(idx, fidx)
        // styled from the app's theme
        XCTAssertEqual(c.features.chrome.tokens, ThemeTokens(settings: f.model.values, mode: f.model.mode))
        await openTab("b.md")
        XCTAssertFalse(o.isOpen, "search closes when its pane goes inactive")
    }

    func testWikiAutocompleteUsesTheWorkspaceIndex() async {
        await make(["a.md": "", "Projects/Roadmap.md": "x", "Roadmap.md": "y", "Other.md": "z"])
        await openTab("a.md")
        guard let c = area.activeFilePane?.controller else { return XCTFail("no editor") }
        wc.window!.makeFirstResponder(c.textView)
        for ch in "[[road" { c.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        c.features.runPendingQuery()
        let opts = c.features.completionOptions ?? []
        XCTAssertEqual(Set(opts.map { $0.completion.insert }), ["Projects/Roadmap", "Roadmap"], "ambiguous stems insert relative paths")
        XCTAssertEqual(Set(opts.map { $0.completion.detail ?? "" }), ["Projects", ""])
    }

    func testFrontmatterPasteGoesToTheStore() async {
        await make(["a.md": "body"])
        await openTab("a.md")
        guard let c = area.activeFilePane?.controller else { return XCTFail("no editor") }
        c.textView.setSelectedRange(NSRange(location: 4, length: 0))
        c.features.paste(PastePayload(plain: "---\ntitle: Pasted\n---\n more"))
        XCTAssertEqual(f.model.editor.file(f.p("a.md"))?.frontmatter, "title: Pasted")
        XCTAssertEqual(c.text, "body more")
        // second time: the file has frontmatter now, so it's pasted as text
        c.features.paste(PastePayload(plain: "---\na: 1\n---\n"))
        XCTAssertEqual(c.text, "body more---\na: 1\n---\n")
    }
}

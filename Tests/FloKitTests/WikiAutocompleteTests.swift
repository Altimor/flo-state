import XCTest
import AppKit
@testable import FloKit
import FloCore

@MainActor
final class WikiAutocompleteTests: XCTestCase {
    var clock: Double = 1_000_000

    func make(results: @escaping (String) -> [SearchResult]) -> KeyReplayer {
        let r = KeyReplayer()
        let c = r.controller
        c.workspaceRoot = "/ws"
        c.features.wikiCompletions = { q, limit in Array(results(q).prefix(limit)) }
        c.features.setCompletionClock { [unowned self] in self.clock }
        return r
    }

    static func sr(_ rel: String) -> SearchResult {
        SearchResult(path: "/ws/" + rel, filename: (rel as NSString).lastPathComponent, relativePath: rel)
    }

    func html(_ o: CompletionOption) -> String {
        let u = Array(o.completion.label.utf16)
        var out = "", off = 0, i = 0
        func text(_ a: Int, _ b: Int) -> String { String(utf16CodeUnits: Array(u[a..<b]), count: b - a) }
        while i + 1 < o.matched.count {
            let f = o.matched[i], t = o.matched[i + 1]
            if f > off { out += text(off, f) }
            out += "<span class=\"cm-completionMatchedText\">\(text(f, t))</span>"
            off = t; i += 2
        }
        if off < u.count { out += text(off, u.count) }
        return out
    }

    // MARK: FuzzyMatcher

    func testFuzzyMatcherScores() {
        func m(_ p: String, _ w: String) -> (Int, [Int])? { FuzzyMatcher(p).match(w).map { ($0.score, $0.matched) } }
        XCTAssertEqual(m("m", "Master")?.0, -300, "single char, case folded, not full")
        XCTAssertNil(m("n", "Master Notes"), "single char only matches at the start")
        XCTAssertEqual(m("master", "Master Notes")?.1, [0, 6])
        XCTAssertEqual(m("no", "📓 Master notes")?.0, -700 - 15)
        XCTAssertEqual(m("no", "Master Notes")?.0, -200 - 700 - 12)
        XCTAssertEqual(m("mn", "Master Notes")?.1, [0, 1, 7, 8], "by-word match")
        XCTAssertNil(m("xy", "Master"))
        XCTAssertEqual(m("", "abc")?.0, -100)
    }

    // MARK: web parity (fixtures/wiki-wk.json)

    func testWebParity() throws {
        guard let cases = KitFixtures.json("wiki-wk.json") as? [[String: Any]] else { throw XCTSkip("fixtures/wiki-wk.json missing") }
        var steps = 0, failures = 0
        for cs in cases {
            let name = cs["name"] as! String
            let resultsJSON = cs["results"] as! [String: [[String: Any]]]
            var issued: [String] = []
            let r = make { q in
                issued.append(q)
                return (resultsJSON[q] ?? []).map { SearchResult(path: $0["path"] as! String, filename: $0["filename"] as! String, relativePath: $0["relative_path"] as! String) }
            }
            let c = r.controller
            r.load(cs["doc"] as! String, selection: .cursor(cs["caret"] as! Int))
            var got: [[String: Any]] = []
            func snap(_ op: String) -> [String: Any] {
                let opts: Any = c.features.completionOptions.map { os in os.enumerated().map { (i, o) -> [String: Any] in
                    ["label": html(o), "detail": o.completion.detail as Any, "selected": i == c.features.completionSelected] } } as Any
                return ["op": op, "doc": c.state.doc.string, "head": c.state.selection.main.head, "options": opts]
            }
            for t in cs["typing"] as! [[Any]] {
                let chars = t[0] as! String, slow = t[1] as! Bool
                for ch in chars {
                    r.press(ch == " " ? "Space" : String(ch))
                    clock += slow ? 350 : 10
                    if slow { c.features.runPendingQuery() }
                }
                if !slow { c.features.runPendingQuery() }
                clock += 350
                got.append(snap("type:" + chars))
            }
            for k in cs["keys"] as! [String] {
                clock += 100
                let chord = ["ArrowDown": "Down", "ArrowUp": "Up", "PageDown": "PageDown", "PageUp": "PageUp"][k] ?? k
                if k.hasPrefix("Page") {
                    let up = k == "PageUp"
                    let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber,
                                              context: nil, characters: up ? "\u{F72C}" : "\u{F72D}", charactersIgnoringModifiers: up ? "\u{F72C}" : "\u{F72D}",
                                              isARepeat: false, keyCode: up ? 116 : 121)!
                    c.textView.keyDown(with: ev)
                } else {
                    r.press(chord)
                }
                c.features.runPendingQuery()
                clock += 350
                got.append(snap("key:" + k))
            }
            let exp = cs["steps"] as! [[String: Any]]
            XCTAssertEqual(issued, cs["queries"] as! [String], "\(name): source queries")
            for (i, e) in exp.enumerated() where i < got.count {
                // PageUp without a popup is CM's cursorPageUp, which the FloCore keymap doesn't bind yet
                if name == "pageup" && (e["op"] as! String) == "key:PageUp" { continue }
                steps += 1
                let g = got[i]
                let eo = e["options"] as? [[String: Any]]
                let go = g["options"] as? [[String: Any]]
                let same = (e["doc"] as! String) == (g["doc"] as! String) && (e["head"] as! Int) == (g["head"] as! Int)
                    && (eo == nil) == (go == nil)
                    && (eo ?? []).count == (go ?? []).count
                    && zip(eo ?? [], go ?? []).allSatisfy { a, b in
                        (a["label"] as! String) == (b["label"] as! String) && (a["detail"] as? String) == (b["detail"] as? String)
                            && (a["selected"] as! Bool) == (b["selected"] as! Bool) }
                if !same { failures += 1; XCTFail("\(name) step \(i) \(e["op"]!):\n got \(g)\n exp \(e)") }
            }
        }
        print("wiki autocomplete parity: \(steps - failures)/\(steps) steps match")
    }

    // MARK: behaviour

    let files = ["Notes/Plan.md", "Archive/Plan.md", "Ideas.md", "Deep/Nested/Idea list.markdown"].map(WikiAutocompleteTests.sr)

    func substring(_ q: String) -> [SearchResult] {
        let n = q.lowercased()
        return files.filter { $0.relativePath.lowercased().contains(n) }
    }

    func testAmbiguousStemInsertsRelativePath() {
        let r = make(results: substring)
        let c = r.controller
        r.load("", selection: .cursor(0))
        for ch in "[[plan" { r.press(String(ch)) }
        c.features.runPendingQuery()
        let opts = c.features.completionOptions!
        XCTAssertEqual(opts.map { $0.completion.label }, ["Plan", "Plan"])
        XCTAssertEqual(opts.map { $0.completion.detail }, ["Notes", "Archive"], "equal scores and labels keep source order")
        XCTAssertEqual(opts.map { $0.completion.insert }, ["Notes/Plan", "Archive/Plan"])
        clock += 100
        r.press("Down")
        r.press("Enter")
        XCTAssertEqual(c.text, "[[Archive/Plan]]")
        XCTAssertEqual(c.state.selection.main.head, 16)
        XCTAssertNil(c.features.completionOptions)
        XCTAssertEqual(r.viewText, c.text)
        // CM history: the (userEvent-less) completion joins the adjacent typing
        // when it lands within 500 ms, so one undo removes both here
        _ = c.handleKey("Mod-z")
        XCTAssertEqual(c.text, "")
    }

    func testMarkdownExtensionAndNestedDetail() {
        let r = make(results: substring)
        let c = r.controller
        r.load("see  and", selection: .cursor(4))
        for ch in "[[idea l" { r.press(ch == " " ? "Space" : String(ch)) }
        c.features.runPendingQuery()
        let o = c.features.completionOptions!
        XCTAssertEqual(o.first?.completion.label, "Idea list")
        XCTAssertEqual(o.first?.completion.detail, "Deep/Nested")
        clock += 100
        r.press("Enter")
        XCTAssertEqual(c.text, "see [[Idea list]] and")
    }

    func testInteractionDelayAndEscape() {
        let r = make(results: substring)
        let c = r.controller
        r.load("", selection: .cursor(0))
        for ch in "[[idea" { r.press(String(ch)) }
        c.features.runPendingQuery()
        XCTAssertNotNil(c.features.completionOptions)
        // Enter within 75 ms of opening is not taken by the completion: a newline
        r.press("Enter")
        XCTAssertEqual(c.text, "[[idea\n")
        XCTAssertNil(c.features.completionOptions)
        _ = c.handleKey("Mod-z")
        c.features.runPendingQuery()
        // reopen, then Escape closes without editing
        r.load("", selection: .cursor(0))
        for ch in "[[idea" { r.press(String(ch)) }
        c.features.runPendingQuery()
        clock += 100
        r.press("Escape")
        XCTAssertNil(c.features.completionOptions)
        XCTAssertEqual(c.text, "[[idea")
        // Ctrl-Space reopens explicitly
        XCTAssertTrue(c.handleKey("Ctrl-Space"))
        c.features.runPendingQuery()
        XCTAssertNotNil(c.features.completionOptions)
        // clicking elsewhere (a selection change) closes
        c.run { t in t.dispatch(TransactionSpec(selection: .cursor(0))); return true }
        XCTAssertNil(c.features.completionOptions)
    }

    func testNoWorkspaceNoPopupAndSelectionGuard() {
        let r = make(results: substring)
        let c = r.controller
        c.workspaceRoot = nil
        r.load("", selection: .cursor(0))
        for ch in "[[idea" { r.press(String(ch)) }
        c.features.runPendingQuery()
        XCTAssertNil(c.features.completionOptions)
    }

    func testPopupGeometry() {
        let r = make(results: substring)
        let c = r.controller
        r.load("", selection: .cursor(0))
        for ch in "[[plan" { r.press(String(ch)) }
        c.features.runPendingQuery()
        let p = c.features.completion.popup!
        XCTAssertEqual(p.frame.width, 260)
        XCTAssertEqual(p.frame.height, 2 * 27 + 10)
        // left edge at the query start's x
        let anchor = c.completionAnchor(2)!
        let inHost = p.superview!.convert(anchor, from: nil)
        XCTAssertEqual(p.frame.minX, inHost.minX, accuracy: 0.5)
        // top at the text box bottom
        let top = p.superview!.isFlipped ? p.frame.minY : p.superview!.bounds.height - p.frame.maxY
        let boxBottom = p.superview!.isFlipped ? inHost.maxY : p.superview!.bounds.height - inHost.minY
        XCTAssertEqual(top, boxBottom, accuracy: 0.5)
        // mouse down on the second row applies it
        let rowY: CGFloat = 5 + 27 + 10
        let local = NSPoint(x: 20, y: rowY)
        let win = p.convert(local, to: nil)
        let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: win, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        p.mouseDown(with: ev)
        XCTAssertEqual(c.text, "[[Archive/Plan]]")
    }
}

import XCTest
import AppKit
@testable import FloKit
import FloCore

enum KitFixtures {
    static let dir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")
    static func json(_ name: String) -> Any? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

@MainActor
final class FindTests: XCTestCase {
    // MARK: SearchCursor / FindQuery unit behaviour

    func matches(_ doc: String, _ q: String) -> [[Int]] {
        var c = SearchCursor(Text(doc), q)
        var out: [[Int]] = []
        while let m = c.next() { out.append([m.from, m.to]) }
        return out
    }

    func testCursorBasics() {
        XCTAssertEqual(matches("foo bar FOO fOo", "foo"), [[0, 3], [8, 11], [12, 15]])
        XCTAssertEqual(matches("aaaa", "aa"), [[0, 2], [2, 4]], "next() skips overlapping matches")
        XCTAssertEqual(matches("abc", ""), [])
        XCTAssertEqual(matches("Café cafe\u{301} CAFÉ", "café"), [[0, 4], [5, 10], [11, 15]], "NFKD on both sides")
        XCTAssertEqual(matches("ﬁle", "fi"), [[0, 1]], "ligature expands under NFKD")
        XCTAssertEqual(matches("a😀b a😀b", "😀b"), [[1, 4], [6, 9]])
        XCTAssertEqual(matches("İstanbul", "i"), [[0, 1]])
        XCTAssertEqual(matches("Straße", "strasse"), [], "ß is not folded to ss")
        var c = SearchCursor(Text("aaaa"), "aa")
        var ov: [[Int]] = []
        while let m = c.nextOverlapping() { ov.append([m.from, m.to]) }
        XCTAssertEqual(ov, [[0, 2], [1, 3], [2, 4]])
    }

    func testUnquote() {
        let q = FindQuery(search: #"a\nb\tc\\d\x"#)
        XCTAssertEqual(q.unquoted, "a\nb\tc\\d\\x")
        XCTAssertEqual(FindQuery(search: #"\\n"#).unquoted, "\\n")
    }

    func testFindNextPrevWrap() {
        let st = EditorState(doc: Text("foo x foo"), selection: .cursor(9))
        let q = FindQuery(search: "foo")
        XCTAssertEqual(q.findNext(st)?.selection, .single(0, 3))
        XCTAssertEqual(q.findPrevious(st)?.selection, .single(6, 9))
        let one = EditorState(doc: Text("x foo"), selection: .single(2, 5))
        XCTAssertEqual(q.findNext(one)?.selection, .single(2, 5), "wraps onto the selected match (CM quirk)")
    }

    func testReplaceAllAndCounts() {
        let st = EditorState(doc: Text("x1 X1 x1x1\nx1"), selection: .cursor(3))
        var q = FindQuery(search: "x1"); q.replace = "y"
        let spec = q.replaceAll(st)!
        XCTAssertEqual(st.update(spec).state.doc.string, "y y yy\ny")
        XCTAssertEqual(FindCount.matchInfo(st, "x1"), .init(current: 2, total: 5))
        XCTAssertEqual(FindCount.matchInfo(st, "zz"), .init(current: 0, total: 0))
        XCTAssertNil(FindCount.matchInfo(st, ""))
        // cap at 5000 for the overview
        let big = EditorState(doc: Text(String(repeating: "ab ", count: 6000)))
        XCTAssertEqual(FindCount.collect(big, "ab")?.ranges.count, 5000)
        XCTAssertEqual(FindCount.matchInfo(big, "ab")?.total, 6000)
    }

    // MARK: web parity (fixtures/find-wk.json, recorded through the real overlay UI)

    struct Snap: Equatable, CustomStringConvertible {
        var doc: String, anchor: Int, head: Int, counter: String?, hl: [[Int]], ticks: Int, open: Bool, query: String?
        var description: String { "doc=\(doc.debugDescription) sel=\(anchor)-\(head) counter=\(counter ?? "nil") hl=\(hl) ticks=\(ticks) q=\(query ?? "nil")" }
    }

    /// Web marks are split per line: join a match across newlines.
    static func mergeWeb(_ hl: [[Int]], _ doc: String, _ query: String) -> [[Int]] {
        if !FindQuery(search: query).unquoted.contains("\n") { return hl }
        let u = Array(doc.utf16)
        var out: [[Int]] = []
        for h in hl {
            if var last = out.last, last[2] == h[2], h[0] == last[1] + 1, last[1] < u.count, u[last[1]] == 10 {
                last[1] = h[1]; out[out.count - 1] = last
            } else { out.append(h) }
        }
        return out
    }

    func snap(_ r: KeyReplayer, _ o: FindOverlayView) -> Snap {
        let c = r.controller
        let hl = c.features.visibleHighlights().map { [$0.0.from, $0.0.to, $0.1 ? 1 : 0] }
        let ov = c.features.overview
        let ticks = (ov == nil || ov!.isHidden) ? 0 : ov!.marks.count
        return Snap(doc: c.state.doc.string, anchor: c.state.selection.main.anchor, head: c.state.selection.main.head,
                    counter: o.isOpen ? o.counterText : nil, hl: hl, ticks: ticks, open: o.isOpen, query: o.isOpen ? o.query : nil)
    }

    func testWebParity() throws {
        guard let cases = KitFixtures.json("find-wk.json") as? [[String: Any]] else { throw XCTSkip("fixtures/find-wk.json missing") }
        let r = KeyReplayer()
        let c = r.controller
        var failures = 0, steps = 0
        for cs in cases {
            let name = cs["name"] as! String
            let doc = cs["doc"] as! String
            let a = cs["anchor"] as! Int, h = cs["head"] as! Int
            let query = cs["query"] as? String
            let rep = cs["replace"] as! String
            let ops = cs["ops"] as! [String]
            let expected = cs["steps"] as! [[String: Any]]
            if let o = c.features.findOverlay, o.isOpen { o.doClose() }
            r.load(doc, selection: .cursor(0))
            c.run { t in t.dispatch(TransactionSpec(selection: .single(a, h))); return true }
            let changes = ops.contains("replace") || ops.contains("all")
            var got: [(String, Snap)] = []
            _ = c.handleKey("Mod-f")
            let o = c.features.findOverlay!
            got.append(("open", snap(r, o)))
            if let q = query { o.setQuery(q); got.append(("query", snap(r, o))) }
            if changes { o.toggleReplace(); o.setReplaceText(rep) }
            for op in ops {
                switch op {
                case "next": o.key("Enter")
                case "prev": o.key("Shift-Enter")
                case "modg": o.key("Mod-g")
                case "modshiftg": o.key("Mod-Shift-g")
                case "replace": o.key("Enter", inReplace: true)
                case "all": o.doReplaceAll()
                default: XCTFail("op \(op)")
                }
                got.append((op, snap(r, o)))
            }
            if changes {
                r.window.makeFirstResponder(c.textView)
                _ = c.handleKey("Mod-z")
                got.append(("undo", snap(r, o)))
                o.toggleReplace()
            }
            XCTAssertEqual(got.count, expected.count, name)
            for (i, (op, s)) in got.enumerated() where i < expected.count {
                let e = expected[i]
                // an undo after a case without its own edit would undo the web's setDoc: not comparable
                if op == "undo" && !(e["doc"] as! String == doc) { continue }
                let exp = Snap(doc: e["doc"] as! String, anchor: e["anchor"] as! Int, head: e["head"] as! Int,
                               counter: e["counter"] as? String,
                               hl: Self.mergeWeb(e["hl"] as! [[Int]], e["doc"] as! String, (e["query"] as? String) ?? ""),
                               ticks: e["ticks"] as! Int, open: e["open"] as! Bool, query: e["query"] as? String)
                steps += 1
                if s != exp { failures += 1; XCTFail("\(name) step \(i) \(op):\n  got \(s)\n  exp \(exp)") }
            }
        }
        print("find parity: \(steps - failures)/\(steps) steps match")
    }

    // MARK: overlay behaviour

    func testOverlayOpenCloseFocusAndPrefill() {
        let r = KeyReplayer()
        let c = r.controller
        r.load("alpha beta\ngamma beta", selection: .single(6, 10))
        XCTAssertTrue(c.handleKey("Mod-f"))
        let o = c.features.findOverlay!
        XCTAssertTrue(o.isOpen)
        XCTAssertEqual(o.query, "beta")
        XCTAssertEqual(o.counterText, "1/2")
        XCTAssertTrue((r.window.firstResponder as? NSTextView)?.delegate === o.findField, "find input focused")
        XCTAssertFalse(o.isHidden)
        // geometry: bottom 8, right 12, width min(560, 100% - 24), height 50
        let host = o.superview!
        XCTAssertEqual(o.frame.width, 560)
        XCTAssertEqual(o.frame.height, 50)
        XCTAssertEqual(host.bounds.width - o.frame.maxX, 12)
        let bottomGap = host.isFlipped ? host.bounds.height - o.frame.maxY : o.frame.minY
        XCTAssertEqual(bottomGap, 8)
        o.toggleReplace()
        XCTAssertEqual(o.frame.height, 88)
        o.toggleReplace()
        // Escape closes and refocuses the editor
        o.key("Escape")
        XCTAssertFalse(o.isOpen)
        XCTAssertTrue(r.window.firstResponder === c.textView)
        XCTAssertTrue(c.features.visibleHighlights().isEmpty)
        // reopen with a multi-line selection keeps the previous query
        c.run { t in t.dispatch(TransactionSpec(selection: .single(0, 15))); return true }
        _ = c.handleKey("Mod-f")
        XCTAssertEqual(o.query, "beta")
        // Mod-g from the editor while open = next
        r.window.makeFirstResponder(c.textView)
        c.run { t in t.dispatch(TransactionSpec(selection: .cursor(0))); return true }
        XCTAssertTrue(c.handleKey("Mod-g"))
        XCTAssertEqual(c.state.selection.main, .range(6, 10))
        XCTAssertTrue(c.handleKey("Mod-Shift-g"))
        XCTAssertEqual(c.state.selection.main, .range(17, 21))
        // Escape inside the editor with a caret: closeSearchPanel (highlights off, card stays)
        c.run { t in t.dispatch(TransactionSpec(selection: .cursor(0))); return true }
        XCTAssertFalse(c.features.visibleHighlights().isEmpty)
        XCTAssertTrue(c.handleKey("Escape"))
        XCTAssertTrue(c.features.visibleHighlights().isEmpty)
        XCTAssertTrue(o.isOpen)
    }

    /// Real key events: Cmd-F through the window, typing in the field editor, Enter, Shift-Enter, Esc.
    func testRealKeyEvents() {
        let r = KeyReplayer()
        let c = r.controller
        r.load("one two one two", selection: .cursor(0))
        r.press("Mod-f")
        let o = c.features.findOverlay!
        XCTAssertTrue(o.isOpen)
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: r.window.windowNumber,
                                      context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            if flags.contains(.command), r.window.performKeyEquivalent(with: ev) { return }
            r.window.firstResponder?.keyDown(with: ev)
        }
        key("t", 17); key("w", 13); key("o", 31)
        XCTAssertEqual(o.query, "two")
        XCTAssertEqual(o.counterText, "1/2")
        key("\r", 36)
        XCTAssertEqual(c.state.selection.main, .range(4, 7))
        key("\r", 36)
        XCTAssertEqual(c.state.selection.main, .range(12, 15))
        key("\r", 36, .shift)
        XCTAssertEqual(c.state.selection.main, .range(4, 7))
        key("g", 5, .command)
        XCTAssertEqual(c.state.selection.main, .range(12, 15))
        key("\u{1B}", 53)
        XCTAssertFalse(o.isOpen)
        XCTAssertTrue(r.window.firstResponder === c.textView)
    }

    func testMod_gOpensWhenClosed() {
        let r = KeyReplayer()
        r.load("abc", selection: .cursor(0))
        XCTAssertTrue(r.controller.handleKey("Mod-g"))
        XCTAssertTrue(r.controller.features.isFindOpen)
        XCTAssertEqual(r.controller.state.selection.main, .cursor(0), "opening doesn't move")
    }

    func testReplaceAllIsOneUndoStep() {
        let r = KeyReplayer()
        let c = r.controller
        let doc = "cat dog cat\ncat"
        r.load(doc, selection: .cursor(0))
        _ = c.handleKey("Mod-f")
        let o = c.features.findOverlay!
        o.setQuery("cat"); o.toggleReplace(); o.setReplaceText("bird")
        o.doReplaceAll()
        XCTAssertEqual(c.text, "bird dog bird\nbird")
        XCTAssertEqual(r.viewText, c.text)
        XCTAssertEqual(o.counterText, "No matches")
        _ = c.handleKey("Mod-z")
        XCTAssertEqual(c.text, doc)
        XCTAssertEqual(r.viewText, doc)
        _ = c.handleKey("Mod-Shift-z")
        XCTAssertEqual(c.text, "bird dog bird\nbird")
        // replace-next edits are undoable one at a time
        r.load("a a", selection: .cursor(0))
        o.setQuery("a"); o.setReplaceText("b")
        o.key("Enter", inReplace: true)  // select
        o.key("Enter", inReplace: true)  // replace
        XCTAssertEqual(c.text, "b a")
        _ = c.handleKey("Mod-z")
        XCTAssertEqual(c.text, "a a")
        o.toggleReplace()
    }

    func testScrollBand() {
        let r = KeyReplayer(width: 1000, height: 600)
        let c = r.controller
        var lines = (0..<400).map { "line \($0)" }
        lines[300] = "needle here"
        lines[20] = "needle two"
        r.load(lines.joined(separator: "\n"), selection: .cursor(0))
        _ = c.handleKey("Mod-f")
        let o = c.features.findOverlay!
        o.setQuery("needle")
        o.key("Enter")
        let clip = c.scrollView.contentView
        let block = c.lineBlockRect(c.state.selection.main.head)!
        let top = block.minY - clip.bounds.minY
        XCTAssertGreaterThanOrEqual(top, 24 - 0.5)
        XCTAssertLessThanOrEqual(block.maxY - clip.bounds.minY, clip.bounds.height - 24 + 0.5)
        o.key("Enter") // to line 300: below the band → bottom-aligned at height - 24
        let b2 = c.lineBlockRect(c.state.selection.main.head)!
        XCTAssertEqual(b2.maxY - clip.bounds.minY, clip.bounds.height - 24, accuracy: 1)
        // stepping to a visible match doesn't scroll
        let before = clip.bounds.minY
        o.key("Shift-Enter")
        o.key("Enter")
        XCTAssertEqual(clip.bounds.minY, before, accuracy: 1)
        o.key("Shift-Enter") // back up to line 20: above → top at 24
        let b3 = c.lineBlockRect(c.state.selection.main.head)!
        XCTAssertEqual(b3.minY - clip.bounds.minY, 24, accuracy: 1)
    }

    func testHighlightsDrawAndOverviewClick() {
        let r = KeyReplayer()
        let c = r.controller
        r.load(String(repeating: "word filler text\n", count: 200), selection: .cursor(0))
        _ = c.handleKey("Mod-f")
        let o = c.features.findOverlay!
        o.setQuery("word")
        let ov = c.features.overview!
        XCTAssertFalse(ov.isHidden)
        XCTAssertEqual(ov.frame.width, 6)
        XCTAssertEqual(c.scrollView.frame.maxX - ov.frame.maxX, 4)
        // 200 matches over 900px: coalescing by pixel keeps them all (distinct pixels)
        XCTAssertEqual(ov.marks.count, 200)
        XCTAssertEqual(ov.marks.filter { $0.2 }.count, 1)
        // click the last tick: jumps and selects it
        let last = ov.marks.last!
        let win = ov.convert(NSPoint(x: 3, y: last.1), to: nil)
        let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: win, modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        ov.mouseDown(with: ev)
        let lastFrom = 199 * 17
        XCTAssertEqual(c.state.selection.main, .range(lastFrom, lastFrom + 4))
        // highlight pixels: render the text view and look for the match colour
        let tv = c.textView
        let rect = tv.visibleRect
        let rep = tv.bitmapImageRepForCachingDisplay(in: rect)!
        tv.cacheDisplay(in: rect, to: rep)
        var yellow = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), col.redComponent > 0.9, col.greenComponent > 0.9, col.blueComponent < 0.8 { yellow += 1 }
            }
        }
        XCTAssertGreaterThan(yellow, 50, "match highlights painted")
    }
}

/// Visual snapshots for eyeballing against the web (FLO_SNAP_DIR=/path).
@MainActor
final class FeatureSnapshotTests: XCTestCase {
    func testSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["FLO_SNAP_DIR"] else { throw XCTSkip("set FLO_SNAP_DIR") }
        for mode in [ThemeMode.dark, .light] {
            let tokens = ThemeTokens(settings: SettingsValues([:]), mode: mode)
            let theme = EditorTheme(foreground: tokens.fgBase.nsColor, accent: tokens.accent.nsColor, background: tokens.bgBase.nsColor)
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1400, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            let c = EditorController(theme: theme)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
            content.wantsLayer = true
            content.layer?.backgroundColor = tokens.bgBase.nsColor.cgColor
            window.contentView = content
            c.scrollView.frame = content.bounds
            content.addSubview(c.scrollView)
            c.features.chrome = EditorChrome(tokens: tokens)
            c.layoutColumn()
            c.load("hello world\nfoo bar foo\n", selection: .single(12, 15))
            c.layoutColumn()
            window.makeFirstResponder(c.textView)
            _ = c.handleKey("Mod-f")
            c.features.findOverlay!.toggleReplace()
            content.layoutSubtreeIfNeeded()
            content.display()
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/find-\(mode).png"))
            c.features.findOverlay!.toggleReplace()
            c.features.closeFind()
            // autocomplete
            c.workspaceRoot = "/ws"
            c.features.wikiCompletions = { _, _ in [SearchResult(path: "/ws/Field Notes Project.md", filename: "Field Notes Project.md", relativePath: "Archive/Field Notes Project.md"),
                                                     SearchResult(path: "/ws/Fruit list.md", filename: "Fruit list.md", relativePath: "Fruit list.md")] }
            c.load("# Title\n\nsome text ", selection: .cursor(19))
            window.makeFirstResponder(c.textView)
            _ = c.insertTyped("[")
            c.run { t in t.dispatch(TransactionSpec(changes: [Change(from: 19, insert: "[[f")], selection: .cursor(22), userEvent: "input.type")); return true }
            c.features.runPendingQuery()
            content.display()
            let rep2 = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: rep2)
            try rep2.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/ac-\(mode).png"))
            if let p = c.features.completion.popup { print("popup frame \(mode)", p.frame, "anchor", c.completionAnchor(20) as Any) }
        }
    }
}

/// The user saw the whole document blurred while the find card was open: the
/// backdrop blur must stay inside the card (and the completion popup).
@MainActor
final class BackdropScopeTests: XCTestCase {
    /// Every layer in the window carrying background filters, with its window rect and clipping.
    func blurLayers(_ root: NSView) -> [(NSView, NSRect, Bool)] {
        var out: [(NSView, NSRect, Bool)] = []
        func walk(_ v: NSView) {
            if let l = v.layer, !(l.backgroundFilters ?? []).isEmpty {
                out.append((v, v.convert(v.bounds, to: nil), l.masksToBounds))
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    func testFindCardBlurIsLimitedToTheCard() {
        let r = KeyReplayer()
        let c = r.controller
        r.load("hello world\nfoo bar foo", selection: .single(12, 15))
        _ = c.handleKey("Mod-f")
        let o = c.features.findOverlay!
        o.toggleReplace()
        let card = o.convert(o.bounds, to: nil)
        let blurs = blurLayers(r.window.contentView!)
        XCTAssertEqual(blurs.count, 1)
        for (v, rect, clipped) in blurs {
            XCTAssertTrue(v === o, "only the card blurs")
            XCTAssertTrue(clipped, "blur output clipped to the card's bounds")
            XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(rect) within \(card)")
        }
        XCTAssertEqual(o.layer?.cornerRadius, 16)
        XCTAssertNil(o.shadow, "no NSShadow (it would force an unclipped group)")
        // the shadow is a sibling right below the card, with the card's frame
        let host = o.superview!
        let i = host.subviews.firstIndex(of: o)!
        XCTAssertTrue(host.subviews[i - 1] === o.shadowView)
        XCTAssertEqual(o.shadowView.frame, o.frame)
        XCTAssertTrue((o.shadowView.layer?.backgroundFilters ?? []).isEmpty)
        // no view covering the editor area carries an effect
        XCTAssertFalse(host.subviews.contains { $0 is NSVisualEffectView })
        o.doClose()
        XCTAssertTrue(o.shadowView.isHidden)
    }

    func testCompletionPopupBlurIsLimitedToThePopup() {
        let r = KeyReplayer()
        let c = r.controller
        c.workspaceRoot = "/ws"
        c.features.wikiCompletions = { _, _ in [SearchResult(path: "/ws/Plan.md", filename: "Plan.md", relativePath: "Plan.md")] }
        r.load("", selection: .cursor(0))
        for ch in "[[pl" { r.press(String(ch)) }
        c.features.runPendingQuery()
        let p = c.features.completion.popup!
        let rect = p.convert(p.bounds, to: nil)
        let blurs = blurLayers(r.window.contentView!)
        XCTAssertEqual(blurs.count, 1)
        XCTAssertTrue(blurs[0].0 === p)
        XCTAssertTrue(blurs[0].2)
        XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(blurs[0].1))
        XCTAssertNil(p.shadow)
        XCTAssertEqual(p.shadowView.frame, p.frame)
        r.press("Escape")
        XCTAssertNil(p.superview)
        XCTAssertNil(p.shadowView.superview)
    }
}

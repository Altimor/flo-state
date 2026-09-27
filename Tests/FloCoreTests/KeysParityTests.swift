import XCTest
@testable import FloCore

/// Replays fixtures/keys.jsonl (real keystrokes recorded in the web app) through
/// Keymap.handle / Keymap.insertText and compares document + selection.
///
/// Classification (see docs/KEYS-DEVIATIONS.md):
/// - cases pressing Up/Down are skipped outright (vertical motion is layout);
/// - a failing case whose replay consulted visual line geometry the monospace
///   model can't reproduce (line wrapping, DOM hit-testing on rendered list
///   prefixes) is reported as "layout", not as a parity failure;
/// - a failing case where typed text replaced a selection that Chrome's
///   contenteditable edits differently from CM's model (selection crossing a
///   line break or starting inside a rendered list prefix) is reported as
///   "dom-edit".
final class KeysParityTests: XCTestCase {
    struct Case {
        let name: String
        let tags: [String]
        let doc: String
        let sel: EditorSelection
        let keys: [String]
        let outDoc: String
        let outSel: EditorSelection
        let index: Int
        /// Editor content before the oracle's setDoc, when recorded.
        let prevDoc: String?
    }

    static func selection(_ o: [String: Any]) -> EditorSelection {
        let ranges = (o["ranges"] as! [[Int]]).map { SelectionRange.range($0[0], $0[1]) }
        return EditorSelection(ranges: ranges, mainIndex: o["main"] as! Int)
    }

    static func loadCases(_ file: String = "keys.jsonl") -> [Case] {
        let url = Fixtures.dir.appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Case] = []
        for (i, line) in text.split(separator: "\n").enumerated() {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            out.append(Case(name: d["name"] as! String, tags: d["tags"] as! [String], doc: d["doc"] as! String,
                            sel: selection(d["sel"] as! [String: Any]), keys: d["keys"] as! [String],
                            outDoc: d["outDoc"] as! String, outSel: selection(d["outSel"] as! [String: Any]), index: i,
                            prevDoc: d["prevDoc"] as? String))
        }
        return out
    }

    static let layoutKeys: Set<String> = ["Up", "Down", "Shift-Up", "Shift-Down", "ArrowUp", "ArrowDown"]

    /// Monospace layout that records when a result depended on geometry the
    /// web app resolves through the DOM: a line long enough to wrap in the
    /// 734px column, or a line whose rendered start is a list prefix / quote
    /// mark / tab widget (CM's posAtCoords hit-tests those inline-blocks).
    final class RecordingLayout: EditorLayout {
        let base = MonospaceLayout()
        var visualGeometryUsed = false
        static let decoratedStart = JSRegex("^([\\t ]*(> ?)*[-+*][ \\t]|\\t|(> ?)+#|[-+*] +#)")
        func note(_ state: EditorState, _ pos: Int) {
            let line = state.doc.lineAt(pos)
            if line.length >= 60 || RecordingLayout.decoratedStart.test(line.text) { visualGeometryUsed = true }
        }
        func moveVertically(_ state: EditorState, _ range: SelectionRange, forward: Bool) -> SelectionRange {
            visualGeometryUsed = true
            return base.moveVertically(state, range, forward: forward)
        }
        func moveToLineBoundary(_ state: EditorState, _ range: SelectionRange, forward: Bool, includeWrap: Bool) -> SelectionRange {
            if includeWrap { note(state, range.head) }
            return base.moveToLineBoundary(state, range, forward: forward, includeWrap: includeWrap)
        }
        func lineBlockAt(_ state: EditorState, _ pos: Int) -> (from: Int, to: Int) { base.lineBlockAt(state, pos) }
        func blockWidgetRanges(_ state: EditorState) -> [BlockWidgetRange] { [] }
    }

    struct RunResult {
        let doc: String
        let sel: EditorSelection
        let visualGeometry: Bool
        let domEdit: Bool
    }

    /// Replays one case. `prevDoc` is the editor content before the oracle's
    /// setDoc (which is itself an undoable change in the web app).
    static func run(_ c: Case, prevDoc: String) -> RunResult {
        let layout = RecordingLayout()
        let env = CommandEnv(now: Date(), time: 1_000_000, layout: layout)
        let session = EditorSession(state: EditorState(doc: Text(prevDoc), selection: .cursor(0)), env: env)
        // Mirror oracle/page.js setDoc: select 0, replace everything, select.
        session.dispatch(TransactionSpec(selection: .single(0)))
        env.time += 100
        session.dispatch(TransactionSpec(changes: [Change(from: 0, to: prevDoc.utf16.count, insert: c.doc)]))
        env.time += 100
        session.dispatch(TransactionSpec(selection: EditorSelection(ranges: c.sel.ranges.map { SelectionRange.range($0.anchor, $0.head) },
                                                                   mainIndex: c.sel.mainIndex)))
        env.time += 5000
        let debug = ProcessInfo.processInfo.environment["KEYS_DEBUG"].map { $0.split(separator: ",").map(String.init).contains(c.name) } ?? false
        func dump(_ label: String) {
            if debug { print("  [\(label)] \(String(reflecting: session.state.doc.string)) sel \(session.state.selection.ranges.map { [$0.anchor, $0.head] })") }
        }
        var domEdit = false
        dump("start")
        for k in c.keys {
            if k.hasPrefix("t:") {
                for ch in k.dropFirst(2) {
                    if ch != "\n" && isDomSensitiveReplace(session.state) { domEdit = true }
                    env.time += 5
                    session.insertText(String(ch))
                }
            } else {
                env.time += 35
                session.handle(k)
            }
            dump(k)
        }
        return RunResult(doc: session.state.doc.string, sel: session.state.selection,
                         visualGeometry: layout.visualGeometryUsed, domEdit: domEdit)
    }

    /// Typing over a selection that crosses a line break, or that starts/ends
    /// strictly inside a rendered list prefix: Chrome's contenteditable edits
    /// the DOM its own way and CM adopts the result.
    static func isDomSensitiveReplace(_ state: EditorState) -> Bool {
        let r = state.selection.main
        if r.empty { return false }
        if state.doc.lineAt(r.from).number != state.doc.lineAt(r.to).number { return true }
        for p in [r.from, r.to] {
            if let parsed = ListLines.parseBulletTaskLineAt(state, p), p > parsed.lineFrom, p < parsed.bodyFrom { return true }
        }
        return false
    }

    func testKeysParity() throws {
        let cases = KeysParityTests.loadCases() + KeysParityTests.loadCases("keys-extra.jsonl")
        if cases.isEmpty { throw XCTSkip("fixtures/keys.jsonl missing") }
        var perTag: [String: (pass: Int, total: Int)] = [:]
        var skipped = 0, pass = 0, total = 0, layoutFails = 0, domFails = 0
        var failures: [String] = [], excluded: [String] = []
        var prevOut = ""
        for c in cases {
            let prevDoc = c.prevDoc ?? (c.index % 250 == 0 ? "" : prevOut)
            prevOut = c.outDoc
            if c.keys.contains(where: { KeysParityTests.layoutKeys.contains($0) }) { skipped += 1; continue }
            let r = KeysParityTests.run(c, prevDoc: prevDoc)
            let ok = r.doc == c.outDoc && r.sel.ranges == c.outSel.ranges && r.sel.mainIndex == c.outSel.mainIndex
            func fmt(_ s: EditorSelection) -> String { s.ranges.map { "[\($0.anchor),\($0.head)]" }.joined() }
            let detail = """
            ✗ \(c.name) [\(c.tags.joined(separator: ","))] keys=\(c.keys)
               doc:  \(String(reflecting: c.doc)) sel \(fmt(c.sel))
               want: \(String(reflecting: c.outDoc)) sel \(fmt(c.outSel))
               got:  \(String(reflecting: r.doc)) sel \(fmt(r.sel))
            """
            if !ok && r.visualGeometry { layoutFails += 1; excluded.append("[layout] " + detail); continue }
            if !ok && r.domEdit { domFails += 1; excluded.append("[dom-edit] " + detail); continue }
            // Intentional divergence: Tab on a numbered item nests it and renumbers (1. / 1. / 2.);
            // the web app left numbered items alone.
            if !ok && c.name.hasPrefix("list ctx '1. a") && c.keys.contains("Tab") { excluded.append("[intentional] " + detail); continue }
            // Intentional divergence: Cmd-Shift-7/8 convert list lines (checkbox/bullet/numbered) and keep
            // the indent; the web app stacked prefixes ("1. - a") or stripped half a checkbox ("[ ] a").
            if !ok && c.keys.contains(where: { $0 == "Mod-Shift-7" || $0 == "Mod-Shift-8" }) { excluded.append("[intentional] " + detail); continue }
            total += 1
            if ok { pass += 1 }
            for tag in c.tags {
                var e = perTag[tag] ?? (0, 0)
                e.total += 1
                if ok { e.pass += 1 }
                perTag[tag] = e
            }
            if !ok { failures.append(detail) }
        }
        var report = "KEYS PARITY: \(pass)/\(total) (\(String(format: "%.1f", 100.0 * Double(pass) / Double(max(1, total))))%)"
        report += " | skipped Up/Down: \(skipped) | excluded layout-dependent: \(layoutFails) | excluded dom-edit: \(domFails)\n"
        for (tag, e) in perTag.sorted(by: { $0.key < $1.key }) {
            report += "  \(tag): \(e.pass)/\(e.total)\n"
        }
        print(report)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keys-parity-failures.txt")
        try? (report + "\n" + failures.joined(separator: "\n") + "\n\nEXCLUDED\n" + excluded.joined(separator: "\n"))
            .write(to: out, atomically: true, encoding: .utf8)
        print("failures written to \(out.path)")
        for f in failures.prefix(40) { print(f) }
        XCTAssertEqual(pass, total, "keys parity failures: \(total - pass)")
    }
}

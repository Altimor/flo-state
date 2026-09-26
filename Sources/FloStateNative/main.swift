import AppKit
import FloCore
import FloKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--batch-geometry") {
    // --batch-geometry in.json out.json : [{doc, caret}] -> [{chars, lineTops}]
    let input = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[i + 1]))) as! [[String: Any]]
    var out: [[String: Any]] = []
    for item in input {
        let r = MainActor.assumeIsolated {
            Snapshot.render(text: item["doc"] as! String, caret: item["caret"] as! Int,
                            width: CGFloat((item["width"] as? Double) ?? 1400), height: CGFloat((item["height"] as? Double) ?? 3000))
        }
        out.append(["chars": r.chars.map { $0 as Any? ?? NSNull() }, "lineTops": r.lineTops])
    }
    try! JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[i + 2]))
    exit(0)
}
if let i = args.firstIndex(of: "--replay-keys") {
    // --replay-keys fixtures/keys.jsonl [filter-substring] : real NSEvent replay vs web oracle
    let text = try! String(contentsOfFile: args[i + 1], encoding: .utf8)
    let filter = args.count > i + 2 ? args[i + 2] : nil
    func sel(_ o: [String: Any]) -> EditorSelection {
        EditorSelection(ranges: (o["ranges"] as! [[Int]]).map { SelectionRange.range($0[0], $0[1]) }, mainIndex: o["main"] as! Int)
    }
    func fmt(_ s: EditorSelection) -> String { s.ranges.map { "\($0.anchor),\($0.head)" }.joined(separator: " ") }
    MainActor.assumeIsolated {
        let r = KeyReplayer()
        var pass = 0, total = 0, desync = 0
        var byTag: [String: (Int, Int)] = [:]
        for line in text.split(separator: "\n") {
            let d = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let name = d["name"] as! String
            if let f = filter, !name.contains(f) { continue }
            r.load(d["doc"] as! String, selection: sel(d["sel"] as! [String: Any]))
            let verbose = ProcessInfo.processInfo.environment["REPLAY_VERBOSE"] != nil
            for k in d["keys"] as! [String] {
                r.press(k)
                if verbose { print("  after \(k): \(r.doc.debugDescription.prefix(80)) [\(fmt(r.selection))]") }
            }
            let ok = r.doc == d["outDoc"] as! String && r.selection == sel(d["outSel"] as! [String: Any])
            if r.viewText != r.doc { desync += 1; print("DESYNC \(name)") }
            total += 1; if ok { pass += 1 }
            let tag = (d["tags"] as! [String]).first ?? "?"
            byTag[tag, default: (0, 0)].1 += 1
            if ok { byTag[tag]!.0 += 1 } else {
                print("FAIL \(name) keys=\(d["keys"]!)\n  doc=\((d["doc"] as! String).debugDescription)\n  want=\((d["outDoc"] as! String).debugDescription) [\(fmt(sel(d["outSel"] as! [String: Any])))]\n  got =\(r.doc.debugDescription) [\(fmt(r.selection))]")
            }
        }
        for (t, v) in byTag.sorted(by: { $0.key < $1.key }) { print("  \(t): \(v.0)/\(v.1)") }
        print("REPLAY: \(pass)/\(total) desync=\(desync)")
    }
    exit(0)
}
if let i = args.firstIndex(of: "--replay-bounds") {
    // --replay-bounds fixtures/bounds.json [filter] : TextKit navigation vs CM on the web layout
    let docs = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[i + 1]))) as! [[String: Any]]
    let filter = args.count > i + 2 ? args[i + 2] : nil
    MainActor.assumeIsolated {
        let r = KeyReplayer()
        let names = ["lbF", "lbB", "vD", "vU"]
        var ok = [0, 0, 0, 0], total = 0
        for d in docs {
            let name = d["name"] as! String
            if let f = filter, !name.contains(f) { continue }
            let doc = d["doc"] as! String
            for p in d["probes"] as! [[String: Any]] {
                let pos = p["pos"] as! Int
                r.load(doc, selection: .cursor(pos))
                let got = r.probe(pos)
                total += 1
                for (k, n) in names.enumerated() {
                    let want = p[n] as! [Any]
                    let wh = want[0] as! Int
                    if got[k].0 == wh { ok[k] += 1 } else {
                        let ns = doc as NSString
                        func ctx(_ x: Int) -> String {
                            let a = max(0, x - 12), b = min(ns.length, x + 12)
                            return (ns.substring(with: NSRange(location: a, length: x - a)) + "‸" + ns.substring(with: NSRange(location: x, length: b - x))).debugDescription
                        }
                        print("MISS \(n) \(name) @\(pos) \(ctx(pos)) want \(wh) \(ctx(wh)) got \(got[k].0) \(ctx(got[k].0))")
                    }
                }
            }
        }
        for (k, n) in names.enumerated() { print("  \(n): \(ok[k])/\(total)") }
        print("BOUNDS: \(ok.reduce(0, +))/\(total * 4)")
    }
    exit(0)
}
if let i = args.firstIndex(of: "--fuzz-edit") {
    // --fuzz-edit <file> <seed> <steps> : random edits through the text view; incremental
    // render state must equal a fresh full render (attributes per char).
    let text = try! String(contentsOfFile: args[i + 1], encoding: .utf8)
    var rng = UInt64(args.count > i + 2 ? Int(args[i + 2]) ?? 1 : 1)
    let steps = args.count > i + 3 ? Int(args[i + 3]) ?? 200 : 200
    func rand(_ n: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(max(1, n))) }
    let snippets = ["\n", "\n\n", "```", "```\n", "# ", "## ", "- ", "* ", "1. ", "**", "*", "_", "`", "~~", "|", "| a | b |\n|---|---|\n",
                    "[[", "]]", ":smile:", "---", "\t", "> ", "x", "hello ", "[link](http://a.b)", "![](a.png)", "- [ ] ", "==", "\\", "<div>", "$$"]
    MainActor.assumeIsolated {
        let r = KeyReplayer()
        r.load(text, selection: .cursor(0))
        var bad = 0
        for step in 0..<steps {
            let tv = r.controller.textView
            let len = (tv.string as NSString).length
            let a = rand(len + 1)
            switch rand(4) {
            case 0, 1:
                tv.setSelectedRange(NSRange(location: a, length: 0))
                tv.insertText(snippets[rand(snippets.count)], replacementRange: NSRange(location: NSNotFound, length: 0))
            case 2:
                let b = min(len, a + rand(40))
                tv.setSelectedRange(NSRange(location: a, length: b - a))
                tv.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            default:
                tv.setSelectedRange(NSRange(location: a, length: rand(3) == 0 ? min(len - a, rand(30)) : 0))
            }
            if step % 20 == 19 || step == steps - 1 {
                let fresh = KeyReplayer()
                fresh.load(r.doc, selection: r.selection)
                // async widget renders (math, mermaid, HTML) landed during the fresh load: let the
                // incremental editor apply them too before comparing
                r.controller.waitForAsyncWidgets()
                let s1 = r.controller.textView.textStorage!, s2 = fresh.controller.textView.textStorage!
                guard s1.string == s2.string else { print("TEXT DESYNC at step \(step)"); bad += 1; break }
                var diffAt: Int? = nil
                let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .kern, .paragraphStyle, .floWidgetKey, .floGlyphShiftKey]
                for pos in 0..<s1.length {
                    for k in keys {
                        let v1 = s1.attribute(k, at: pos, effectiveRange: nil), v2 = s2.attribute(k, at: pos, effectiveRange: nil)
                        if !attrEqual(v1, v2) { diffAt = pos; print("ATTR DIFF step \(step) pos \(pos) key \(k.rawValue): \(String(describing: v1).prefix(80)) vs \(String(describing: v2).prefix(80))"); break }
                    }
                    if diffAt != nil { break }
                }
                if diffAt != nil { bad += 1; break }
            }
        }
        print("FUZZ: \(bad == 0 ? "ok" : "FAILED") steps=\(steps) planMismatches=\(PlanCacheStats.mismatches)")
    }
    exit(0)
}
if let i = args.firstIndex(of: "--perf") {
    // --perf <file> : typing latency on a real document (offscreen, incl. layout + display)
    let text = try! String(contentsOfFile: args[i + 1], encoding: .utf8)
    MainActor.assumeIsolated {
        let r = KeyReplayer()
        var t0 = Date()
        let units = text.utf16.count
        let lines = text.components(separatedBy: "\n")
        // caret at the end of the line in the middle of the document
        var pos = 0
        for l in lines.prefix(lines.count / 2) { pos += l.utf16.count + 1 }
        pos = max(0, pos - 1)
        r.load(text, selection: .cursor(pos))
        r.window.displayIfNeeded()
        print(String(format: "load %d units, %d lines: %.1f ms", units, lines.count, Date().timeIntervalSince(t0) * 1000))
        var times: [Double] = []
        let typed = Array("the quick brown fox jumps over the lazy dog ".utf8.map { String(UnicodeScalar($0)) })
        for k in 0..<200 {
            t0 = Date()
            let key = k % 50 == 49 ? "Enter" : (typed[k % typed.count] == " " ? "Space" : typed[k % typed.count])
            r.press(key)
            r.controller.textView.layoutSubtreeIfNeeded()
            r.window.displayIfNeeded()
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        let pl = r.controller.perfLog
        if !pl.isEmpty {
            func avg(_ k: KeyPath<(Double, Double, Double, Double), Double>) -> Double { pl.map { $0[keyPath: k] }.reduce(0, +) / Double(pl.count) * 1000 }
            print(String(format: "render x%d: parse %.2f plan %.2f sigs %.2f apply %.2f ms", pl.count, avg(\.0), avg(\.1), avg(\.2), avg(\.3)))
        }
        let sorted = times.sorted()
        print(String(format: "keystroke: avg %.2f ms, p50 %.2f, p95 %.2f, max %.2f", times.reduce(0, +) / Double(times.count),
                     sorted[times.count / 2], sorted[times.count * 95 / 100], sorted.last!))
        t0 = Date()
        for _ in 0..<50 { r.press("Down") ; r.window.displayIfNeeded() }
        print(String(format: "arrow down: avg %.2f ms", Date().timeIntervalSince(t0) * 1000 / 50))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot") {
    // --snapshot <file> [--caret N] [--out png] [--geometry json] [--width W] [--height H]
    func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let file = args[i + 1]
    let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    let caret = Int(opt("--caret") ?? "0") ?? 0
    let w = CGFloat(Double(opt("--width") ?? "1400") ?? 1400), h = CGFloat(Double(opt("--height") ?? "900") ?? 900)
    // --dark: the schema's default dark theme (Writer preset)
    let theme = args.contains("--dark")
        ? EditorTheme(foreground: NSColor(hex: "#FCFCFC"), accent: NSColor(hex: "#FF6A00"), headingColor: NSColor(hex: "#F0F0F0"),
                      subheadingColor: NSColor(hex: "#3a3a3a"), contrast: 0.328, background: NSColor(hex: "#111111"))
        : EditorTheme()
    let result = MainActor.assumeIsolated { Snapshot.render(text: text, caret: caret, width: w, height: h, theme: theme,
                                                                        documentPath: (file as NSString).standardizingPath.hasPrefix("/") ? file : FileManager.default.currentDirectoryPath + "/" + file) }
    if let out = opt("--out") { try? result.png.write(to: URL(fileURLWithPath: out)) }
    if let g = opt("--geometry") {
        let json = try! JSONSerialization.data(withJSONObject: ["chars": result.chars.map { $0 as Any? ?? NSNull() }, "lineTops": result.lineTops])
        try? json.write(to: URL(fileURLWithPath: g))
    }
    exit(0)
}

MainActor.assumeIsolated { runGUI() }

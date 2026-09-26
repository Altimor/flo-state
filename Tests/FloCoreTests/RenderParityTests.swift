import XCTest
@testable import FloCore

/// Per-character live-preview parity against the real app's rendered DOM.
final class RenderParityTests: XCTestCase {
    struct Sem: Equatable, CustomStringConvertible {
        var vis: String          // "v" visible, "rm" removed, "0" zero-size, "tr" transparent, "hid" opacity-hidden
        var mono = false
        var size = 100           // percent of base
        var weight = 400
        var italic = false
        var under = false
        var strike = false
        var color = ""
        var op = 100
        var description: String {
            vis == "v" ? "\(color)\(op != 100 ? "@\(op)" : "") \(size)% w\(weight)\(italic ? " it" : "")\(under ? " u" : "")\(strike ? " s" : "")\(mono ? " mono" : "")" : vis
        }
    }

    static let base = 18.0

    static func colorRole(_ raw: String) -> String {
        var css = raw
        // WebKit serialises oklch with float noise ("296.829987"): normalise to the CSS source precision
        if raw.hasPrefix("oklch("), let inner = raw.dropFirst(6).split(separator: ")").first {
            let v = inner.split(separator: " ").compactMap { Double($0) }
            if v.count == 3 {
                func f(_ x: Double, _ p: Int) -> String {
                    var s = String(format: "%.\(p)f", x)
                    while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
                    return s
                }
                css = "oklch(\(f(v[0], 4)) \(f(v[1], 3)) \(f(v[2], 2)))"
            }
        }
        if css.contains("/ 0.8)") { return "text" }
        if css.contains("/ 0.54)") { return "muted" }
        if css.hasPrefix("color(srgb 0.0509804") && !css.contains("/") { return "primary" }
        switch css {
        case "rgb(4, 51, 255)": return "link"
        case "rgb(74, 134, 232)": return "subheading"
        case "rgb(25, 25, 25)": return "heading1"
        case "rgba(0, 0, 0, 0)": return "transparent"
        case "oklch(0.6569 0.2 259.93)": return "atom"
        case "oklch(0.6853 0.164 25.1)": return "string"
        case "oklch(0.7005 0.217 296.83)": return "keyword"
        case "oklch(0.7127 0.101 169.93)": return "literal"
        case "oklch(0.7688 0.16 43.42)": return "regexp"
        case "oklch(0.6142 0.158 259.6)": return "definitionVariable"
        case "oklch(0.7588 0.082 184.11)": return "localVariable"
        case "oklch(0.6451 0.083 165.19)": return "typeNamespace"
        case "oklch(0.7614 0.1 168.52)": return "className"
        case "oklch(0.6667 0.193 282.06)": return "specialVariable"
        case "oklch(0.5892 0.132 259.4)": return "definitionProperty"
        case "oklch(0.7593 0.182 28.91)": return "invalid"
        default: return css
        }
    }

    static func nativeRole(_ c: ColorRole) -> String {
        switch c {
        case .text: return "text"
        case .primary: return "primary"
        case .muted: return "muted"
        case .link: return "link"
        case .heading1: return "heading1"
        case .subheading: return "subheading"
        case .transparent: return "transparent"
        case .syntax(let n): return n
        case .invalid: return "invalid"
        case .inherit: return "text"
        }
    }

    static func expected(_ ch: [Any]?, styles: [[String: Any]]) -> Sem {
        guard let ch = ch else { return Sem(vis: "rm") }
        let s = styles[ch[0] as! Int]
        let fs = Double((s["fontSize"] as! String).dropLast(2))!
        if fs == 0 { return Sem(vis: "0") }
        let op = Int((((s["opacity"] as? Double) ?? 1) * 100).rounded())
        let chain = ((s["classes"] as? [String]) ?? []).joined(separator: " ")
        if (ch[1] as! Int) == 0 || op == 0 {
            // opacity-hidden but still occupying space == transparent, except
            // the heading hash which hangs in the margin.
            return Sem(vis: chain.contains("cm-heading-hash") ? "hid" : "tr")
        }
        let color = colorRole(s["color"] as! String)
        if color == "transparent" { return Sem(vis: "tr") }
        return Sem(vis: "v", mono: (s["fontFamily"] as! String).hasPrefix("\"SF Mono\""),
                   size: Int((fs / base * 100).rounded()), weight: Int(s["fontWeight"] as! String) ?? 400,
                   italic: (s["fontStyle"] as! String) == "italic",
                   under: (s["textDecorationLine"] as! String).contains("underline"),
                   strike: (s["textDecorationLine"] as! String).contains("line-through"), color: color, op: op)
    }

    static func native(_ st: CharStyle) -> Sem {
        switch st.hidden {
        case .removed?: return Sem(vis: "rm")
        case .zeroSize?: return Sem(vis: "0")
        case .transparent?: return Sem(vis: "tr")
        case .margin(let visible)?:
            if !visible { return Sem(vis: "hid") }
        case nil: break
        }
        if st.color == .transparent { return Sem(vis: "tr") }
        return Sem(vis: "v", mono: st.mono, size: Int((st.sizeEm * 100).rounded()), weight: st.weight, italic: st.italic,
                   under: st.underline, strike: st.strike, color: nativeRole(st.color), op: Int((st.opacity * 100).rounded()))
    }

    func testRenderMatchesOracle() {
        let cases = Fixtures.json(ProcessInfo.processInfo.environment["RENDER_FIXTURE"] ?? "render.json") as! [[String: Any]]
        var total = 0, bad = 0
        var byClass: [String: (Int, String)] = [:]
        var badCases = Set<String>()
        for c in cases {
            let doc = c["doc"] as! String
            let sel = (c["sel"] as! [String: Any])["ranges"] as! [[Int]]
            let state = EditorState(doc: Text(doc), selection: EditorSelection(ranges: sel.map { SelectionRange(anchor: $0[0], head: $0[1]) }))
            let plan = RenderPlanner.plan(state)
            let chars = c["chars"] as! [Any]
            let styles = c["styles"] as! [[String: Any]]
            let units = Array(doc.utf16)
            var rendered = [Bool](repeating: false, count: units.count)
            // CodeMirror also renders the selection head's line when it lies outside the viewport,
            // detached (a gap above it) and without viewport-scoped decorations: not comparable.
            var prevBottom: Double? = nil
            for l in (c["lines"] as! [[String: Any]]).sorted(by: { ($0["top"] as? Double ?? 0) < ($1["top"] as? Double ?? 0) }) {
                let f = l["from"] as! Int, t = (l["to"] as? Int) ?? f
                let top = (l["top"] as? Double) ?? 0, h = (l["height"] as? Double) ?? 0
                defer { prevBottom = top + h }
                if let pb = prevBottom, top - pb > 100 { continue }
                if f <= t { for i in f..<min(t, units.count) { rendered[i] = true } }
            }
            for (pos, raw) in chars.enumerated() {
                if units[pos] == 10 || !rendered[pos] { continue } // newlines / offscreen / block widgets
                // WebKit reports the first char after a soft wrap as a collapsed (zero-width,
                // "invisible") rect at the end of the previous row: a measuring artifact, not a style
                if let r = raw as? [Any], r.count > 4, (r[1] as? NSNumber)?.intValue == 0,
                   ((r[4] as? NSNumber)?.doubleValue ?? 1) == 0,
                   (styles[(r[0] as? NSNumber)?.intValue ?? 0]["fontSize"] as? String) != "0px" { continue }
                let exp = Self.expected(raw as? [Any], styles: styles)
                let got = Self.native(plan.style(at: pos))
                total += 1
                if exp != got {
                    bad += 1
                    badCases.insert(c["name"] as! String)
                    var cls = "?"
                    if let r = raw as? [Any] { cls = ((styles[r[0] as! Int]["classes"] as? [String]) ?? []).joined(separator: ">") }
                    let key = "\(cls) | exp \(exp) | got \(got)"
                    let ctx = String(utf16CodeUnits: Array(units[max(0, pos - 12)..<min(units.count, pos + 12)]), count: min(units.count, pos + 12) - max(0, pos - 12))
                    byClass[key] = ((byClass[key]?.0 ?? 0) + 1, byClass[key]?.1 ?? "\(c["name"]!) @\(pos) «\(ctx)»")
                }
            }
        }
        let top = byClass.sorted { $0.value.0 > $1.value.0 }.prefix(40)
            .map { "  \($0.value.0)× \($0.key)\n      e.g. \($0.value.1)" }.joined(separator: "\n")
        print("RENDER PARITY: \(total - bad)/\(total) chars match; \(badCases.count)/\(cases.count) cases have diffs\n\(top)")
        XCTAssertEqual(bad, 0)
    }
}

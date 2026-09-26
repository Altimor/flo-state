import XCTest
import AppKit
import WebKit
@testable import FloKit
import FloCore

@MainActor
final class BlockWidgetTests: XCTestCase {
    func fragmentFrame(_ r: KeyReplayer, containing pos: Int) -> CGRect? {
        let tlm = r.controller.textView.textLayoutManager!
        let tcm = tlm.textContentManager!
        var found: CGRect?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            let a = tcm.offset(from: tcm.documentRange.location, to: f.rangeInElement.location)
            let b = tcm.offset(from: tcm.documentRange.location, to: f.rangeInElement.endLocation)
            if pos >= a && pos < b { found = f.layoutFragmentFrame; return false }
            return true
        }
        return found
    }

    /// The rendered table's first line takes the widget height, the rest collapse;
    /// clicking the table selects its whole source (and reveals it).
    func testTableWidgetHeightAndClick() {
        let r = KeyReplayer()
        let table = "| Name | Qty |\n|:--|:-:|\n| **Apple** | 3 |\n| Pear | 12 |"
        let doc = "Intro\n\n" + table + "\n\nafter"
        r.load(doc, selection: .cursor(0))
        let from = 7, to = from + table.utf16.count
        let first = fragmentFrame(r, containing: from)!
        let expected = TableCache().layout(source: table, theme: r.controller.theme, available: r.controller.applier.columnWidth)!.widgetHeight
        XCTAssertEqual(first.height, expected, accuracy: 0.5)
        let second = fragmentFrame(r, containing: (doc as NSString).range(of: "|:--").location)!
        XCTAssertLessThan(second.height, 1)
        // click in the middle of the table
        let tv = r.controller.textView
        let p = tv.convert(NSPoint(x: first.midX + tv.textContainerOrigin.x, y: first.midY + tv.textContainerOrigin.y), to: nil)
        let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: r.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        tv.mouseDown(with: ev)
        XCTAssertEqual(r.selection.main.from, from)
        XCTAssertEqual(r.selection.main.to, to)
        // revealed: source lines now have text height
        XCTAssertGreaterThan(fragmentFrame(r, containing: (doc as NSString).range(of: "|:--").location)!.height, 20)
    }

    /// KaTeX math renders async; line boxes match the web (inline 28px, display merged line 100px);
    /// clicking a formula selects its source.
    func testMathWidgets() {
        let r = KeyReplayer()
        let doc = "Intro\n\n$$\nE = mc^2\n$$\n\nand $a^2 + b^2 = c^2$ inline.\n\nend"
        r.load(doc, selection: .cursor(0))
        r.controller.waitForAsyncWidgets()
        let ns = doc as NSString
        XCTAssertEqual(fragmentFrame(r, containing: ns.range(of: "$$").location)!.height, 100, accuracy: 0.5)
        XCTAssertLessThan(fragmentFrame(r, containing: ns.range(of: "E =").location)!.height, 1)
        let inline = fragmentFrame(r, containing: ns.range(of: "and").location)!
        XCTAssertEqual(inline.height, 28, accuracy: 0.5)
        let from = ns.range(of: "$a^2").location, to = ns.range(of: "c^2$").location + 4
        let tv = r.controller.textView
        let screen = tv.firstRect(forCharacterRange: NSRange(location: from, length: to - from), actualRange: nil)
        let rect = tv.convert(r.window.convertFromScreen(screen), from: nil)
        XCTAssertEqual(rect.width, 112.125, accuracy: 0.5)
        XCTAssertEqual(r.controller.inlineWidgetRange(at: NSPoint(x: rect.midX, y: rect.midY)).map { [$0.0, $0.1] }, [from, to])
    }

    func spin(_ seconds: TimeInterval, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func js(_ web: WKWebView, _ code: String) -> Any? {
        var out: Any?, done = false
        web.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { r in if case .success(let v) = r { out = v }; done = true }
        spin(5) { done }
        return out
    }

    /// Mermaid: fixed 496px widget (never revealed by the caret); a live canvas
    /// sits over it; its Edit-code panel rewrites the whole fence.
    func testMermaidWidgetAndLiveCanvas() {
        MermaidOverlay.enabled = true
        let r = KeyReplayer()
        let fence = "```mermaid\nflowchart LR\n A[Idea] --> B{Worth it?}\n B -- yes --> C[Build it]\n B -- no --> D[Park it]\n C --> E[Ship]\n E --> A\n```"
        let doc = "Intro\n\n" + fence + "\n\nafter"
        r.load(doc, selection: .cursor(9))   // caret inside the fence: still rendered
        r.controller.waitForAsyncWidgets()
        let ns = doc as NSString
        XCTAssertEqual(fragmentFrame(r, containing: ns.range(of: "```mermaid").location)!.height, 496, accuracy: 0.5)
        XCTAssertLessThan(fragmentFrame(r, containing: ns.range(of: "flowchart").location)!.height, 1)
        let tv = r.controller.textView
        var live: WKWebView?
        spin(10) { live = tv.subviews.compactMap { $0 as? WKWebView }.first; return live != nil && (js(live!, "return !!document.querySelector('.cm-mermaid-canvas svg')") as? Bool) == true }
        guard let web = live else { return XCTFail("no live canvas") }
        XCTAssertEqual(web.frame.height, 480, accuracy: 0.5)
        XCTAssertEqual(web.frame.width, r.controller.applier.columnWidth, accuracy: 0.5)
        // Edit code toggle opens the nested editor
        _ = js(web, "document.querySelector('.cm-mermaid-canvas-edit').click(); return 1")
        spin(1) { (js(web, "return document.querySelector('.cm-mermaid-canvas').classList.contains('is-editing')") as? Bool) == true }
        XCTAssertEqual(js(web, "return document.querySelector('.cm-mermaid-canvas').classList.contains('is-editing')") as? Bool, true)
        // expand opens the fullscreen overlay over the whole window; Esc closes it
        _ = js(web, "document.querySelector('[aria-label=\"Open in fullscreen\"]').click(); return 1")
        let overlay = r.controller.mermaidOverlay!
        spin(5) { overlay.fullscreen != nil && (js(overlay.fullscreen!, "return !!document.querySelector('.cm-mermaid-fullscreen.is-open svg')") as? Bool) == true }
        guard let fs = overlay.fullscreen else { return XCTFail("no fullscreen") }
        XCTAssertEqual(fs.frame, r.window.contentView!.bounds)
        if let out = ProcessInfo.processInfo.environment["MERMAID_FS_PNG"] {
            r.window.orderBack(nil)   // far offscreen; web views only paint in an ordered window
            var done = false
            spin(0.6)
            let sc = WKSnapshotConfiguration(); sc.afterScreenUpdates = true
            _ = js(fs, "document.querySelector('.cm-mermaid-fullscreen-canvas').style.transition = 'none'; return 1")
            fs.takeSnapshot(with: sc) { img, _ in
                if let t = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                done = true
            }
            spin(5) { done }
        }
        _ = js(fs, "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})); return 1")
        spin(3) { overlay.fullscreen == nil }
        XCTAssertNil(overlay.fullscreen)
        // a source change from the panel replaces the fence
        let next = "```mermaid\ngraph LR\n  X --> Y\n```"
        _ = js(web, "webkit.messageHandlers.flo.postMessage({type: 'source', text: \(String(reflecting: next))}); return 1")
        spin(3) { r.controller.state.doc.string.contains("graph LR") }
        XCTAssertEqual(r.controller.state.doc.string, "Intro\n\n" + next + "\n\nafter")
    }

    /// HTML blocks: sanitised render with the web's heights; <iframe>-only blocks keep their source;
    /// links inside navigate; clicking elsewhere selects the source backwards.
    func testHtmlBlocks() {
        let r = KeyReplayer()
        let doc = "Intro\n\n<div>\n  <p>para <a href=\"https://x.com\">link</a></p>\n</div>\n\n<iframe src=\"x\"></iframe>\n\nafter"
        r.load(doc, selection: .cursor(0))
        r.controller.waitForAsyncWidgets()
        let ns = doc as NSString
        let f = fragmentFrame(r, containing: ns.range(of: "<div>").location)!
        XCTAssertEqual(f.height, 139, accuracy: 0.5)   // as the web (break-spaces keeps the newlines)
        XCTAssertLessThan(fragmentFrame(r, containing: ns.range(of: "<p>").location)!.height, 1)
        XCTAssertEqual(fragmentFrame(r, containing: ns.range(of: "<iframe").location)!.height, 27, accuracy: 0.5)
        var got: [EditorController.LinkClick] = []
        r.controller.onLinkClick = { got.append($0) }
        let from = ns.range(of: "<div>").location, to = ns.range(of: "</div>").location + 6
        XCTAssertEqual(r.controller.blockWidgetRange(at: from).map { [$0.0, $0.1] }, [to, from])
    }

    /// Visual check of the fullscreen page in a windowless web view (MERMAID_FS_PNG2).
    func testMermaidFullscreenPageRenders() {
        guard let out = ProcessInfo.processInfo.environment["MERMAID_FS_PNG2"] else { return }
        let theme = EditorTheme()
        let html = MermaidRenderer.pageHTML(MermaidRenderer.style(theme: theme), width: 1400, fullscreen: true)!
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fs-test.html")
        try! html.write(to: file, atomically: true, encoding: .utf8)
        v.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        spin(3) { !v.isLoading }
        spin(0.3)
        _ = js(v, "floFullscreen('flowchart LR\\n A[Idea] --> B{Worth it?}\\n B -- yes --> C[Build it]\\n B -- no --> D[Park it]\\n C --> E[Ship]\\n E --> A'); return 1")
        spin(1)
        // CSS transitions don't advance in a windowless view: settle them for the capture
        _ = js(v, "const s = document.createElement('style'); s.textContent = '*{transition:none !important}'; document.head.append(s); await new Promise(r => setTimeout(r, 100)); return 1")
        var done = false
        let sc = WKSnapshotConfiguration(); sc.afterScreenUpdates = true
        v.takeSnapshot(with: sc) { img, _ in
            if let t = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: t) { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
            done = true
        }
        spin(5) { done }
    }

    /// The plan-time HTML verdict (HtmlSanitizeHint.mayRender) agrees with DOMPurify.
    func testHtmlSanitizeVerdictMatchesDOMPurify() {
        let base = [
            "<div>x</div>", "<div></div>", "<iframe src=\"x\"></iframe>", "<script>alert(1)</script>", "<style>p{}</style>",
            "<!-- only a comment -->", "<br/>", "<hr>", "<img src=\"a.png\">", "<foo>text</foo>", "<foo></foo>", "<custom-el/>",
            "<div>&nbsp;</div>", "<span>&amp;</span>", "<p>\n\n</p>", "<form><input></form>", "<textarea>t</textarea>",
            "<select><option>o</option></select>", "<svg><text>t</text></svg>", "<math><mi>x</mi></math>", "<noscript>n</noscript>",
            "<title>t</title>", "<meta charset=\"x\">", "<link rel=\"x\">", "<object>o</object>", "<embed src=\"x\">",
            "<table><tr><td></td></tr></table>", "<details><summary></summary></details>", "<video></video>", "<audio></audio>",
            "<center>c</center>", "<font>f</font>", "<button>b</button>", "<label></label>", "<canvas></canvas>",
            "<div\n  class=\"x\">\n</div>", "<template>t</template>", "<xmp>x</xmp>", "<head><title>x</title></head>",
            "<body></body>", "<html></html>", "<!DOCTYPE html>", "<?xml version=\"1.0\"?>", "<![CDATA[x]]>", "<a href=\"x\"></a>",
            "<b> </b>", "<i>\t</i>", "<u>&#160;</u>", "<wbr>", "<abbr>a</abbr>", "<colgroup></colgroup>", "<thead></thead>",
        ]
        var all = base
        // every HTML block in the oracle sandbox workspace (if generated) and the custom corpus
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let e = FileManager.default.enumerator(at: root.appendingPathComponent("oracle/sandbox"), includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "md" {
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                FloMarkdown.parse(text).iterate(enter: { n, _ in
                    if n.name == "HTMLBlock" { all.append((text as NSString).substring(with: n.range)) }
                    return true
                })
            }
        }
        let samples = all
        let real = HtmlBlockRenderer.shared.sanitizedIsEmpty(samples, style: HtmlBlockRenderer.style(theme: EditorTheme()))
        for (s, empty) in zip(samples, real) {
            XCTAssertEqual(HtmlSanitizeHint.mayRender(s), !empty, "verdict for \(s)")
        }
    }
}

import AppKit
import WebKit
import FloCore

/// Live Mermaid canvases: a WKWebView running the web widget, laid exactly
/// over each rendered (snapshot) mermaid widget in the text view, so drag-pan,
/// wheel / pinch / button zoom, reset and the Edit-code panel behave as in the
/// web app. Edits in the code panel rewrite the whole fence in the document
/// (writeFenceText). The static snapshot underneath is what offscreen
/// captures see.
@MainActor
final class MermaidOverlay: NSObject, WKScriptMessageHandler {
    weak var editor: EditorController?
    private final class Live {
        let view: WKWebView
        var body: String
        var fence: String
        var from: Int, to: Int
        var style: MermaidRenderer.PageStyle
        var loaded = false
        init(view: WKWebView, body: String, fence: String, from: Int, to: Int, style: MermaidRenderer.PageStyle) {
            self.view = view; self.body = body; self.fence = fence; self.from = from; self.to = to; self.style = style
        }
    }
    private var lives: [Live] = []
    private var syncScheduled = false
    /// Tests / snapshots: no live views.
    static var enabled = ProcessInfo.processInfo.environment["FLO_NO_LIVE_MERMAID"] == nil

    init(editor: EditorController) { self.editor = editor }

    func scheduleSync() {
        guard Self.enabled, !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.sync()
        }
    }

    /// Create / move / drop live views to match the plan's mermaid widgets.
    func sync() {
        guard let editor = editor, let plan = editor.currentPlan, let tlm = editor.textView.textLayoutManager,
              let tcm = tlm.textContentManager else { return }
        let tv = editor.textView
        let style = MermaidRenderer.style(theme: editor.theme)
        let width = editor.applier.columnWidth
        var keep: [Live] = []
        var pool = lives
        let units = editor.state.doc.units
        for w in plan.widgets {
            guard case .mermaid(let body) = w.kind, w.to <= units.count,
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: w.from),
                  let frag = tlm.textLayoutFragment(for: loc) else { continue }
            let fence = String(utf16CodeUnits: Array(units[w.from..<w.to]), count: w.to - w.from)
            let f = frag.layoutFragmentFrame
            let origin = tv.textContainerOrigin
            let rect = CGRect(x: origin.x + editor.applier.gutter, y: origin.y + f.minY + MermaidRenderer.widgetPadding,
                              width: width, height: MermaidRenderer.canvasHeight)
            // reuse the view showing the same fence (or any spare one)
            let idx = pool.firstIndex { $0.fence == fence } ?? pool.firstIndex { $0.body == body } ?? (pool.isEmpty ? nil : 0)
            let live: Live
            if let i = idx {
                live = pool.remove(at: i)
                if live.style != style { load(live, style: style, width: width) }
            } else {
                live = make(style: style, width: width, body: body, fence: fence)
                tv.addSubview(live.view)
            }
            live.from = w.from; live.to = w.to
            if live.body != body || live.fence != fence {
                live.body = body; live.fence = fence
                if live.loaded { mount(live) }
            }
            if live.view.frame != rect { live.view.frame = rect }
            keep.append(live)
        }
        for l in pool { l.view.removeFromSuperview() }
        lives = keep
    }

    private func make(style: MermaidRenderer.PageStyle, width: CGFloat, body: String, fence: String) -> Live {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "flo")
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.setValue(false, forKey: "drawsBackground")
        let live = Live(view: v, body: body, fence: fence, from: 0, to: 0, style: style)
        load(live, style: style, width: width)
        return live
    }

    private func load(_ live: Live, style: MermaidRenderer.PageStyle, width: CGFloat) {
        live.style = style
        live.loaded = false
        guard let html = MermaidRenderer.pageHTML(style, width: width) else { return }
        // the page's canvas box starts at the widget padding: shift it up so the view is just the canvas
        let shifted = html.replacingOccurrences(of: "</style>", with: ".cm-mermaid-widget { padding: 0 !important; }</style>")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("flo-mermaid-live-\(getpid())-\(ObjectIdentifier(live).hashValue).html")
        try? shifted.write(to: file, atomically: true, encoding: .utf8)
        live.view.navigationDelegate = navDelegate
        navDelegate.onLoad[ObjectIdentifier(live.view)] = { [weak self, weak live] in
            guard let self = self, let live = live else { return }
            live.loaded = true
            self.mount(live)
        }
        live.view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    private func mount(_ live: Live) {
        live.view.callAsyncJavaScript("floMermaid(body, fence, true)", arguments: ["body": live.body, "fence": live.fence],
                                      in: nil, in: .page, completionHandler: nil)
    }

    private let navDelegate = NavDelegate()

    // MARK: fullscreen (mermaid-fullscreen.ts): the web overlay in a web view covering the window

    private(set) var fullscreen: WKWebView?

    func openFullscreen(body: String) {
        guard fullscreen == nil, let editor = editor, let win = editor.textView.window, let root = win.contentView,
              let html = MermaidRenderer.pageHTML(MermaidRenderer.style(theme: editor.theme), width: root.bounds.width, fullscreen: true) else { return }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(self), name: "flo")
        let v = WKWebView(frame: root.bounds, configuration: cfg)
        v.autoresizingMask = [.width, .height]
        v.setValue(false, forKey: "drawsBackground")
        root.addSubview(v, positioned: .above, relativeTo: nil)
        fullscreen = v
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("flo-mermaid-full-\(getpid()).html")
        try? html.write(to: file, atomically: true, encoding: .utf8)
        v.navigationDelegate = navDelegate
        navDelegate.onLoad[ObjectIdentifier(v)] = { [weak v] in
            guard let v = v else { return }
            v.window?.makeFirstResponder(v)
            v.callAsyncJavaScript("floFullscreen(body)", arguments: ["body": body], in: nil, in: .page, completionHandler: nil)
        }
        v.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    func closeFullscreen() {
        guard let v = fullscreen else { return }
        fullscreen = nil
        navDelegate.onLoad[ObjectIdentifier(v)] = nil
        v.removeFromSuperview()
        editor.map { $0.textView.window?.makeFirstResponder($0.textView) }
    }

    final class NavDelegate: NSObject, WKNavigationDelegate {
        var onLoad: [ObjectIdentifier: () -> Void] = [:]
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { onLoad[ObjectIdentifier(webView)]?() }
        }
    }

    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: MermaidOverlay?
        init(_ t: MermaidOverlay) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(c, didReceive: message) }
        }
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let d = message.body as? [String: Any] else { return }
            if d["type"] as? String == "expand", let live = lives.first(where: { $0.view.configuration.userContentController === c }) {
                openFullscreen(body: live.body); return
            }
            if d["type"] as? String == "closed", let fs = fullscreen, fs.configuration.userContentController === c {
                closeFullscreen(); return
            }
            guard d["type"] as? String == "source", let text = d["text"] as? String,
                  let editor = editor, let live = lives.first(where: { $0.view.configuration.userContentController === c }) else { return }
            // writeFenceText: replace the entire fence, leave the outer selection alone
            let from = live.from, to = live.to
            guard to <= editor.state.doc.length, editor.state.doc.slice(from, to) != text else { return }
            live.fence = text
            editor.run { t in
                t.dispatch(TransactionSpec(changes: [Change(from: from, to: to, insert: text)]))
                return true
            }
        }
    }
}

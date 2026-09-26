import AppKit
import WebKit
import FloCore

/// Mermaid widgets (mermaid-decorations.ts): the web app's own widget —
/// beautiful-mermaid SVG in the mermaid-canvas.ts frame — bundled into
/// Resources/mermaid (tools/mermaid). Drawn from cached snapshots of a
/// windowless WKWebView; a live copy of the same page is laid over the widget
/// while the pointer is on it (MermaidOverlay) for pan / zoom / Edit code.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    nonisolated static let canvasHeight: CGFloat = 480
    nonisolated static let widgetPadding: CGFloat = 8
    nonisolated static var widgetHeight: CGFloat { canvasHeight + 2 * widgetPadding }

    struct Key: Hashable {
        var body: String
        var fenceText: String
        var width: CGFloat
        var page: PageStyle
    }

    /// Everything the page's CSS depends on.
    struct PageStyle: Hashable {
        var vars: String
        var fontFamily: String
        var fontSize: CGFloat
        var dark: Bool
    }

    private var cache: [Key: NSImage] = [:]
    private var queue: [Key] = []
    private var queued = Set<Key>()
    private var busy = false
    private var web: WKWebView?
    private var webStyle: PageStyle?
    private var loaded = false
    var onReady: [() -> Void] = []
    private var notifyScheduled = false

    func cached(_ key: Key) -> NSImage? { cache[key] }

    func image(_ key: Key) -> NSImage? {
        if ProcessInfo.processInfo.environment["FLO_DEBUG_MERMAID"] != nil { NSLog("mermaid image %d", cache[key] == nil ? 0 : 1) }
        if let r = cache[key] { return r }
        if !queued.contains(key) { queued.insert(key); queue.append(key); pump() }
        return nil
    }

    static func style(theme: EditorTheme) -> PageStyle {
        let fg = theme.foreground, c = theme.contrast
        let bg = theme.background.usingColorSpace(.sRGB) ?? theme.background
        let dark = (0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent) < 0.5
        func mix(_ a: CGFloat) -> String { fg.withAlphaComponent(a).cssRGBA }
        let vars = """
        --bg-base: \(bg.withAlphaComponent(1).cssRGBA); --fg-base: \(fg.withAlphaComponent(1).cssRGBA); --contrast: \(c);
        --accent: \(theme.accent.cssRGBA); --border-color: \(mix(c * 0.24)); --surface-subtle: \(mix(c * 0.18));
        --surface-card: \(dark ? mix(c * 0.16) : "transparent"); --text-primary: \(fg.cssRGBA); --text-secondary: \(mix(0.8));
        --mono-font: "SF Mono", Menlo, Monaco, Consolas, monospace; --code-bg: \(theme.codeBackground.cssRGBA);
        --pm-code-background-color: \(theme.codeBackground.cssRGBA);
        """
        return PageStyle(vars: vars, fontFamily: theme.cssFontFamily, fontSize: theme.baseSize, dark: dark)
    }

    static var resourceDir: URL? { FloResourcesProxy.url("mermaid") }

    static func pageHTML(_ s: PageStyle, width: CGFloat, offscreen: Bool = false, fullscreen: Bool = false) -> String? {
        guard let dir = resourceDir,
              let js = try? String(contentsOf: dir.appendingPathComponent("mermaid-widget.js"), encoding: .utf8),
              let css = try? String(contentsOf: dir.appendingPathComponent("mermaid-canvas.css"), encoding: .utf8) else { return nil }
        return """
        <!doctype html><html data-theme="\(s.dark ? "dark" : "light")"><head><meta charset="utf-8"><style>
        *, ::before, ::after { box-sizing: border-box; }
        :root { \(s.vars) }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body { font-family: \(s.fontFamily); font-size: \(s.fontSize)px; line-height: 1.5; color: var(--text-secondary);
               -webkit-font-smoothing: antialiased; }
        button { font: inherit; }
        .cm-mermaid-widget { width: \(width)px; }
        \(css)
        </style><script>/* offscreen / occluded web views never fire rAF: time-based frames */ window.requestAnimationFrame = cb => setTimeout(() => cb(performance.now()), 16);</script></head><body>\(fullscreen ? "" : "<div class=\"cm-mermaid-widget\"><div class=\"cm-mermaid-canvas\" id=\"host\" tabindex=\"0\"></div></div>")
        <script>\(js)</script>
        <script>
        window.floSettle = async function () {
          for (let i = 0; i < 3; i++) await new Promise(r => requestAnimationFrame(r));
          await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 1500))]);
          for (let i = 0; i < 2; i++) await new Promise(r => requestAnimationFrame(r));
          return 1;
        };
        </script></body></html>
        """
    }

    private func boot(_ style: PageStyle, width: CGFloat) {
        if ProcessInfo.processInfo.environment["FLO_DEBUG_MERMAID"] != nil { NSLog("mermaid boot") }
        let w = web ?? {
            let cfg = WKWebViewConfiguration()
            let v = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: Self.widgetHeight), configuration: cfg)
            v.navigationDelegate = self
            v.setValue(false, forKey: "drawsBackground")
            web = v
            return v
        }()
        w.frame = NSRect(x: 0, y: 0, width: width, height: Self.widgetHeight)
        loaded = false
        webStyle = style
        guard let html = Self.pageHTML(style, width: width, offscreen: true) else { NSLog("mermaid: resources missing"); return }
        // a large page: load it from a temp file rather than a string
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("flo-mermaid-\(getpid()).html")
        do { try html.write(to: file, atomically: true, encoding: .utf8) } catch { NSLog("mermaid: %@", "\(error)"); return }
        w.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if ProcessInfo.processInfo.environment["FLO_DEBUG_MERMAID"] != nil { NSLog("mermaid loaded") }
            loaded = true; pump()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("mermaid page failed: %@", "\(error)")
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("mermaid page failed (provisional): %@", "\(error)")
    }

    private func pump() {
        guard !busy, let key = queue.first else { return }
        if web == nil || webStyle != key.page || web!.frame.width != key.width { boot(key.page, width: key.width); return }
        guard loaded, let web = web else { return }
        queue.removeFirst()
        busy = true
        web.callAsyncJavaScript("floMermaid(body, fence, false); return await floSettle()",
                                arguments: ["body": key.body, "fence": key.fenceText], in: nil, in: .page) { r in
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.environment["FLO_DEBUG_MERMAID"] != nil { NSLog("mermaid js: %@", String(describing: r)) }
                let cfg = WKSnapshotConfiguration()
                cfg.rect = CGRect(x: 0, y: Self.widgetPadding, width: key.width, height: Self.canvasHeight)
                cfg.afterScreenUpdates = true
                web.takeSnapshot(with: cfg) { img, _ in
                    MainActor.assumeIsolated { self.finish(key, img) }
                }
            }
        }
    }

    private func finish(_ key: Key, _ img: NSImage?) {
        busy = false
        queued.remove(key)
        if let i = img { cache[key] = i }
        if cache.count > 60 { cache.removeAll() }
        if !notifyScheduled {
            notifyScheduled = true
            DispatchQueue.main.async {
                self.notifyScheduled = false
                for f in self.onReady { f() }
            }
        }
        pump()
    }

    var isIdle: Bool { queue.isEmpty && !busy }

    func waitIdle(timeout: TimeInterval = 15) {
        let end = Date().addingTimeInterval(timeout)
        while !isIdle && Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

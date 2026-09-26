import AppKit
import WebKit
import FloCore

/// HTML blocks (html-block-decorations.ts): sanitised with the web's own
/// DOMPurify config (Resources/htmlblock, extracted by tools/htmlblock),
/// laid out in a windowless WKWebView replica of `.cm-html-block-widget`
/// inside `.cm-content`, snapshotted and cached. Link rects are kept so
/// clicks on links navigate.
@MainActor
final class HtmlBlockRenderer: NSObject, WKNavigationDelegate {
    static let shared = HtmlBlockRenderer()

    struct Key: Hashable {
        var raw: String
        var width: CGFloat
        var style: Style
    }

    struct Style: Hashable {
        var vars: String
        var fontFamily: String
        var fontSize: CGFloat
        var lineHeight: CGFloat
        var color: String
    }

    final class Result {
        let image: NSImage?
        let height: CGFloat
        /// Sanitised output was blank: the web keeps the source.
        let empty: Bool
        let links: [(CGRect, String)]
        init(image: NSImage?, height: CGFloat, empty: Bool, links: [(CGRect, String)]) {
            self.image = image; self.height = height; self.empty = empty; self.links = links
        }
    }

    private var cache: [Key: Result] = [:]
    private var queue: [Key] = []
    private var queued = Set<Key>()
    private var busy = false
    private var web: WKWebView?
    private var loaded = false
    var onReady: [() -> Void] = []
    /// The real sanitiser disagreed with a plan-time verdict: plans must be rebuilt.
    var verdictChanged = false
    private var notifyScheduled = false

    func cached(_ key: Key) -> Result? { cache[key] }

    func result(_ key: Key) -> Result? {
        if let r = cache[key] { return r }
        if !queued.contains(key) { queued.insert(key); queue.append(key); pump() }
        return nil
    }

    static func style(theme: EditorTheme) -> Style {
        let fg = theme.foreground, c = theme.contrast
        func mix(_ a: CGFloat) -> String { fg.withAlphaComponent(a).cssRGBA }
        let vars = """
        --link-color: \(theme.accent.cssRGBA); --border-color: \(mix(c * 0.24)); --code-bg: \(theme.codeBackground.cssRGBA);
        --blockquote-border: \(theme.blockquoteBar.cssRGBA); --text-muted: \(theme.mutedColor.cssRGBA);
        --pm-code-font: "SF Mono", Menlo, Monaco, Consolas, monospace;
        """
        return Style(vars: vars, fontFamily: theme.cssFontFamily, fontSize: theme.baseSize,
                     lineHeight: theme.lineHeight, color: theme.textColor.cssRGBA)
    }

    /// htmlBlockTheme (EditorView.baseTheme) as plain CSS.
    static let widgetCSS = """
    .cm-html-block-widget { padding: 0.25em 0; line-height: 1.6; }
    .cm-html-block-widget h1, .cm-html-block-widget h2, .cm-html-block-widget h3, .cm-html-block-widget h4,
    .cm-html-block-widget h5, .cm-html-block-widget h6 { margin-top: 0.5em; margin-bottom: 0.25em; font-weight: 600; line-height: 1.3; }
    .cm-html-block-widget h1 { font-size: 1.6em; }
    .cm-html-block-widget h2 { font-size: 1.4em; }
    .cm-html-block-widget h3 { font-size: 1.2em; }
    .cm-html-block-widget p { margin: 0.5em 0; }
    .cm-html-block-widget a { color: var(--link-color, #4fc1ff); text-decoration: underline; }
    .cm-html-block-widget img { max-width: 100%; height: auto; }
    .cm-html-block-widget table { border-collapse: collapse; width: 100%; }
    .cm-html-block-widget th, .cm-html-block-widget td { border: 1px solid var(--border-color, #3e3e42); padding: 0.4em 0.8em; }
    .cm-html-block-widget th { font-weight: 600; background-color: var(--code-bg, #2d2d2d); }
    .cm-html-block-widget pre { background-color: var(--code-bg, #2d2d2d); padding: 0.75em 1em; border-radius: 4px; overflow: auto; }
    .cm-html-block-widget code { font-family: var(--pm-code-font, 'SF Mono', Menlo, Monaco, Consolas, monospace); font-size: 0.9em; }
    .cm-html-block-widget blockquote { border-left: 3px solid var(--blockquote-border, #4e4e52); padding-left: 1em; margin: 0.5em 0; color: var(--text-muted, #858585); }
    .cm-html-block-widget hr { border: none; border-top: 1px solid var(--border-color, #3e3e42); margin: 0.75em 0; }
    .cm-html-block-widget ul, .cm-html-block-widget ol { padding-left: 1.5em; margin: 0.25em 0; }
    .cm-html-block-widget details { border: 1px solid var(--border-color, #3e3e42); border-radius: 4px; padding: 0.5em; }
    .cm-html-block-widget summary { cursor: pointer; font-weight: 600; }
    """

    private func boot() {
        guard web == nil, let dir = FloResourcesProxy.url("htmlblock"),
              let js = try? String(contentsOf: dir.appendingPathComponent("sanitize.js"), encoding: .utf8) else { return }
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        w.navigationDelegate = self
        w.setValue(false, forKey: "drawsBackground")
        web = w
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html, body { margin: 0; padding: 0; background: transparent; }
        .cm-content { white-space: break-spaces; word-wrap: break-word; overflow-wrap: anywhere; tab-size: 4; }
        \(Self.widgetCSS)
        </style><script>\(js)</script><script>
        window.floRenderHtml = async function (o) {
          document.documentElement.style.cssText = o.vars;
          const c = document.getElementById('c');
          c.style.fontFamily = o.fontFamily; c.style.fontSize = o.fontSize + 'px'; c.style.lineHeight = o.lineHeight;
          c.style.color = o.color; c.style.width = o.width + 'px';
          const sanitized = floSanitize(o.raw);
          if (!sanitized.trim()) return JSON.stringify({ empty: true });
          const w = document.createElement('div');
          w.className = 'cm-html-block-widget';
          w.innerHTML = sanitized;
          c.replaceChildren(w);
          void w.offsetHeight;
          await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 1000))]);
          await Promise.all([...w.querySelectorAll('img')].map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r; setTimeout(r, 1500); })));
          const wr = w.getBoundingClientRect();
          const links = [...w.querySelectorAll('a[href]')].flatMap(a => [...a.getClientRects()].map(r =>
            [r.left - wr.left, r.top - wr.top, r.width, r.height, a.getAttribute('href')]));
          return JSON.stringify({ height: wr.height, links });
        };
        </script></head><body><div class="cm-content" id="c"></div></body></html>
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("flo-htmlblock-\(getpid()).html")
        try? html.write(to: file, atomically: true, encoding: .utf8)
        w.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded = true; pump() }
    }

    private func pump() {
        if web == nil { boot() }
        guard loaded, !busy, let web = web, !queue.isEmpty else { return }
        let key = queue.removeFirst()
        busy = true
        let args: [String: Any] = ["raw": key.raw, "width": key.width, "vars": key.style.vars, "fontFamily": key.style.fontFamily,
                                   "fontSize": key.style.fontSize, "lineHeight": key.style.lineHeight, "color": key.style.color]
        web.frame = NSRect(x: 0, y: 0, width: key.width, height: web.frame.height)
        web.callAsyncJavaScript("return await floRenderHtml(o)", arguments: ["o": args], in: nil, in: .page) { r in
            MainActor.assumeIsolated {
                guard case .success(let v) = r, let s = v as? String,
                      let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { self.finish(key, nil); return }
                if d["empty"] as? Bool == true {
                    // planning assumed it renders: correct the verdict and re-plan
                    if HtmlSanitizeHint.record(key.raw, renders: false) { self.verdictChanged = true }
                    self.finish(key, Result(image: nil, height: 0, empty: true, links: [])); return
                }
                HtmlSanitizeHint.record(key.raw, renders: true)
                let h = CGFloat((d["height"] as? NSNumber)?.doubleValue ?? 0)
                let links: [(CGRect, String)] = ((d["links"] as? [[Any]]) ?? []).compactMap { a in
                    guard a.count == 5, let href = a[4] as? String else { return nil }
                    let n = a.prefix(4).map { CGFloat(($0 as? NSNumber)?.doubleValue ?? 0) }
                    return (CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), href)
                }
                if web.frame.height < h + 4 { web.frame.size.height = h + 4 }
                let cfg = WKSnapshotConfiguration()
                cfg.rect = CGRect(x: 0, y: 0, width: key.width, height: max(1, h))
                cfg.afterScreenUpdates = true
                web.takeSnapshot(with: cfg) { img, _ in
                    MainActor.assumeIsolated { self.finish(key, Result(image: img, height: h, empty: false, links: links)) }
                }
            }
        }
    }

    private func finish(_ key: Key, _ r: Result?) {
        busy = false
        queued.remove(key)
        if let r = r { cache[key] = r }
        if cache.count > 300 { cache.removeAll() }
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

    func waitIdle(timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while !isIdle && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}

extension HtmlBlockRenderer {
    /// DOMPurify's verdict (does anything survive?) for each raw block — tests.
    func sanitizedIsEmpty(_ raws: [String], width: CGFloat = 734, style: Style) -> [Bool] {
        let keys = raws.map { Key(raw: $0, width: width, style: style) }
        for k in keys { _ = result(k) }
        waitIdle(timeout: 20)
        return keys.map { cached($0)?.empty ?? true }
    }
}

import AppKit
import WebKit
import FloCore

/// KaTeX math (math-decorations.ts + math-renderer.ts) rendered by the same
/// KaTeX build the web app ships, in one offscreen (windowless) WKWebView,
/// laid out in a replica of the editor line and snapshotted. Asynchronous and
/// cached per (formula, display, font, colour): until a formula is ready the
/// widget takes no space; `onReady` asks the editor to re-apply its lines.
@MainActor
final class MathRenderer: NSObject, WKNavigationDelegate {
    static let shared = MathRenderer()

    struct Key: Hashable {
        var formula: String
        var display: Bool
        var fontSize: CGFloat
        var lineHeight: CGFloat
        var color: String        // CSS rgba()
        var fontFamily: String   // CSS font-family list
        var errorColor: String
        var codeBackground: String
        /// CodeMirror's zero-width `cm-widgetBuffer` images around a widget at a line edge
        var bufferBefore = false
        var bufferAfter = false
    }

    /// A rendered formula. Inline: `width` of the widget, the line box it
    /// makes (`lineHeight`, `baseline` from the top). Display: the whole
    /// merged line (`lineHeight`) drawn full width. `image` covers
    /// [-pad, width + pad] × [-pad, lineHeight + pad] around the widget box.
    final class Result {
        let image: NSImage
        let width: CGFloat
        let lineHeight: CGFloat
        let baseline: CGFloat
        let pad: CGFloat
        init(image: NSImage, width: CGFloat, lineHeight: CGFloat, baseline: CGFloat, pad: CGFloat) {
            self.image = image; self.width = width; self.lineHeight = lineHeight; self.baseline = baseline; self.pad = pad
        }
    }

    static let pad: CGFloat = 12
    private var cache: [Key: Result] = [:]
    private var queue: [Key] = []
    private var queued = Set<Key>()
    private var busy = false
    private var web: WKWebView?
    private var loaded = false
    /// Called (coalesced) after new formulas finished rendering.
    var onReady: [() -> Void] = []
    private var notifyScheduled = false

    var pending: Int { queue.count + (busy ? 1 : 0) + (loaded ? 0 : (queue.isEmpty ? 0 : 1)) }

    func cached(_ key: Key) -> Result? { cache[key] }

    func result(_ key: Key) -> Result? {
        if let r = cache[key] { return r }
        if !queued.contains(key) {
            queued.insert(key); queue.append(key)
            pump()
        }
        return nil
    }

    private static var katexDir: URL? {
        FloResourcesProxy.url("katex")
    }

    private func boot() {
        guard web == nil, let dir = Self.katexDir else { return }
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = true
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: cfg)
        w.navigationDelegate = self
        w.setValue(false, forKey: "drawsBackground")
        web = w
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>\(Self.inlinedCSS(dir))</style><script>\((try? String(contentsOf: dir.appendingPathComponent("katex.min.js"), encoding: .utf8)) ?? "")</script>
        <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        .cm-content { white-space: break-spaces; word-wrap: break-word; }
        .cm-line { display: block; padding: 0; }
        .cm-math-widget .katex-display { margin: 0.5em 0; }
        .cm-math-error { border-radius: 0.4rem; padding: 0.1rem 0.3rem;
          font-family: "SF Mono", ui-monospace, SFMono-Regular, Menlo, monospace; }
        #z { display: inline-block; width: 0; height: 0; }
        .cm-widgetBuffer { vertical-align: text-top; height: 1em; width: 0; display: inline; }
        </style></head><body><div class="cm-content" id="c"><div class="cm-line" id="l"></div></div>
        <script>
        window.floRender = async function (o) {
          const c = document.getElementById('c'), l = document.getElementById('l');
          c.style.fontFamily = o.fontFamily; c.style.fontSize = o.fontSize + 'px'; c.style.lineHeight = o.lineHeight + 'px';
          c.style.color = o.color; c.style.width = o.width + 'px';
          const span = document.createElement('span');
          span.className = o.display ? 'cm-math-widget cm-math-display' : 'cm-math-widget';
          try {
            span.innerHTML = katex.renderToString(o.formula, { displayMode: o.display, throwOnError: false, output: 'html' });
          } catch (e) {
            window.floLastError = String(e) + ' scripts=' + document.scripts.length + ' len=' + (document.scripts[0] ? document.scripts[0].text.length : -1) + ' css=' + document.styleSheets.length;
            span.classList.add('cm-math-error');
            span.style.color = o.errorColor; span.style.backgroundColor = o.codeBackground;
            span.textContent = o.display ? '$$' + o.formula + '$$' : '$' + o.formula + '$';
          }
          l.replaceChildren(span);
          const buf = () => { const i = document.createElement('img'); i.className = 'cm-widgetBuffer'; return i; };
          if (o.before) l.insertBefore(buf(), span);
          if (o.after) l.appendChild(buf());
          const z = document.createElement('span'); z.id = 'z'; l.appendChild(z);
          void l.offsetHeight;  // lay out so the KaTeX fonts start loading
          await document.fonts.ready;
          void l.offsetHeight;
          const lr = l.getBoundingClientRect(), sr = span.getBoundingClientRect(), zr = z.getBoundingClientRect();
          if (window.floLastError && window.floDebug) console.log(window.floLastError);
          const dbg = [...l.querySelectorAll('img,.katex-display,.katex')].map(e => { const r = e.getBoundingClientRect(); return e.className + ':' + (r.top - lr.top) + '/' + r.height }).join(' ');
          return JSON.stringify([sr.width, lr.height, zr.bottom - lr.top, sr.left - lr.left, (window.floLastError || '') + dbg]);
        };
        </script></body></html>
        """
        w.loadHTMLString(html, baseURL: nil)
    }

    /// katex.min.css with its woff2 fonts inlined as data URIs (woff/ttf fallbacks dropped).
    static func inlinedCSS(_ dir: URL) -> String {
        guard var css = try? String(contentsOf: dir.appendingPathComponent("katex.min.css"), encoding: .utf8) else { return "" }
        let re = try! NSRegularExpression(pattern: #"src:url\(fonts/([^)]+)\.woff2\) format\("woff2"\)[^}]*"#)
        let ns = css as NSString
        var out = "", last = 0
        for m in re.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            let data = (try? Data(contentsOf: dir.appendingPathComponent("fonts/\(name).woff2"))) ?? Data()
            out += "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        css = out
        return css
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // warm the fonts up so the first measurement is final
            webView.evaluateJavaScript("katex.render('\\\\mathrm{A}\\\\mathit{a}\\\\mathbf{b}\\\\sum\\\\int x^2', document.createElement('div')); 0") { _, _ in
                MainActor.assumeIsolated {
                    self.loaded = true
                    self.pump()
                }
            }
        }
    }

    private func pump() {
        if web == nil { boot() }
        guard loaded, !busy, let web = web, !queue.isEmpty else { return }
        let key = queue.removeFirst()
        busy = true
        let width: CGFloat = 734
        let args: [String: Any] = ["formula": key.formula, "display": key.display, "fontSize": key.fontSize, "lineHeight": key.lineHeight,
                                   "color": key.color, "fontFamily": key.fontFamily, "width": width,
                                   "errorColor": key.errorColor, "codeBackground": key.codeBackground,
                                   "before": key.bufferBefore, "after": key.bufferAfter]
        web.callAsyncJavaScript("return await floRender(o)", arguments: ["o": args], in: nil, in: .page) { r in
            MainActor.assumeIsolated {
                guard case .success(let v) = r, let s = v as? String,
                      let raw = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [Any], raw.count == 5 else {
                    self.finish(key, nil); return
                }
                if ProcessInfo.processInfo.environment["FLO_DEBUG_MATH"] != nil { NSLog("math %@ -> %@", key.formula, s) }
                let a = raw.prefix(4).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                let w = CGFloat(a[0]), lh = CGFloat(a[1]), base = CGFloat(a[2]), left = CGFloat(a[3])
                let pad = Self.pad
                let rect = key.display
                    ? CGRect(x: 0, y: 0, width: width, height: lh)
                    : CGRect(x: left - pad, y: -pad, width: w + 2 * pad, height: lh + 2 * pad)
                // shift the page so the padded rect is inside the view
                web.evaluateJavaScript("document.body.style.transform = 'translate(\(pad)px, \(pad)px)'; 0") { _, _ in
                    MainActor.assumeIsolated {
                        let cfg = WKSnapshotConfiguration()
                        cfg.rect = rect.offsetBy(dx: pad, dy: pad)
                        cfg.afterScreenUpdates = true
                        web.takeSnapshot(with: cfg) { img, _ in
                            MainActor.assumeIsolated {
                                if let img = img {
                                    self.finish(key, Result(image: img, width: key.display ? width : w, lineHeight: lh, baseline: base,
                                                            pad: key.display ? 0 : pad))
                                } else { self.finish(key, nil) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func finish(_ key: Key, _ r: Result?) {
        busy = false
        queued.remove(key)
        if let r = r { cache[key] = r }
        if cache.count > 500 { cache.removeAll() }
        if !notifyScheduled {
            notifyScheduled = true
            DispatchQueue.main.async {
                self.notifyScheduled = false
                for f in self.onReady { f() }
            }
        }
        pump()
    }

    /// Spin the run loop until every queued formula is rendered (snapshots/tests).
    func waitIdle(timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while (!queue.isEmpty || busy) && Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

extension NSColor {
    /// CSS rgba() of the sRGB colour.
    var cssRGBA: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "rgba(%d, %d, %d, %.4f)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()), c.alphaComponent)
    }
}

extension EditorTheme {
    /// The editor font stack as CSS (`--font`).
    var cssFontFamily: String {
        (fontFamilies.map { "\"\($0)\"" } + ["-apple-system", "BlinkMacSystemFont", "sans-serif"]).joined(separator: ", ")
    }
}

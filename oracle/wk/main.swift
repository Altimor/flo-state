// WebKit oracle: loads the real Flo State frontend (mock backend) in an
// offscreen WKWebView — the same engine the Tauri app uses on macOS — and
// answers JSON-line commands on stdin:
//   {"js": "<expr>"}                -> {"result": <json>} | {"error": "..."}
//   {"load": "<url>", "width": W, "height": H}
//   {"screenshot": "<png path>"}
//   {"key": {...NSEvent spec...}}   (reserved)
import AppKit
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

/// Call a private `-(void)set…:(BOOL)` if it exists.
func setBool(_ obj: NSObject, _ selName: String, _ v: Bool) {
    let sel = NSSelectorFromString(selName)
    guard obj.responds(to: sel), let m = class_getInstanceMethod(type(of: obj), sel) else {
        FileHandle.standardError.write("missing \(selName)\n".data(using: .utf8)!); return
    }
    typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(method_getImplementation(m), to: F.self)(obj, sel, v)
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Host: NSObject, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var loaded: (() -> Void)?

    func make(width: CGFloat, height: CGFloat) {
        window = KeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // keep timers / rAF running although the window is offscreen
        for k in ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageDOMTimerThrottlingAutoIncreases",
                  "pageVisibilityBasedProcessSuppressionEnabled"] {
            setBool(cfg.preferences, "_set" + k.prefix(1).uppercased() + k.dropFirst() + ":", false)
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: cfg)
        web.navigationDelegate = self
        setBool(web, "_setWindowOcclusionDetectionEnabled:", false)
        window.contentView = web
        window.orderBack(nil)   // needs to be "visible" for rendering; it's far offscreen
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?(); loaded = nil }

    func reply(_ obj: Any) {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    func handle(_ line: String) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            reply(["error": "bad json"]); return
        }
        if let url = d["load"] as? String {
            let w = (d["width"] as? Double) ?? 1400, h = (d["height"] as? Double) ?? 900
            if web == nil { make(width: w, height: h) } else {
                window.setContentSize(NSSize(width: w, height: h)); web.frame = NSRect(x: 0, y: 0, width: w, height: h)
            }
            loaded = { self.reply(["result": true]) }
            web.load(URLRequest(url: URL(string: url)!))
        } else if let expr = d["js"] as? String {
            let body = "const __r = await (\(expr));\nreturn JSON.stringify(__r === undefined ? null : __r);"
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { r in
                switch r {
                case .success(let v):
                    if let s = v as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) {
                        self.reply(["result": obj])
                    } else { self.reply(["result": NSNull()]) }
                case .failure(let e): self.reply(["error": "\(e)"])
                }
            }
        } else if let path = d["screenshot"] as? String {
            let cfg = WKSnapshotConfiguration()
            cfg.afterScreenUpdates = true
            web.takeSnapshot(with: cfg) { img, err in
                guard let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    self.reply(["error": "\(String(describing: err))"]); return
                }
                try? png.write(to: URL(fileURLWithPath: path))
                self.reply(["result": [rep.pixelsWide, rep.pixelsHigh]])
            }
        } else if let k = d["key"] as? [String: Any] {
            // real NSEvents through the window (WebKit's own key handling + CM keymaps)
            let chars = (k["chars"] as? String) ?? "", ign = (k["ign"] as? String) ?? chars
            let code = UInt16((k["keyCode"] as? Int) ?? 0)
            var flags: NSEvent.ModifierFlags = []
            for m in (k["mods"] as? [String]) ?? [] {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift)
                case "alt": flags.insert(.option); case "ctrl": flags.insert(.control); default: break }
            }
            if !window.isKeyWindow { window.makeKey() }
            if window.firstResponder !== web { window.makeFirstResponder(web) }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
            // let the web process handle it
            web.evaluateJavaScript("new Promise(r => requestAnimationFrame(() => setTimeout(r, 0)))") { _, _ in
                self.reply(["result": true])
            }
        } else if d["quit"] != nil {
            exit(0)
        } else {
            reply(["error": "unknown command"])
        }
    }
}

let host = Host()
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.async { host.handle(line) }
    }
    DispatchQueue.main.async { exit(0) }
}
app.run()

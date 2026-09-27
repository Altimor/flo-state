import AppKit
import FloCore
import FloKit

/// Welcome screen (no workspace): "Open Folder" / "Open File" / "Start from Scratch" (a new ~/Documents/Notebook with a Welcome note).
final class WelcomeView: FlippedView {
    unowned let model: ShellModel
    var onAddFolder: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var onStartFromScratch: (() -> Void)?
    init(model: ShellModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private static let titles = ["Open Folder", "Open File", "Start from Scratch"]
    private var buttons: [(String, CGRect)] {
        let f = UIFonts.ui(model.values, weight: .medium)
        let widths = Self.titles.map { TextStyle(font: f, color: .black).width($0) + 32 }
        let total = widths.reduce(0, +) + 12 * CGFloat(widths.count - 1)
        let y = bounds.height / 2 + 4
        var x = (bounds.width - total) / 2
        return zip(Self.titles, widths).map { t, w in defer { x += w + 12 }; return (t, CGRect(x: x, y: y, width: w, height: 35.5)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = model.palette_
        p.bg.setFill(); bounds.fill(using: .sourceOver)
        let msg = "Open a folder of notes or a single file, or start from scratch."
        let style = TextStyle(font: UIFonts.ui(model.values), color: p.textMuted)
        let lines = TextWrap.lines(msg, font: style.font, width: 252)
        var y = bounds.height / 2 - 24 - CGFloat(lines.count) * 21.125
        for l in lines { style.draw(l, x: (bounds.width - style.width(l)) / 2, lineTop: y, lineHeight: 21.125, in: ctx); y += 21.125 }
        let bf = UIFonts.ui(model.values, weight: .medium)
        for (i, (t, r)) in buttons.enumerated() {
            if i == 0 {
                p.textPrimary.setFill(); roundedPath(r, 8).fill()
                TextStyle(font: bf, color: p.bgBaseOpaque).draw(t, x: r.minX + 16, lineTop: r.minY + 8, lineHeight: 19.5, in: ctx)
            } else {
                let path = roundedPath(r.insetBy(dx: 0.5, dy: 0.5), 7.5)
                p.lineSubtle.setStroke(); path.lineWidth = 1; path.stroke()
                TextStyle(font: bf, color: p.textSecondary).draw(t, x: r.minX + 16, lineTop: r.minY + 8, lineHeight: 19.5, in: ctx)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let b = buttons
        if b[0].1.contains(pt) { onAddFolder?() } else if b[1].1.contains(pt) { onOpenFile?() } else if b[2].1.contains(pt) { onStartFromScratch?() }
    }
}

/// `--shell-snapshot <workspace> --data-dir D [--width W --height H] [--out png]
/// [--dump json] [--expand dir]... [--action newtab|palette[:q]|create:name]`
///
/// Builds the real window content offscreen (x=-10000, never ordered front,
/// never activates, no Dock icon) and writes a PNG + a frame dump.
@MainActor
enum ShellSnapshot {
    static var active = false
    /// `--settings-snapshot --data-dir D [--pane id] [--dark] [--out png] [--dump json]`:
    /// the Settings window rendered offscreen (frame incl. toolbar).
    static func runSettings(_ args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        active = true
        let data = opt("--data-dir") ?? NSTemporaryDirectory()
        let backend = SettingsBackend(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        let wc = SettingsWindowController(backend: backend)
        let w = wc.window!
        w.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        wc.select(opt("--pane") ?? "general")
        pump(ms: 400)
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let frameView = w.contentView!.superview!
        frameView.layoutSubtreeIfNeeded()
        frameView.display()
        if let out = opt("--out") {
            let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        if let d = opt("--dump") {
            let dump: [String: Any] = ["title": w.title, "frame": [w.frame.width, w.frame.height],
                                       "resizable": w.styleMask.contains(.resizable),
                                       "toolbar": w.toolbar?.items.map { $0.label } ?? [],
                                       "keys": wc.selectedPane.controls.map { $0.def.key },
                                       "preferred": [wc.selectedPane.preferredContentSize.width, wc.selectedPane.preferredContentSize.height],
                                       "content": [w.contentView!.frame.width, w.contentView!.frame.height]]
            try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: d))
        }
    }

    static func run(_ args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func all(_ n: String) -> [String] { args.indices.filter { args[$0] == n && $0 + 1 < args.count }.map { args[$0 + 1] } }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Legacy NSScrollers break offscreen cacheDisplay; the oracle hides scrollbars too.
        active = true
        guard let ws = opt("--shell-snapshot"), let data = opt("--data-dir") else {
            FileHandle.standardError.write(Data("usage: --shell-snapshot <workspace> --data-dir <dir>\n".utf8)); exit(2)
        }
        let w = CGFloat(Double(opt("--width") ?? "1200") ?? 1200), h = CGFloat(Double(opt("--height") ?? "800") ?? 800)
        let model = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)), importLegacy: false)
        model.readOnly = true
        model.systemIsDark = { false }
        let wc = ShellWindowController(model: model, frame: NSRect(x: -10000, y: -10000, width: w, height: h), offscreen: true)
        wc.root.opaqueBase = true
        wc.root.wantsLayer = true
        wc.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        pump { await model.openWorkspace(ws) }
        wc.flush()
        for d in all("--expand") { model.toggleDirectory(d) }
        wc.flush()
        wc.root.layoutSubtreeIfNeeded()
        wc.didActivate()
        if let a = opt("--action") {
            if a == "newtab" { model.editor.openNewTab() }
            else if a.hasPrefix("palette") {
                model.perform(.openFileSearch)
                if let q = a.split(separator: ":", maxSplits: 1).dropFirst().first { model.setPaletteQuery(String(q)) }
            } else if a.hasPrefix("create:") {
                model.perform(.newNote)
                model.setPaletteQuery(String(a.dropFirst("create:".count)))
            }
        }
        pump(ms: 150)
        wc.flush()
        wc.root.needsLayout = true
        wc.root.layoutSubtreeIfNeeded()
        wc.root.area.updateRail()
        wc.root.display()
        if let out = opt("--out") {
            let rep = wc.root.bitmapImageRepForCachingDisplay(in: wc.root.bounds)!
            wc.root.cacheDisplay(in: wc.root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        if ProcessInfo.processInfo.environment["SHELL_DEBUG"] != nil {
            func walk(_ v: NSView, _ depth: Int) {
                print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) b=\(v.bounds.origin) hidden=\(v.isHidden)")
                if depth < 7 { v.subviews.forEach { walk($0, depth + 1) } }
            }
            walk(wc.root, 0)
        }
        if let dbg = ProcessInfo.processInfo.environment["SHELL_DEBUG_DIR"] {
            for (name, v) in [("sidebar", wc.root.sidebar as NSView), ("area", wc.root.area), ("tabs", wc.root.tabs)] {
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dbg + "/" + name + ".png"))
            }
        }
        if let d = opt("--dump") {
            let json = try! JSONSerialization.data(withJSONObject: wc.root.dump(), options: [.prettyPrinted, .sortedKeys])
            try? json.write(to: URL(fileURLWithPath: d))
        }
    }

    /// Run an async job to completion while servicing the main run loop.
    static func pump(_ job: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await job(); done = true }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    static func pump(ms: Double) {
        let end = Date().addingTimeInterval(ms / 1000)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
}

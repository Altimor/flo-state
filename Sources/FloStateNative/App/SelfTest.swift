import AppKit
import FloCore
import FloKit

/// End-to-end self test inside the real app process (real run loop, real
/// on-screen window with live TextKit viewport layout), invisible: the window
/// is fully transparent and ignores the mouse, and the app never activates.
///
///   FloStateNative --selftest-return <workspace> <file> <dataDir>
///
/// Presses Return (and types) at the end and in the middle of the document,
/// logging the scroll position / document height after every key and every
/// scroll jump, then prints a JSON report and exits (1 if a jump happened).
@MainActor
enum SelfTest {
    static var keep: [AnyObject] = []

    static func run(_ args: [String]) {
        guard let i = args.firstIndex(of: "--selftest-return"), args.count > i + 3 else { print("usage"); exit(64) }
        let root = args[i + 1], file = args[i + 2], data = args[i + 3]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        let wc = ShellWindowController(model: model, frame: NSRect(x: 80, y: 80, width: 1400, height: 1000), offscreen: true)
        keep = [wc, model]
        wc.window!.alphaValue = 0
        wc.window!.ignoresMouseEvents = true
        wc.window!.orderFrontRegardless()
        Task { @MainActor in
            await model.openWorkspace(root, openFile: file, keepSession: false)
            wc.flush()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await script(wc)
        }
        app.run()
    }

    static func script(_ wc: ShellWindowController) async {
        guard let pane = wc.root.area.activeFilePane, let c = pane.controller else { print("no editor"); exit(2) }
        wc.window!.makeKey()
        wc.window!.makeFirstResponder(c.textView)
        var log: [String] = []
        var jumps: [String] = []
        var lastY = c.scrollView.contentView.bounds.origin.y
        var muted = true   // deliberate moves (jumping to the end / middle) aren't jumps
        let obs = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: c.scrollView.contentView, queue: nil) { _ in
            MainActor.assumeIsolated {
                let y = c.scrollView.contentView.bounds.origin.y
                if !muted, abs(y - lastY) > 200 {
                    let usage = c.textView.textLayoutManager?.usageBoundsForTextContainer.maxY ?? -1
                    jumps.append("\(Int(lastY))->\(Int(y)) docH=\(Int(c.textView.frame.height)) usage=\(Int(usage))")
                }
                lastY = y
            }
        }
        func key(_ chars: String, _ code: UInt16) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: wc.window!.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
            wc.window!.sendEvent(e)
        }
        func snap(_ label: String) {
            let clip = c.scrollView.contentView.bounds
            let caret = c.rect(forPosition: c.state.selection.main.head, in: c.textView) ?? .zero
            let visible = clip.intersects(caret)
            log.append("\(label): clipY=\(Int(clip.minY)) docH=\(Int(c.textView.frame.height)) caretY=\(Int(caret.minY)) visible=\(visible)")
            if !visible { jumps.append("\(label): caret not visible") }
        }
        func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

        // at the end
        c.textView.setSelectedRange(NSRange(location: (c.textView.string as NSString).length, length: 0))
        c.textView.scrollRangeToVisible(c.textView.selectedRange())
        muted = true
        await pause(0.8)
        lastY = c.scrollView.contentView.bounds.origin.y
        muted = false
        for n in 0..<8 {
            if n % 3 == 2 { for ch in "abc" { key(String(ch), 0) } }
            key("\r", 36)
            await pause(0.35)
            snap("end #\(n + 1)")
        }
        // in the middle
        let mid = (c.textView.string as NSString).length / 2
        c.textView.setSelectedRange(NSRange(location: mid, length: 0))
        c.textView.scrollRangeToVisible(c.textView.selectedRange())
        muted = true
        await pause(0.8)
        lastY = c.scrollView.contentView.bounds.origin.y
        muted = false
        for n in 0..<6 {
            key("\r", 36)
            await pause(0.35)
            snap("middle #\(n + 1)")
        }
        // clicks: the caret must land where clicked (live bug: "clicking often doesn't move the caret")
        func click(atChar pos: Int) -> Int {
            let tv = c.textView
            guard let r = c.rect(forPosition: pos, in: tv) else { return -1 }
            let p = tv.convert(NSPoint(x: r.minX + 2, y: r.midY), to: nil)
            func ev(_ t: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: wc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(ev(.leftMouseUp), atStart: false)
            tv.mouseDown(with: ev(.leftMouseDown))
            return c.state.selection.main.head
        }
        var clickMisses: [String] = []
        let ns = c.textView.string as NSString
        var probe = 0
        for n in 0..<20 {
            // a visible position: somewhere inside the current viewport, mid-word
            let clip = c.scrollView.contentView.bounds
            guard let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager,
                  let f = tlm.textLayoutFragment(for: CGPoint(x: 400, y: clip.midY + CGFloat(n * 17 % 300) - 150 - c.textView.textContainerOrigin.y)) else { continue }
            let start = tcm.offset(from: tcm.documentRange.location, to: f.rangeInElement.location)
            let para = f.rangeInElement
            let len = tcm.offset(from: para.location, to: para.endLocation)
            guard len > 6 else { continue }
            probe = start + len / 2
            if ns.character(at: probe) == 10 { continue }
            await pause(0.15)
            let got = click(atChar: probe)
            await pause(0.15)
            if abs(got - probe) > 1 { clickMisses.append("clicked \(probe) got \(got)") }
        }
        if !clickMisses.isEmpty { jumps.append(contentsOf: clickMisses) }
        log.append("clicks tried: 20, misses: \(clickMisses.count)")
        // wheel scrolling must not move the caret or jump
        let headBefore = c.state.selection.main.head
        for _ in 0..<15 {
            if let w = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0),
               let e = NSEvent(cgEvent: w) { c.scrollView.scrollWheel(with: e) }
            await pause(0.05)
            lastY = c.scrollView.contentView.bounds.origin.y
        }
        if c.state.selection.main.head != headBefore { jumps.append("wheel scroll moved the caret") }
        log.append("after wheel: clipY=\(Int(c.scrollView.contentView.bounds.minY))")
        NotificationCenter.default.removeObserver(obs)
        let lt = FloTextView.layoutTime.sorted()
        let report: [String: Any] = ["log": log, "jumps": jumps,
                                     "ensureLayoutMs": lt.isEmpty ? [] : [lt[lt.count / 2] * 1000, lt[lt.count * 95 / 100] * 1000, lt.last! * 1000]]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
        print(String(data: data, encoding: .utf8)!)
        exit(jumps.isEmpty ? 0 : 1)
    }
}

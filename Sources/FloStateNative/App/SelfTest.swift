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

    // MARK: scroll benchmark

    ///   FloStateNative --selftest-scroll <workspace> <file> <dataDir>
    /// Wheel-scrolls the note top → bottom → top → bottom in 40pt steps inside an invisible on-screen window,
    /// timing each step's main-thread work (scroll + layout + display), and prints per-pass stats as JSON.
    static func runScroll(_ args: [String]) {
        guard let i = args.firstIndex(of: "--selftest-scroll"), args.count > i + 3 else { print("usage"); exit(64) }
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
            guard let c = wc.root.area.activeFilePane?.controller else { print("no editor"); exit(2) }
            let clip = c.scrollView.contentView
            func wheel(_ dy: Int32) -> Double {
                let t0 = CFAbsoluteTimeGetCurrent()
                if let w = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0),
                   let e = NSEvent(cgEvent: w) { c.scrollView.scrollWheel(with: e) }
                wc.window!.displayIfNeeded()
                CATransaction.flush()
                return (CFAbsoluteTimeGetCurrent() - t0) * 1000
            }
            func pass(down: Bool) -> [String: Any] {
                var times: [Double] = [], slow: [[Int]] = [], jumps: [[Int]] = []
                var last = clip.bounds.minY, stuck = 0
                var lastH = c.textView.frame.height, heightChanges = 0
                var shifts = 0, maxShift = 0.0
                func charY(_ i: Int) -> CGFloat? {
                    guard let w = c.textView.window else { return nil }
                    let r = c.textView.firstRect(forCharacterRange: NSRange(location: i, length: 1), actualRange: nil)
                    return r.width > 0 ? c.textView.convert(w.convertFromScreen(r), from: nil).minY : nil
                }
                while stuck < 3 && times.count < 4000 {
                    // content stability: the character near the viewport top must keep its document position
                    let probe = CGPoint(x: c.textView.bounds.midX, y: clip.bounds.minY + 200)
                    let anchor = c.textView.characterIndexForInsertion(at: probe)
                    let y0 = anchor == NSNotFound ? nil : charY(anchor)
                    let ms = wheel(down ? -40 : 40)
                    if let y0, let y1 = charY(anchor), abs(y1 - y0) > 1 { shifts += 1; maxShift = max(maxShift, Double(abs(y1 - y0))) }
                    times.append(ms)
                    if ms > 16 { slow.append([Int(clip.bounds.minY), Int(ms)]) }
                    let moved = clip.bounds.minY - last
                    // a wheel step moves 40pt (less at the ends); anything else is a jump
                    if abs(moved) > 41 || (down ? moved < -0.5 : moved > 0.5) { jumps.append([Int(last), Int(moved)]) }
                    if abs(c.textView.frame.height - lastH) > 0.5 { heightChanges += 1; lastH = c.textView.frame.height }
                    if abs(clip.bounds.minY - last) < 0.5 { stuck += 1 } else { stuck = 0 }
                    last = clip.bounds.minY
                    if times.count % 100 == 0 { FileHandle.standardError.write("\(down ? "down" : "up") step \(times.count) y=\(Int(last)) h=\(Int(c.textView.frame.height)) last=\(Int(ms))ms\n".data(using: .utf8)!) }
                }
                let s = times.sorted()
                func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
                return ["steps": times.count, "p50": pct(0.5), "p95": pct(0.95), "max": s.last ?? 0,
                        "over16ms": slow.count, "slowest": Array(slow.sorted { $0[1] > $1[1] }.prefix(8)),
                        "jumps": jumps.count, "firstJumps": Array(jumps.prefix(6)), "heightChanges": heightChanges,
                        "contentShifts": shifts, "maxShift": maxShift]
            }
            clip.scroll(to: .zero); c.scrollView.reflectScrolledClipView(clip)
            var edits = 0
            let obs = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: c.textView.textStorage, queue: nil) { _ in edits += 1 }
            func unlaid() -> Int {
                guard let tlm = c.textView.textLayoutManager else { return -1 }
                var n = 0
                tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { f in if f.state != .layoutAvailable { n += 1 }; return true }
                return n
            }
            var r: [String: Any] = [:]
            r["unlaidAtStart"] = unlaid()
            r["down1"] = pass(down: true); r["unlaidAfterDown1"] = unlaid(); r["editsDuringDown1"] = edits; edits = 0
            r["up"] = pass(down: false); r["unlaidAfterUp"] = unlaid(); r["editsDuringUp"] = edits
            r["down2"] = pass(down: true)
            NotificationCenter.default.removeObserver(obs)
            if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { print(String(data: d, encoding: .utf8)!) }
            exit(0)
        }
        app.run()
    }
}

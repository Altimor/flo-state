import AppKit
import FloCore

private var mermaidOverlayKey: UInt8 = 0

extension EditorController {
    /// Source range of the rendered block widget (table, …) drawn on the line
    /// holding `pos`, when clicking there selects the whole source.
    func blockWidgetRange(at pos: Int) -> (Int, Int)? {
        guard pos != NSNotFound, let plan = currentPlan, pos >= 0, pos <= state.doc.length else { return nil }
        let line = state.doc.lineAt(pos)
        for w in plan.widgetsOverlapping(line.from, line.to) where w.block && w.replaces {
            switch w.kind {
            case .htmlBlock:
                if w.from <= line.to && w.to >= line.from { return (w.to, w.from) }
            case .table, .mermaid, .math(_, true):
                if w.from <= line.to && w.to >= line.from { return (w.from, w.to) }
            default: break
            }
        }
        return nil
    }
}

extension EditorController {
    /// Source range of a rendered inline math formula under a view point
    /// (clicking it range-selects the node, which reveals the source).
    func inlineWidgetRange(at point: NSPoint) -> (Int, Int)? {
        let i = textView.characterIndexForInsertion(at: point)
        guard i != NSNotFound, let plan = currentPlan else { return nil }
        for w in plan.widgetsOverlapping(max(0, i - 1), i + 1) where w.replaces {
            guard case .math(_, false) = w.kind, w.to > w.from else { continue }
            let screen = textView.firstRect(forCharacterRange: NSRange(location: w.from, length: w.to - w.from), actualRange: nil)
            guard let win = textView.window else { continue }
            let r = textView.convert(win.convertFromScreen(screen), from: nil)
            if point.x >= r.minX && point.x <= r.maxX { return (w.from, w.to) }
        }
        return nil
    }

    /// A link inside a rendered HTML block under a view point.
    func htmlBlockLink(at point: NSPoint) -> String? {
        let i = textView.characterIndexForInsertion(at: point)
        guard i != NSNotFound, let plan = currentPlan, let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let line = state.doc.lineAt(min(i, state.doc.length))
        for w in plan.widgetsOverlapping(line.from, line.to) where w.block && w.replaces {
            guard case .htmlBlock(let src) = w.kind,
                  let r = MainActor.assumeIsolated({ HtmlBlockRenderer.shared.cached(HtmlBlockRenderer.Key(raw: src, width: applier.columnWidth,
                                                                                                           style: HtmlBlockRenderer.style(theme: theme))) }),
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: w.from),
                  let frag = tlm.textLayoutFragment(for: loc) else { continue }
            let o = textView.textContainerOrigin
            let local = CGPoint(x: point.x - o.x - applier.gutter, y: point.y - o.y - frag.layoutFragmentFrame.minY)
            if let hit = r.links.first(where: { $0.0.contains(local) }) { return hit.1 }
        }
        return nil
    }

    /// Async widgets (KaTeX math): when renders land, re-apply the lines that show them.
    func installAsyncWidgetHooks() {
        MainActor.assumeIsolated {
            MathRenderer.shared.onReady.append { [weak self] in self?.asyncWidgetsReady() }
            MermaidRenderer.shared.onReady.append { [weak self] in self?.asyncWidgetsReady() }
            HtmlBlockRenderer.shared.onReady.append { [weak self] in self?.asyncWidgetsReady() }
            let overlay = MermaidOverlay(editor: self)
            objc_setAssociatedObject(self, &mermaidOverlayKey, overlay, .OBJC_ASSOCIATION_RETAIN)
            for name in [NSText.didChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: textView, queue: .main) { [weak overlay] _ in
                    MainActor.assumeIsolated { overlay?.scheduleSync() }
                }
            }
        }
    }

    func asyncWidgetsReady() {
        if MainActor.assumeIsolated({ HtmlBlockRenderer.shared.verdictChanged }) {
            MainActor.assumeIsolated { HtmlBlockRenderer.shared.verdictChanged = false }
            render(force: true)
            return
        }
        guard let plan = currentPlan else { return }
        let doc = state.doc
        for w in plan.widgets {
            switch w.kind {
            case .math, .mermaid, .htmlBlock: if w.from <= doc.length { forceLines.insert(doc.lineAt(w.from).number - 1) }
            default: break
            }
        }
        render()
        MainActor.assumeIsolated { mermaidOverlay?.scheduleSync() }
    }

    /// Live mermaid canvases over the rendered widgets.
    var mermaidOverlay: MermaidOverlay? {
        MainActor.assumeIsolated { objc_getAssociatedObject(self, &mermaidOverlayKey) as? MermaidOverlay }
    }

    /// Wait for pending async widget renders (snapshots and tests).
    public func waitForAsyncWidgets(timeout: TimeInterval = 10) {
        MainActor.assumeIsolated {
            MathRenderer.shared.waitIdle(timeout: timeout)
            MermaidRenderer.shared.waitIdle(timeout: timeout)
            HtmlBlockRenderer.shared.waitIdle(timeout: timeout)
        }
        asyncWidgetsReady()
    }
}

extension EditorController {
    /// A click on a rendered task checkbox (the area left of the item's text on a `- [ ]` line)
    /// toggles it. Returns true when the click was on a checkbox.
    func toggleCheckbox(at point: NSPoint) -> Bool {
        let i = textView.characterIndexForInsertion(at: point)
        guard i != NSNotFound, let plan = currentPlan, let win = textView.window else { return false }
        let line = state.doc.lineAt(min(i, state.doc.length))
        for w in plan.widgetsOverlapping(line.from, line.to) {
            guard case .checkbox = w.kind, w.from >= line.from, w.to <= line.to else { continue }
            // the text starts at w.to; the box is drawn in the ~2em just before it
            let screen = textView.firstRect(forCharacterRange: NSRange(location: w.to, length: 0), actualRange: nil)
            let r = textView.convert(win.convertFromScreen(screen), from: nil)
            let box = CGRect(x: r.minX - 34, y: r.minY - 4, width: 34, height: r.height + 8)
            guard box.contains(point), let spec = ListCommands.checkboxToggle(state, at: w.from) else { continue }
            run { t in t.dispatch(spec); return true }
            return true
        }
        return false
    }
}

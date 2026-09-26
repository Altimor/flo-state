import AppKit
import FloCore

/// `EditorLayout` backed by the live TextKit 2 layout: vertical motion and
/// visual line boundaries follow soft wraps like CodeMirror's DOM queries.
final class TextKitLayout: EditorLayout {
    weak var controller: EditorController?

    private var tlm: NSTextLayoutManager? { controller?.textView.textLayoutManager }

    struct VisualLine {
        var from: Int      // doc offset of first char
        var to: Int        // doc offset after last char (excluding a trailing newline)
        var frag: NSTextLayoutFragment
        var line: NSTextLineFragment
        var fragStart: Int
        var rect: CGRect   // container coordinates
        var endsLogicalLine = false
    }

    private func offset(_ loc: NSTextLocation) -> Int {
        guard let tcm = tlm?.textContentManager else { return 0 }
        return tcm.offset(from: tcm.documentRange.location, to: loc)
    }

    private func lines(of frag: NSTextLayoutFragment, docLength: Int) -> [VisualLine] {
        let start = offset(frag.rangeInElement.location)
        let units = controller?.state.doc.units ?? []
        return frag.textLineFragments.map { lf in
            let r = lf.characterRange
            var to = start + r.location + r.length
            var nl = false
            if to > start + r.location, to - 1 < units.count, units[to - 1] == 10 { to -= 1; nl = true }
            let b = lf.typographicBounds
            let rect = CGRect(x: frag.layoutFragmentFrame.minX + b.minX, y: frag.layoutFragmentFrame.minY + b.minY,
                              width: b.width, height: b.height)
            return VisualLine(from: start + r.location, to: min(to, docLength), frag: frag, line: lf, fragStart: start, rect: rect,
                              endsLogicalLine: nl)
        }
    }

    private func fragment(at pos: Int) -> NSTextLayoutFragment? {
        guard let tlm = tlm, let tcm = tlm.textContentManager else { return nil }
        let clamped = max(0, min(pos, controller?.state.doc.length ?? 0))
        if let loc = tcm.location(tcm.documentRange.location, offsetBy: clamped),
           let f = tlm.textLayoutFragment(for: loc) ?? {
               // not laid out yet (e.g. right after attributes changed): lay out and retry
               if let r = NSTextRange(location: loc, end: tcm.location(loc, offsetBy: min(1, tcm.offset(from: loc, to: tcm.documentRange.endLocation)))) {
                   tlm.ensureLayout(for: r)
               }
               return tlm.textLayoutFragment(for: loc)
           }() {
            if offset(f.rangeInElement.location) <= clamped { return f }
            // TextKit hands back the following paragraph for a position on a
            // paragraph's newline; walk back to the fragment that contains it.
            var prev: NSTextLayoutFragment?
            tlm.enumerateTextLayoutFragments(from: f.rangeInElement.location, options: [.reverse, .ensuresLayout]) { g in
                if self.offset(g.rangeInElement.location) <= clamped { prev = g; return false }
                return true
            }
            if let p = prev { return p }
            return f
        }
        // end of document after a trailing newline: last fragment
        var last: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { f in
            last = f; return false
        }
        return last
    }

    /// The visual line holding `pos` (assoc < 0 prefers the line ending at pos).
    func visualLine(at pos: Int, assoc: Int, state: EditorState) -> VisualLine? {
        guard var frag = fragment(at: pos) else { return nil }
        var ls = lines(of: frag, docLength: state.doc.length)
        if ls.isEmpty, let tlm = tlm {
            // a stale fragment (attributes just changed): lay it out and look again
            tlm.ensureLayout(for: frag.rangeInElement)
            if let f = fragment(at: pos) { frag = f; ls = lines(of: frag, docLength: state.doc.length) }
        }
        guard !ls.isEmpty else { return nil }
        for (i, l) in ls.enumerated() {
            let isLast = i == ls.count - 1
            if pos < l.from { return l }
            if pos < l.to || (pos == l.to && (isLast || assoc < 0 || l.endsLogicalLine)) { return l }
            if isLast { return l }
            // pos == l.to on a wrapped line with assoc >= 0 → start of next line
        }
        return ls.last
    }

    /// Rendered list prefix (bullet / checkbox widget range) containing pos.
    func listPrefix(at pos: Int) -> Widget? {
        controller?.currentPlan?.widgets.first { w in
            switch w.kind {
            case .bullet, .checkbox: return w.from <= pos && pos < w.to
            default: return false
            }
        }
    }

    /// Inside a heading's `#… ` mark drawn in the margin (not revealed).
    func isHiddenHash(_ pos: Int) -> Bool {
        guard let plan = controller?.currentPlan, pos < (controller?.state.doc.length ?? 0) else { return false }
        if case .margin? = plan.style(at: pos).hidden { return true }
        return false
    }

    func caretX(_ pos: Int, in l: VisualLine) -> CGFloat {
        // CM: positions inside the list prefix span sit at the span's left
        // edge, which is the line's left edge (padding and text-indent cancel).
        // The prefix's own (transparent) glyphs start there; the fixed-width box
        // then extends to the content.
        if let w = listPrefix(at: pos), let c = controller {
            var x = c.applier.gutter
            let units = c.state.doc.units
            let font = c.theme.font(size: c.theme.baseSize, weight: 400, mono: false)
            for i in w.from..<pos {
                if units[i] == 9 { x += 4 * c.theme.ch; continue }
                x += (String(utf16CodeUnits: [units[i]], count: 1) as NSString).size(withAttributes: [.font: font]).width
            }
            return x
        }
        return l.rect.minX + l.line.locationForCharacter(at: pos - l.fragStart).x
    }

    /// Nearest caret boundary to x on the visual line (CM posAtCoords).
    func pos(atX x: CGFloat, in l: VisualLine) -> Int {
        var best = l.from, bestD = CGFloat.infinity
        var i = l.from
        let units = controller?.state.doc.units ?? []
        let left = controller?.applier.gutter ?? 0
        while i <= l.to {
            // skip the low half of surrogate pairs
            if i > l.from, i < units.count, (0xDC00...0xDFFF).contains(units[i]) { i += 1; continue }
            // Rendered list prefixes / hidden heading hashes are hit-tested as
            // boxes: only their start (at the very left edge) or the content
            // after them can be reached.
            if let w = listPrefix(at: i) {
                if i > w.from || x > left + 3 { i += 1; continue }
            }
            if isHiddenHash(i) { i += 1; continue }
            let d = abs(caretX(i, in: l) - x)
            if d < bestD { bestD = d; best = i }
            i += 1
        }
        return best
    }

    /// Whether a visual line belongs to a rendered block widget's source.
    func inBlockWidget(_ l: VisualLine, state: EditorState) -> Bool {
        guard let plan = controller?.currentPlan else { return false }
        let line = state.doc.lineAt(l.from)
        return plan.widgetsOverlapping(line.from, line.to).contains { w in
            guard w.replaces && w.from <= line.from && w.to >= line.to && w.to > w.from else { return false }
            if w.block { return true }
            if case .math(_, true) = w.kind { return true }   // display math filling its lines
            return false
        }
    }

    /// Neighbouring visual line, skipping lines hidden inside folded sections.
    private func neighbour(of l: VisualLine, forward: Bool, state: EditorState) -> VisualLine? {
        var cur = l
        for _ in 0..<(state.doc.lines + 1) {
            guard let n = rawNeighbour(of: cur, forward: forward, state: state) else { return nil }
            let idx = state.doc.lineAt(n.from).number - 1
            // CM's vertical motion never lands inside a block widget (table, HR, block image, …): pass over it
            if controller?.applier.foldedLines.contains(idx) != true && !inBlockWidget(n, state: state) { return n }
            cur = n
        }
        return nil
    }

    private func rawNeighbour(of l: VisualLine, forward: Bool, state: EditorState) -> VisualLine? {
        let ls = lines(of: l.frag, docLength: state.doc.length)
        if let idx = ls.firstIndex(where: { $0.from == l.from }) {
            let n = idx + (forward ? 1 : -1)
            if n >= 0 && n < ls.count { return ls[n] }
        }
        guard let tlm = tlm else { return nil }
        var found: NSTextLayoutFragment?
        let selfStart = l.fragStart
        let opts: NSTextLayoutFragment.EnumerationOptions = forward ? [.ensuresLayout] : [.reverse, .ensuresLayout]
        tlm.enumerateTextLayoutFragments(from: l.frag.rangeInElement.location, options: opts) { f in
            let start = self.offset(f.rangeInElement.location)
            if forward ? start > selfStart : start < selfStart { found = f; return false }
            return true
        }
        guard let f = found else { return nil }
        let nls = lines(of: f, docLength: state.doc.length)
        return forward ? nls.first : nls.last
    }

    // MARK: EditorLayout

    func moveVertically(_ state: EditorState, _ range: SelectionRange, forward: Bool) -> SelectionRange {
        guard let l = visualLine(at: range.head, assoc: range.assoc, state: state) else {
            return MonospaceLayout().moveVertically(state, range, forward: forward)
        }
        let goal = range.goalColumn ?? Int(caretX(range.head, in: l).rounded())
        guard let n = neighbour(of: l, forward: forward, state: state) else {
            return forward ? .cursor(state.doc.length, assoc: -1, goalColumn: goal) : .cursor(0, assoc: 1, goalColumn: goal)
        }
        let p = pos(atX: CGFloat(goal), in: n)
        // landing at a wrap point belongs to the upper line
        let assoc = (p == n.to && n.to < state.doc.lineAt(n.from).to) ? -1 : 1
        return .cursor(p, assoc: assoc, goalColumn: goal)
    }

    func moveToLineBoundary(_ state: EditorState, _ range: SelectionRange, forward: Bool, includeWrap: Bool) -> SelectionRange {
        let line = state.doc.lineAt(range.head)
        if ProcessInfo.processInfo.environment["LAYOUT_DEBUG"] != nil, let l = visualLine(at: range.head, assoc: range.assoc, state: state) {
            print("LB head=\(range.head) assoc=\(range.assoc) fwd=\(forward) line=\(l.from)..<\(l.to) fragStart=\(l.fragStart) lf=\(l.line.characterRange)")
        }
        guard includeWrap, let l = visualLine(at: range.head, assoc: range.assoc, state: state) else {
            return .cursor(forward ? line.to : line.from, assoc: forward ? -1 : 1)
        }
        if !forward, l.from == line.from,
           let w = controller?.currentPlan?.widgets.first(where: { w in
               switch w.kind {
               case .checkbox(0, _), .bullet(0): return w.from == line.from
               default: return false
               } }) {
            // posAtCoords at the left edge of a depth-0 list prefix (one right-aligned inline-block, no
            // indent-visual span) lands after its first whitespace run unless that run is the trailing
            // space before the content: "  - x" → 2, "* [ ] x" → 2, "> - x" → 2, "- x" → 0.
            let u = Array(state.sliceDoc(w.from, w.to).utf16)
            var i = 0
            while i < u.count, u[i] != 32 && u[i] != 9 { i += 1 }
            var j = i
            while j < u.count, u[j] == 32 || u[j] == 9 { j += 1 }
            if i < u.count, j < u.count { return .cursor(w.from + j, assoc: 1) }
        }
        return forward ? .cursor(max(l.to, range.head), assoc: -1) : .cursor(min(l.from, range.head), assoc: 1)
    }

    func lineBlockAt(_ state: EditorState, _ pos: Int) -> (from: Int, to: Int) {
        let l = state.doc.lineAt(pos)
        return (l.from, l.to)
    }

    func blockWidgetRanges(_ state: EditorState) -> [BlockWidgetRange] {
        // revealBlockOnArrow: every fold-extension replace widget
        guard let plan = controller?.currentPlan else { return [] }
        return plan.widgets.compactMap { w in
            guard w.replaces else { return nil }
            switch w.kind {
            case .bullet, .checkbox, .tab, .wikiLink: return nil
            default: return BlockWidgetRange(from: w.from, to: w.to)
            }
        }
    }
}

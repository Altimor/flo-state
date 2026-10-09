import Foundation
import FloCore

/// Keeps the render plan up to date by re-planning only the top-level blocks
/// a change or a selection move can affect (planning is independent across
/// top-level markdown blocks), and splicing everything else from the
/// previous plan.
final class PlanCache {
    private(set) var plan: RenderPlan?
    private var last: EditorState?
    /// Set to force the next update to plan the whole document.
    var invalidated = false

    struct Update {
        let plan: RenderPlan
        /// 0-based new-document line ranges that were re-planned (nil = all).
        let dirtyLines: [Range<Int>]?
        /// (first changed line, lines added) for mapping per-line caches, nil if no text change.
        let lineShift: (after: Int, delta: Int, oldFirst: Int, oldLast: Int, newLast: Int)?
        /// The text change since the previous update: old [a, bOld) became new [a, bNew).
        var change: (a: Int, bOld: Int, bNew: Int)? = nil
    }

    func reset() { plan = nil; last = nil }
    /// Start offsets of the tables shown as markdown (the rest are table editors). Mapped through
    /// edits in `update`; changing it needs a full re-plan (`invalidated`).
    var markdownTables = Set<Int>()
    /// Why the last update re-planned the whole document (nil: it was incremental).
    private(set) var fullReason: String?

    func update(_ state: EditorState) -> Update {
        defer { last = state; invalidated = false }
        if !markdownTables.isEmpty, let prev = last, let ch = Self.diff(prev.doc.units, state.doc.units) {
            markdownTables = Set(markdownTables.map { $0 < ch.a ? $0 : $0 >= ch.bOld ? $0 + ch.bNew - ch.bOld : ch.a })
        }
        fullReason = nil
        guard !invalidated, let old = plan, let prev = last, prev.markdown == state.markdown else {
            fullReason = "no previous plan"
            let p = RenderPlanner.plan(state, markdownTables: markdownTables)
            plan = p
            return Update(plan: p, dirtyLines: nil, lineShift: nil,
                          change: last.flatMap { Self.diff($0.doc.units, state.doc.units) })
        }
        let doc = state.doc
        let change = Self.diff(prev.doc.units, doc.units)
        if change == nil && prev.selection == state.selection { return Update(plan: old, dirtyLines: [], lineShift: nil) }
        let delta = change.map { $0.bNew - $0.bOld } ?? 0
        func mapPos(_ p: Int) -> Int {
            guard let c = change else { return p }
            if p <= c.a { return p }
            if p >= c.bOld { return p + delta }
            return c.bNew
        }

        let tops = Self.units(state.tree)
        var regions: [(Int, Int)] = []
        if let c = change {
            let oldTops = Self.units(prev.tree)
            var k = 0
            while k < oldTops.count, k < tops.count, oldTops[k].name == tops[k].name,
                  oldTops[k].from == tops[k].from, oldTops[k].to == tops[k].to, tops[k].to < c.a { k += 1 }
            var m = 0
            while m < oldTops.count - k, m < tops.count - k {
                let o = oldTops[oldTops.count - 1 - m], n = tops[tops.count - 1 - m]
                guard o.name == n.name, o.from + delta == n.from, o.to + delta == n.to, o.from > c.bOld else { break }
                m += 1
            }
            let from = k > 0 ? min(nextLineStart(doc, tops[k - 1].to), c.a) : 0
            let to = m > 0 ? max(doc.lineAt(tops[tops.count - m].from).from, c.bNew) : doc.length
            regions.append(expand(doc, from, to))
        }
        for r in prev.selection.ranges { regions.append(blockRange(doc, tops, mapPos(r.from), mapPos(r.to))) }
        for r in state.selection.ranges { regions.append(blockRange(doc, tops, r.from, r.to)) }
        // + the line above each region: an edit can change what it is (`---` or `===` typed under a
        // paragraph makes it a heading; a delimiter row makes the line above a table header)
        regions = regions.map { r in
            let l = doc.lineAt(r.0)
            return l.from > 0 ? (doc.lineAt(l.from - 1).from, r.1) : r
        }
        var merged = Self.merge(regions)
        // `[[...]]` wiki links may span lines (the web regex allows newlines):
        // grow regions until no link (old or new) crosses a boundary.
        let oldUnits = prev.doc.units, newUnits = doc.units
        func oldPos(_ p: Int) -> Int { guard let c = change else { return p }; return p <= c.a ? p : p - delta }
        for _ in 0..<8 {
            var grown = merged
            for (idx, r) in merged.enumerated() {
                var (a, b) = r
                if let m = Self.wikiSpan(crossing: a, newUnits) { a = min(a, m.0); b = max(b, m.1) }
                if let m = Self.wikiSpan(crossing: b, newUnits) { a = min(a, m.0); b = max(b, m.1) }
                if let m = Self.wikiSpan(crossing: oldPos(r.0), oldUnits) { a = min(a, mapPos(m.0)); b = max(b, mapPos(m.1)) }
                if let m = Self.wikiSpan(crossing: oldPos(r.1), oldUnits) { a = min(a, mapPos(m.0)); b = max(b, mapPos(m.1)) }
                if (a, b) != r { grown[idx] = blockRange(doc, tops, a, b) }
            }
            grown = Self.merge(grown)
            if grown.count == merged.count && zip(grown, merged).allSatisfy({ $0 == $1 }) { break }
            merged = grown
        }
        // A change must sit inside one region (the splice maps old->new around it).
        if let c = change, !merged.contains(where: { $0.0 <= c.a && $0.1 >= c.bNew }) {
            fullReason = "change outside regions \(merged) change \(c)"
            let p = RenderPlanner.plan(state, markdownTables: markdownTables)
            plan = p
            return Update(plan: p, dirtyLines: nil, lineShift: nil, change: change)
        }

        // --- splice ---
        let oldDoc = prev.doc
        var runs: [StyleRun] = []
        var lines: [LineStyle] = []
        var widgets: [Widget] = []
        var hashes = Set<Int>()
        var dirty: [Range<Int>] = []
        runs.reserveCapacity(old.runs.count + 16)
        lines.reserveCapacity(doc.lines)
        var cursor = 0 // new-doc char position covered so far
        var endPlanned = false   // a re-planned region reached the end of the note (its last line included)
        func keep(_ s: Int, _ e: Int, final: Bool = false) {
            // new [s, e) is unchanged text; old coordinates:
            guard s <= e else { return }
            // nothing left after a region that already planned the note's last line (counting it again
            // made the line count wrong, and every edit at the end of a note re-planned the whole note)
            if s == e && endPlanned { return }
            let shift = (change != nil && s >= change!.bNew) ? delta : 0
            let os = s - shift, oe = e - shift
            // runs
            var i = runIndex(old.runs, os)
            while i < old.runs.count, old.runs[i].from < oe {
                var r = old.runs[i]
                r.from = max(r.from, os) + shift; r.to = min(r.to, oe) + shift
                if r.from < r.to { appendRun(&runs, r) }
                i += 1
            }
            // lines starting in [s, e) (e is a line start or the doc end)
            let ls = doc.lineAt(s)
            let nFirst = ls.from == s ? ls.number : ls.number + 1
            // lines starting in [s, e); an empty last line starting exactly at the end of the note is
            // left to whatever comes last (a region that reaches the end, or the final keep)
            let lastFrom = doc.line(doc.lines).from
            let nLast = e >= doc.length ? (lastFrom < e || final ? doc.lines : doc.lines - 1) : doc.lineAt(e).number - 1
            if nFirst <= nLast {
                let lineShift = shift != 0 || (change != nil && s >= change!.bNew) ? doc.lines - oldDoc.lines : 0
                for n in nFirst...nLast {
                    let o = n - lineShift
                    lines.append(old.lines[o - 1])
                    if old.lineNumbersWithRevealedHash.contains(o) { hashes.insert(n) }
                }
            }
            for w in old.widgetsOverlapping(os, oe) where w.from >= os && (w.from < oe || (w.from == oe && oe == oldDoc.length && e == doc.length)) {
                var nw = w; nw.from += shift; nw.to += shift
                widgets.append(nw)
            }
        }
        for (rs, re) in merged {
            keep(cursor, rs)
            let p = RenderPlanner.plan(state, from: rs, to: re, markdownTables: markdownTables)
            for r in p.runs { appendRun(&runs, r) }
            let firstLine = doc.lineAt(rs).number - 1
            lines.append(contentsOf: p.lines)
            // + the line after: its spacing depends on this region's last line (a list right under text)
            dirty.append(firstLine..<min(doc.lines, firstLine + p.lines.count + 1))
            widgets.append(contentsOf: p.widgets)
            hashes.formUnion(p.lineNumbersWithRevealedHash)
            cursor = re
            if re >= doc.length { endPlanned = true }
        }
        keep(cursor, doc.length, final: true)
        guard lines.count == doc.lines else {
            // should not happen; stay correct
            fullReason = "line count \(lines.count) != \(doc.lines) regions=\(merged) change=\(String(describing: change)) oldLen=\(prev.doc.length) newLen=\(doc.length) text=\(doc.string.suffix(40).debugDescription)"
            let p = RenderPlanner.plan(state, markdownTables: markdownTables)
            plan = p
            return Update(plan: p, dirtyLines: nil, lineShift: nil, change: change)
        }
        let p = RenderPlan(runs: runs, lines: lines, widgets: widgets, lineNumbersWithRevealedHash: hashes)
        plan = p
        if Self.verify { Self.check(p, against: RenderPlanner.plan(state, markdownTables: markdownTables), state: state, regions: merged) }
        var shiftInfo: (Int, Int, Int, Int, Int)? = nil
        if let c = change {
            let oldFirst = oldDoc.lineAt(c.a).number - 1
            let oldLast = oldDoc.lineAt(c.bOld).number - 1
            let newLast = doc.lineAt(c.bNew).number - 1
            shiftInfo = (oldFirst, newLast - oldLast, oldFirst, oldLast, newLast)
        }
        return Update(plan: p, dirtyLines: dirty, lineShift: shiftInfo, change: change)
    }

    // MARK: verification (FLO_VERIFY_PLAN=1): incremental == full

    static let verify = ProcessInfo.processInfo.environment["FLO_VERIFY_PLAN"] != nil
    static var mismatches = 0

    static func check(_ p: RenderPlan, against f: RenderPlan, state: EditorState, regions: [(Int, Int)]) {
        var problems: [String] = []
        if p.lines != f.lines {
            let i = (0..<min(p.lines.count, f.lines.count)).first { p.lines[$0] != f.lines[$0] } ?? min(p.lines.count, f.lines.count)
            problems.append("lines differ at \(i) (count \(p.lines.count) vs \(f.lines.count))")
        }
        // compare per-char styles
        let n = state.doc.length
        var pi = 0, fi = 0
        for pos in 0..<n {
            while pi < p.runs.count && p.runs[pi].to <= pos { pi += 1 }
            while fi < f.runs.count && f.runs[fi].to <= pos { fi += 1 }
            let a = pi < p.runs.count ? p.runs[pi].style : nil, b = fi < f.runs.count ? f.runs[fi].style : nil
            if a != b { problems.append("style differs at \(pos)"); break }
        }
        let wa = Set(p.widgets.map { "\($0)" }), wb = Set(f.widgets.map { "\($0)" })
        if wa != wb { problems.append("widgets differ: +\(wa.subtracting(wb).prefix(2)) -\(wb.subtracting(wa).prefix(2))") }
        if p.lineNumbersWithRevealedHash != f.lineNumbersWithRevealedHash { problems.append("hash lines differ") }
        if !problems.isEmpty {
            mismatches += 1
            print("PLAN MISMATCH regions=\(regions) sel=\(state.selection.main.head): " + problems.joined(separator: "; "))
        }
    }

    // MARK: helpers

    /// The blocks an edit re-plans: top-level blocks, except that a list counts item by item. A keystroke
    /// in a note that's one long list re-planned the whole list (hundreds of lines) every time.
    static func units(_ tree: SyntaxTree) -> [SyntaxNode] {
        var out: [SyntaxNode] = []
        for n in tree.root.children {
            if n.name == "BulletList" || n.name == "OrderedList" {
                let items = n.children.filter { $0.name == "ListItem" }
                if items.count == n.children.count, !items.isEmpty { out.append(contentsOf: items); continue }
            }
            out.append(n)
        }
        return out
    }

    static func merge(_ regions: [(Int, Int)]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for r in regions.sorted(by: { $0.0 < $1.0 }) {
            if let l = out.last, r.0 <= l.1 { out[out.count - 1].1 = max(l.1, r.1) } else { out.append(r) }
        }
        return out
    }

    /// A `[[x]]` match (no `]` inside) with `[[` before `b` and `]]` at/after `b`.
    static func wikiSpan(crossing b: Int, _ u: [UInt16]) -> (Int, Int)? {
        let open: UInt16 = 91, close: UInt16 = 93
        guard b > 1, b < u.count else { return nil }
        var i = b - 1
        var start: Int? = nil
        while i >= 1 {
            if u[i] == close { return nil }
            if u[i] == open && u[i - 1] == open { start = i - 1; break }
            i -= 1
        }
        guard let s = start else { return nil }
        var j = b
        while j < u.count {
            if u[j] == close {
                return j + 1 < u.count && u[j + 1] == close && j > s + 2 ? (s, j + 2) : nil
            }
            j += 1
        }
        return nil
    }

    private func appendRun(_ runs: inout [StyleRun], _ r: StyleRun) {
        if let l = runs.last, l.to == r.from, l.style == r.style { runs[runs.count - 1].to = r.to } else { runs.append(r) }
    }

    private func runIndex(_ runs: [StyleRun], _ pos: Int) -> Int {
        var lo = 0, hi = runs.count
        while lo < hi { let m = (lo + hi) / 2; if runs[m].to <= pos { lo = m + 1 } else { hi = m } }
        return lo
    }

    private func nextLineStart(_ doc: Text, _ pos: Int) -> Int {
        let l = doc.lineAt(min(pos, doc.length))
        return min(doc.length, l.to + 1)
    }

    /// Snap [from, to) to line starts (to = next line start, or doc end).
    private func expand(_ doc: Text, _ from: Int, _ to: Int) -> (Int, Int) {
        let f = doc.lineAt(max(0, min(from, doc.length))).from
        let tl = doc.lineAt(max(0, min(to, doc.length)))
        let t = (to == tl.from && to > f) ? to : min(doc.length, tl.to + 1)
        return (f, max(f, t))
    }

    /// The top-level block(s) around [from, to], or the blank gap between blocks.
    private func blockRange(_ doc: Text, _ tops: [SyntaxNode], _ from: Int, _ to: Int) -> (Int, Int) {
        var lo = 0, hi = tops.count
        while lo < hi { let m = (lo + hi) / 2; if tops[m].to < from { lo = m + 1 } else { hi = m } }
        var a = from, b = to
        var i = lo
        // blocks overlapping [from, to]
        while i < tops.count, tops[i].from <= to {
            a = min(a, tops[i].from); b = max(b, tops[i].to)
            i += 1
        }
        return expand(doc, a, b)
    }

    /// Common prefix/suffix diff: changed [a, bOld) in old became [a, bNew) in new.
    static func diff(_ old: [UInt16], _ new: [UInt16]) -> (a: Int, bOld: Int, bNew: Int)? {
        if old.count == new.count && old == new { return nil }
        return old.withUnsafeBufferPointer { o in
            new.withUnsafeBufferPointer { n in
                var a = 0
                let minLen = min(o.count, n.count)
                while a < minLen && o[a] == n[a] { a += 1 }
                var s = 0
                while s < o.count - a && s < n.count - a && o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
                return (a, o.count - s, n.count - s)
            }
        }
    }
}

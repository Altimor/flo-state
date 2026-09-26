import AppKit
import FloCore

/// Heading-section folding (heading-fold.ts): a section runs from the end of a
/// heading line to the end of the last line before the next heading of the
/// same or shallower depth (or the document end). Folded sections are hidden
/// and atomic for the caret.
public struct Fold: Equatable {
    public var from: Int
    public var to: Int
}

enum HeadingSections {
    /// `/^(#{1,6})\s/` on the raw line text (like the web, even inside code).
    static func depth(_ units: [UInt16], _ from: Int, _ to: Int) -> Int {
        var n = 0
        var i = from
        while i < to, units[i] == 35, n < 7 { n += 1; i += 1 }
        guard n >= 1, n <= 6, i < to else { return 0 }
        let c = units[i]
        return (c == 32 || c == 9 || c == 13 || c == 12 || c == 11 || c == 0xA0 || c == 0x2028 || c == 0x2029 || c == 0xFEFF) ? n : 0
    }

    /// Foldable sections keyed by heading line number (1-based).
    static func all(_ doc: Text) -> [Int: Fold] {
        let u = doc.units
        var depths = [Int](repeating: 0, count: doc.lines + 1)
        for n in 1...doc.lines {
            let l = doc.lineStarts[n - 1]
            let e = n < doc.lines ? doc.lineStarts[n] - 1 : u.count
            depths[n] = depth(u, l, e)
        }
        var out: [Int: Fold] = [:]
        // stack of open headings (line, depth)
        var stack: [(Int, Int)] = []
        func close(_ line: Int, endLine: Int) {
            if endLine > line {
                out[line] = Fold(from: lineEnd(doc, line), to: lineEnd(doc, endLine))
            }
        }
        for n in 1...doc.lines where depths[n] > 0 {
            while let top = stack.last, top.1 >= depths[n] {
                stack.removeLast()
                close(top.0, endLine: n - 1)
            }
            stack.append((n, depths[n]))
        }
        for (line, _) in stack { close(line, endLine: doc.lines) }
        return out
    }

    static func lineEnd(_ doc: Text, _ n: Int) -> Int {
        n < doc.lines ? doc.lineStarts[n] - 1 : doc.length
    }
}

extension EditorController {
    /// Toggle the section under the heading on `lineNumber` (1-based).
    @discardableResult
    public func toggleFold(line lineNumber: Int) -> Bool {
        guard let s = foldSections[lineNumber] else { return false }
        if let i = folds.firstIndex(where: { $0.from == s.from }) {
            setFolds(folds.enumerated().filter { $0.offset != i }.map { $0.element })
        } else {
            setFolds(folds + [s])
        }
        return true
    }

    /// Collapse every section of depth ≥ 2 (the `#` title is left alone).
    @discardableResult
    public func collapseAllHeadings() -> Bool {
        let doc = state.doc
        var add: [Fold] = []
        for (line, s) in foldSections {
            let l = doc.line(line)
            if HeadingSections.depth(doc.units, l.from, l.to) >= 2, !folds.contains(where: { $0.from == s.from && $0.to == s.to }) {
                add.append(s)
            }
        }
        if add.isEmpty && folds.isEmpty { return false }
        setFolds(folds + add)
        return true
    }

    @discardableResult
    public func expandAllHeadings() -> Bool {
        guard !folds.isEmpty else { return false }
        setFolds([])
        return true
    }

    /// Fold / unfold the section containing the caret (Cmd-Alt-[ / ]).
    public func foldAtCaret(_ fold: Bool) -> Bool {
        let head = state.selection.main.head
        let line = state.doc.lineAt(head).number
        // innermost section whose heading is at or above the caret
        let candidates = foldSections.filter { $0.key == line || ($0.value.from < head && head <= $0.value.to) }
        guard let best = candidates.max(by: { $0.key < $1.key }) else { return false }
        let existing = folds.firstIndex { $0.from == best.value.from }
        if fold, existing == nil { setFolds(folds + [best.value]); return true }
        if !fold, let i = existing { var f = folds; f.remove(at: i); setFolds(f); return true }
        return false
    }

    /// The chevron's 1em box in text-view coordinates for a heading line:
    /// `right: 100%; margin-right: 0.55em`, centred at pad-top + 0.5lh + 4px.
    func chevronRect(line: Int) -> CGRect? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager, line <= state.doc.lines else { return nil }
        let pos = state.doc.line(line).from
        guard let loc = tcm.location(tcm.documentRange.location, offsetBy: pos), let f = tlm.textLayoutFragment(for: loc),
              let lf = f.textLineFragments.first else { return nil }
        let em = headingFontSize(line)
        let left = textView.textContainerOrigin.x + applier.gutter
        let top = textView.textContainerOrigin.y + f.layoutFragmentFrame.minY + lf.typographicBounds.minY
        let cy = top + lf.typographicBounds.height / 2 + 4
        return CGRect(x: left - 0.55 * em - em, y: cy - em / 2, width: em, height: em)
    }

    func headingFontSize(_ line: Int) -> CGFloat {
        guard let plan = currentPlan else { return theme.baseSize }
        let l = state.doc.line(line)
        var size = theme.baseSize
        var p = l.from
        while p < l.to {
            let st = plan.style(at: p)
            if st.hidden == nil { size = max(size, theme.baseSize * CGFloat(st.sizeEm)) }
            p += 1
            if p - l.from > 40 { break }
        }
        return size
    }

    /// Move carets out of folded ranges (they're atomic, like CM fold widgets).
    func clampSelectionOutOfFolds(forward: Bool) {
        guard !folds.isEmpty else { return }
        var changed = false
        let ranges = state.selection.ranges.map { r -> SelectionRange in
            var r = r
            for f in folds where r.head > f.from && r.head < f.to {
                r = r.empty ? .cursor(forward ? f.to : f.from) : SelectionRange.range(r.anchor, forward ? f.to : f.from)
                changed = true
            }
            return r
        }
        guard changed else { return }
        let before = state
        session.dispatch(TransactionSpec(selection: EditorSelection(ranges: ranges, mainIndex: state.selection.mainIndex),
                                         userEvent: "select", addToHistory: false))
        sync(from: before)
    }
}

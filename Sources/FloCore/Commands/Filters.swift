import Foundation

// Transaction filters: heading-decorations.ts `headingSelectionGuard` and
// list/index.ts `listPrefixSelectionGuard`. Each returns the replacement
// selection, or nil to leave the transaction alone.

struct NoGoZone { let from: Int; let to: Int }

enum Headings {
    static let MAX_HEADING_HASH_PREFIX = 7

    static func isATX(_ name: String) -> Bool {
        name.count == 11 && name.hasPrefix("ATXHeading") && ("1"..."6").contains(name.last!)
    }

    static func findHeadingHashEnd(_ node: SyntaxNode) -> Int? {
        guard let first = node.cmFirstChild, first.name == "HeaderMark" else { return nil }
        return min(first.to + 1, node.to)
    }

    static func collectHeadingNoGoZones(_ state: EditorState) -> [NoGoZone] {
        var zones: [NoGoZone] = []
        state.tree.iterate(enter: { node, _ in
            if !isATX(node.name) { return true }
            guard let hashEnd = findHeadingHashEnd(node) else { return false }
            let lineFrom = state.doc.lineAt(node.from).from
            zones.append(NoGoZone(from: lineFrom, to: hashEnd))
            return false
        })
        return zones
    }

    static func couldBeInZone(_ state: EditorState, _ pos: Int) -> Bool {
        let line = state.doc.lineAt(pos)
        return pos - line.from <= MAX_HEADING_HASH_PREFIX
    }

    static func anySelectionEndpointCouldBeInZone(_ state: EditorState, _ sel: EditorSelection) -> Bool {
        for r in sel.ranges {
            if couldBeInZone(state, r.anchor) || couldBeInZone(state, r.head) { return true }
        }
        return false
    }

    static func clampRangesToZones(_ ranges: [SelectionRange], _ zones: [NoGoZone]) -> (changed: Bool, ranges: [SelectionRange]) {
        var changed = false
        let fixed = ranges.map { r -> SelectionRange in
            var anchor = r.anchor, head = r.head
            for z in zones {
                if anchor >= z.from && anchor < z.to { anchor = z.to; changed = true }
                if head >= z.from && head < z.to { head = z.to; changed = true }
            }
            return SelectionRange.range(anchor, head)
        }
        return (changed, fixed)
    }

    /// `findZoneEndingAt` for the escape-left bindings.
    static func findZoneEndingAt(_ state: EditorState, _ pos: Int) -> NoGoZone? {
        let line = state.doc.lineAt(pos)
        if pos - line.from > MAX_HEADING_HASH_PREFIX { return nil }
        return collectHeadingNoGoZones(state).first { $0.to == pos }
    }

    /// `clampSelectionToHeadings(view)` for mount/swap paths.
    public static func clampSelection(_ state: EditorState) -> EditorSelection? {
        let sel = state.selection
        if !anySelectionEndpointCouldBeInZone(state, sel) { return nil }
        let zones = collectHeadingNoGoZones(state)
        if zones.isEmpty { return nil }
        let r = clampRangesToZones(sel.ranges, zones)
        return r.changed ? EditorSelection.create(r.ranges, mainIndex: sel.mainIndex) : nil
    }
}

struct ParsedBulletTaskLine {
    let lineFrom: Int
    let markerFrom: Int
    let bodyFrom: Int
    let indentLen: Int
    let markerLen: Int
    let isTask: Bool
}

enum ListLines {
    /// `/^([ \t]*)([-+*]) (\[[ xX]\] )?/`
    static let BULLET_TASK_LINE_RE = JSRegex("^([ \\t]*)([-+*]) (\\[[ xX]\\] )?")

    static func parseBulletTaskLine(_ line: Line) -> ParsedBulletTaskLine? {
        guard let m = BULLET_TASK_LINE_RE.exec(line.text) else { return nil }
        let indentLen = m.len(1)
        let markerLen = m.length - indentLen
        return ParsedBulletTaskLine(lineFrom: line.from, markerFrom: line.from + indentLen,
                                    bodyFrom: line.from + m.length, indentLen: indentLen,
                                    markerLen: markerLen, isTask: m[3] != nil)
    }

    static func parseBulletTaskLineAt(_ state: EditorState, _ pos: Int) -> ParsedBulletTaskLine? {
        let line = state.doc.lineAt(pos)
        guard let p = parseBulletTaskLine(line) else { return nil }
        if pos > line.to { return nil }
        return p
    }

    static func clampCollapsedListPrefixRange(_ state: EditorState, _ range: SelectionRange) -> SelectionRange? {
        if !range.empty { return nil }
        guard let parsed = parseBulletTaskLineAt(state, range.head) else { return nil }
        var pos = range.head
        if pos > parsed.lineFrom && pos < parsed.markerFrom {
            pos = parsed.markerFrom
        } else if pos > parsed.markerFrom && pos < parsed.bodyFrom {
            pos = parsed.bodyFrom
        } else {
            return nil
        }
        return SelectionRange.cursor(pos)
    }
}

enum Filters {
    static func headingSelectionGuard(_ tr: Transaction) -> EditorSelection? {
        guard tr.selectionSet else { return nil }
        let sel = tr.state.selection
        if !Headings.anySelectionEndpointCouldBeInZone(tr.state, sel) { return nil }
        let zones = Headings.collectHeadingNoGoZones(tr.state)
        if zones.isEmpty { return nil }
        let r = Headings.clampRangesToZones(sel.ranges, zones)
        if !r.changed { return nil }
        return EditorSelection.create(r.ranges, mainIndex: sel.mainIndex)
    }

    static func listPrefixSelectionGuard(_ tr: Transaction) -> EditorSelection? {
        guard tr.selectionSet else { return nil }
        let sel = tr.state.selection
        var changed = false
        let ranges = sel.ranges.map { r -> SelectionRange in
            if let c = ListLines.clampCollapsedListPrefixRange(tr.state, r) { changed = true; return c }
            return r
        }
        if !changed { return nil }
        return EditorSelection.create(ranges, mainIndex: sel.mainIndex)
    }
}

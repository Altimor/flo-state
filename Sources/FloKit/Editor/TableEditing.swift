import AppKit
import FloCore

/// Document side of the table editor (TableOverlay): markdown mode per table, inserting a table,
/// and keeping the caret out of the hidden markdown of rendered tables.
extension EditorController {
    /// The rendered table (editor mode) whose source contains `pos`.
    func renderedTable(containing pos: Int) -> (from: Int, to: Int)? {
        guard let plan = currentPlan else { return nil }
        for w in plan.widgetsOverlapping(max(0, pos - 1), pos + 1) {
            if case .table = w.kind, w.block, w.replaces, w.from <= pos, pos <= w.to { return (w.from, w.to) }
        }
        return nil
    }

    /// The table node (any mode) containing `pos`.
    func tableNode(containing pos: Int) -> (from: Int, to: Int)? {
        var found: (Int, Int)? = nil
        state.tree.iterate(from: pos, to: pos, enter: { n, _ in
            if n.name == "Table" { found = (n.from, n.to); return false }
            return true
        })
        return found
    }

    public var markdownTables: Set<Int> { planCache.markdownTables }

    /// Repaint a rendered table now (editing a cell hides its drawn text). Invalidating its layout or
    /// needsDisplay leave the cached fragment drawing on screen; re-applying the line's attributes (a
    /// text storage edit, as typing does) makes TextKit redraw it.
    func redrawTable(at from: Int) {
        guard from <= state.doc.length else { return }
        forceLines.insert(state.doc.lineAt(from).number - 1)
        render()
    }

    /// Show a table as markdown source (`on`) or as the table editor again.
    public func setTableMarkdownMode(_ from: Int, _ on: Bool) {
        if on { planCache.markdownTables.insert(from) } else { planCache.markdownTables.remove(from) }
        render(force: true)
        if on {
            // put the caret in the table so it can be edited straight away
            let line = state.doc.lineAt(from)
            _ = run(scroll: false) { t in t.dispatch(TransactionSpec(selection: .cursor(line.to))); return true }
        }
        MainActor.assumeIsolated { tableOverlay?.scheduleSync() }
    }

    /// Insert an empty `rows` × `columns` table (header row included) on its own lines at the caret,
    /// and start editing its first cell.
    public func insertTable(rows: Int, columns: Int) {
        let md = TableGrid.empty(rows: rows, columns: columns).markdown
        var tableFrom = 0
        _ = run { t in
            let st = t.state
            let line = st.doc.lineAt(st.selection.main.head)
            let blank = line.text.trimmingCharacters(in: .whitespaces).isEmpty
            let at = blank ? line.from : line.to
            let before = blank ? "" : "\n\n"
            let after = at < st.doc.length && !blank ? "\n" : "\n"
            tableFrom = at + (before as NSString).length
            let insert = before + md + after
            t.dispatch(TransactionSpec(changes: [Change(from: blank ? line.from : at, to: blank ? line.to : at, insert: insert)],
                                       selection: .cursor(tableFrom + (md as NSString).length + 1), userEvent: "input.table"))
            return true
        }
        let from = tableFrom
        MainActor.assumeIsolated {
            tableOverlay?.pendingEdit = (from, 0, 0)
            tableOverlay?.scheduleSync()
        }
    }

    /// After a render: the overlay follows the tables, and an empty caret that landed inside a rendered
    /// table's (hidden) markdown moves past it, in the direction it was going.
    func afterRenderTables() {
        MainActor.assumeIsolated { tableOverlay?.scheduleSync() }
        let sel = state.selection.main
        defer { tableEscapeLastHead = state.selection.main.head }
        guard sel.empty, let t = renderedTable(containing: sel.head) else { return }
        let len = state.doc.length
        let forward = sel.head > tableEscapeLastHead || tableEscapeLastHead < t.from
        let target = forward ? (t.to < len ? t.to + 1 : t.to) : (t.from > 0 ? t.from - 1 : 0)
        guard target < t.from || target > t.to else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.selection.main.empty, self.renderedTable(containing: self.state.selection.main.head) != nil else { return }
            _ = self.run { tr in tr.dispatch(TransactionSpec(selection: .cursor(target))); return true }
        }
    }
}

/// "Insert ▸ Table" in the context menu: hover a grid to pick the size, click to insert.
final class TableSizePicker: NSView {
    static let maxRows = 8, maxCols = 8
    private let cellSize: CGFloat = 16, gap: CGFloat = 3, pad: CGFloat = 12
    private var hover = (rows: 3, cols: 3)
    var onPick: ((Int, Int) -> Void)?
    private let label = NSTextField(labelWithString: "")

    init() {
        let w = pad * 2 + CGFloat(Self.maxCols) * (cellSize + gap) - gap
        let h = pad * 2 + CGFloat(Self.maxRows) * (cellSize + gap) - gap + 22
        super.init(frame: CGRect(x: 0, y: 0, width: w, height: h))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = CGRect(x: 0, y: h - pad - 16, width: w, height: 16)
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func updateLabel() { label.stringValue = "\(hover.rows) × \(hover.cols)" }

    private func cell(at p: CGPoint) -> (Int, Int) {
        let c = Int((p.x - pad) / (cellSize + gap)) + 1, r = Int((p.y - pad) / (cellSize + gap)) + 1
        return (max(1, min(Self.maxRows, r)), max(1, min(Self.maxCols, c)))
    }

    override func mouseMoved(with event: NSEvent) {
        let (r, c) = cell(at: convert(event.locationInWindow, from: nil))
        if (r, c) != hover { hover = (r, c); updateLabel(); needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let (r, c) = cell(at: convert(event.locationInWindow, from: nil))
        enclosingMenuItem?.menu?.cancelTracking()
        let pick = onPick
        DispatchQueue.main.async { pick?(r, c) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for r in 0..<Self.maxRows {
            for c in 0..<Self.maxCols {
                let rect = CGRect(x: pad + CGFloat(c) * (cellSize + gap), y: pad + CGFloat(r) * (cellSize + gap), width: cellSize, height: cellSize)
                let on = r < hover.rows && c < hover.cols
                (on ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.quaternaryLabelColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                if on {
                    NSColor.controlAccentColor.setStroke()
                    let b = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); b.lineWidth = 1; b.stroke()
                }
            }
        }
    }
}

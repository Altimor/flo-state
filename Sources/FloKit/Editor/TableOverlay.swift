import AppKit
import FloCore

private var tableOverlayKey: UInt8 = 0

/// The table editor: a transparent view over each rendered table (the table itself is still drawn
/// by its layout fragment). Click a cell to edit it (Tab / Shift-Tab / Enter / arrows move between
/// cells), drag the handles beside a row or above a column to move it, drag a column's right
/// border to resize it (double-click it: automatic widths again), right-click for the rest.
/// Every edit rewrites the table's markdown in one transaction (TableGrid).
@MainActor
final class TableOverlay {
    weak var editor: EditorController?
    private var views: [TableOverlayView] = []
    private var syncScheduled = false
    /// A table just inserted: start editing its first cell once its view exists.
    var pendingEdit: (from: Int, row: Int, col: Int)?

    init(editor: EditorController) { self.editor = editor }

    /// The cell being edited in the table starting at `from` (not drawn by the text: the field covers it).
    func editingCell(tableAt from: Int) -> (Int, Int)? {
        views.first { $0.from == from }?.editingCell.map { ($0.row, $0.col) }
    }

    func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.sync()
        }
    }

    /// The table views over the plan's rendered tables (reused in order, so an edit in progress survives).
    func sync() {
        guard let editor = editor, let plan = editor.currentPlan, let tlm = editor.textView.textLayoutManager,
              let tcm = tlm.textContentManager else { return }
        let tv = editor.textView
        var next: [TableOverlayView] = []
        var pool = views
        for w in plan.widgets {
            // the very layout the text draws (stored on the line): a fresh one at the current column width
            // differs after a resize until the line is re-applied, and the field landed over the wrong cells
            guard case .table(let source) = w.kind, w.to > w.from, w.to <= editor.state.doc.length,
                  let layout = ((tv.textStorage?.length ?? 0) > w.from ? tv.textStorage?.attribute(.floWidget, at: w.from, effectiveRange: nil) as? WidgetBox : nil)?.table
                      ?? editor.applier.tables.layout(source: source, theme: editor.theme, available: editor.applier.columnWidth),
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: w.from) else { continue }
            if let r = NSTextRange(location: loc, end: tcm.location(loc, offsetBy: 1)) { tlm.ensureLayout(for: r) }
            guard let frag = tlm.textLayoutFragment(for: loc), let line = frag.textLineFragments.first else { continue }
            let origin = tv.textContainerOrigin
            let tableOrigin = CGPoint(x: origin.x + editor.applier.gutter,
                                      y: origin.y + frag.layoutFragmentFrame.minY + line.typographicBounds.minY + layout.tableTop)
            let view: TableOverlayView
            if let i = pool.firstIndex(where: { $0.from == w.from }) ?? (pool.isEmpty ? nil : 0) {
                view = pool.remove(at: i)
            } else {
                view = TableOverlayView(overlay: self)
                tv.addSubview(view)
            }
            view.update(from: w.from, to: w.to, source: source, layout: layout, tableOrigin: tableOrigin)
            next.append(view)
        }
        for v in pool { v.removeFromSuperview() }
        views = next
        if let p = pendingEdit, let v = views.first(where: { $0.from == p.from }) {
            pendingEdit = nil
            v.beginEditing(row: p.row, col: p.col)
        }
    }

    /// Replace a table's markdown (one undoable edit); the caret stays out of the table.
    func write(_ grid: TableGrid, from: Int, to: Int) {
        guard let editor = editor else { return }
        let md = grid.markdown
        editor.run(scroll: false) { t in
            var sel = t.state.selection
            let len = (md as NSString).length
            if sel.main.head > to { sel = .cursor(sel.main.head + len - (to - from)) }
            else if sel.main.head >= from { sel = .cursor(from + len) }
            t.dispatch(TransactionSpec(changes: [Change(from: from, to: to, insert: md)], selection: sel, userEvent: "input.table"))
            return true
        }
    }

    func setMarkdownMode(_ from: Int) { editor?.setTableMarkdownMode(from, true) }

    func delete(from: Int, to: Int) {
        guard let editor = editor else { return }
        let doc = editor.state.doc
        // the table's lines and the newline after them
        let end = to < doc.length ? to + 1 : to
        editor.run(scroll: false) { t in
            t.dispatch(TransactionSpec(changes: [Change(from: from, to: end)], selection: .cursor(from), userEvent: "delete.table"))
            return true
        }
    }
}

extension EditorController {
    var tableOverlay: TableOverlay? {
        MainActor.assumeIsolated {
            if let o = objc_getAssociatedObject(self, &tableOverlayKey) as? TableOverlay { return o }
            let o = TableOverlay(editor: self)
            objc_setAssociatedObject(self, &tableOverlayKey, o, .OBJC_ASSOCIATION_RETAIN)
            // follow the text view's size changes (window resize, sidebar): the column moves without a render
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak o] _ in
                MainActor.assumeIsolated { o?.scheduleSync() }
            }
            return o
        }
    }
}

// MARK: - one table

@MainActor
final class TableOverlayView: NSView, NSTextViewDelegate {
    private weak var overlay: TableOverlay?
    private(set) var from = 0
    private var to = 0
    private var source = ""
    private(set) var layout: TableLayout!
    private var grid: TableGrid!
    /// Room around the table for the row / column handles.
    static let margin = CGSize(width: 22, height: 18)

    private var hoverRow: Int?
    private var hoverCol: Int?
    private var resizeCol: Int?
    private enum Drag { case resize(col: Int, startX: CGFloat, widths: [CGFloat], current: CGFloat)
                        case row(from: Int, target: Int), col(from: Int, target: Int) }
    private var drag: Drag?
    private var editorField: CellEditor?
    private var editing: (row: Int, col: Int)?
    private var tracking: NSTrackingArea?

    init(overlay: TableOverlay) {
        self.overlay = overlay
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    private var theme: EditorTheme { overlay?.editor?.theme ?? EditorTheme() }
    private var tableRect: CGRect { CGRect(origin: CGPoint(x: Self.margin.width, y: Self.margin.height), size: layout.size) }

    func update(from: Int, to: Int, source: String, layout: TableLayout, tableOrigin: CGPoint) {
        let changed = source != self.source
        self.from = from; self.to = to; self.source = source; self.layout = layout
        if changed || grid == nil { grid = TableGrid(markdown: source) ?? TableGrid.empty(rows: 1, columns: 1) }
        let f = CGRect(x: tableOrigin.x - Self.margin.width, y: tableOrigin.y - Self.margin.height,
                       width: layout.size.width + Self.margin.width + 8, height: layout.size.height + Self.margin.height + 8)
        if frame != f { frame = f }
        window?.invalidateCursorRects(for: self)
        if let e = editing, let field = editorField {
            if e.row < layout.cells.count, e.col < layout.cells[e.row].count { field.frame = fieldFrame(e.row, e.col) }
            else { endEditing(commit: false) }
        }
        needsDisplay = true
    }

    // MARK: geometry

    /// The cell being edited (tests).
    var editingCell: (row: Int, col: Int)? { editing }
    func cellRect(_ r: Int, _ c: Int) -> CGRect { cellFrame(r, c) }
    func columnHandleRect(_ c: Int) -> CGRect { colHandle(c) }
    func rowHandleRect(_ r: Int) -> CGRect { rowHandle(r) }

    private func cellFrame(_ r: Int, _ c: Int) -> CGRect { layout.cells[r][c].frame.offsetBy(dx: Self.margin.width, dy: Self.margin.height) }
    private var columnWidths: [CGFloat] { layout.cells.first?.map { $0.frame.width } ?? [] }

    private func cell(at p: CGPoint) -> (Int, Int)? {
        for (r, row) in layout.cells.enumerated() {
            for (c, _) in row.enumerated() where cellFrame(r, c).contains(p) { return (r, c) }
        }
        return nil
    }

    /// The column whose right border is under `p` (resize target).
    private func border(at p: CGPoint) -> Int? {
        guard tableRect.insetBy(dx: -4, dy: 0).contains(p) else { return nil }
        for c in columnWidths.indices {
            let x = cellFrame(0, c).maxX
            if abs(p.x - x) <= 4 { return c }
        }
        return nil
    }

    private func rowHandle(_ r: Int) -> CGRect {
        let f = cellFrame(r, 0)
        return CGRect(x: Self.margin.width - 18, y: f.midY - 9, width: 14, height: 18)
    }
    private func colHandle(_ c: Int) -> CGRect {
        let f = cellFrame(0, c)
        return CGRect(x: f.midX - 9, y: Self.margin.height - 15, width: 18, height: 12)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard layout != nil, let sup = superview else { return nil }
        let p = convert(point, from: sup)
        // right-click / ctrl-click on the cell being edited: the table menu, not the field's Cut/Copy/Paste
        let ev = NSApp.currentEvent
        let menuClick = ev?.type == .rightMouseDown || (ev?.type == .leftMouseDown && ev?.modifierFlags.contains(.control) == true)
        if let f = editorField, f.frame.contains(p), !menuClick { return super.hitTest(point) }
        if tableRect.insetBy(dx: -4, dy: 0).contains(p) { return self }
        if rowBand(at: p) != nil || colBand(at: p) != nil { return self }
        if drag != nil { return self }
        return nil
    }

    // MARK: hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// The row whose band left of the table (handle up to the table edge) holds `p`: the pointer can
    /// travel from a cell to its row handle without the handle disappearing on the way.
    private func rowBand(at p: CGPoint) -> Int? {
        guard p.x >= rowHandle(0).minX - 4, p.x <= tableRect.minX + 1 else { return nil }
        return layout.cells.indices.first { r in let f = cellFrame(r, 0); return p.y >= f.minY && p.y < f.maxY }
    }
    /// The column whose band above the table holds `p`.
    private func colBand(at p: CGPoint) -> Int? {
        guard p.y >= colHandle(0).minY - 4, p.y <= tableRect.minY + 1 else { return nil }
        return columnWidths.indices.first { c in let f = cellFrame(0, c); return p.x >= f.minX && p.x < f.maxX }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var r = hoverRow, c = hoverCol
        if let (cr, cc) = cell(at: p) { r = cr; c = cc }
        else if let br = rowBand(at: p) { r = br }
        else if let bc = colBand(at: p) { c = bc }
        else { r = nil; c = nil }
        let b = border(at: p)
        if r != hoverRow || c != hoverCol || b != resizeCol { hoverRow = r; hoverCol = c; resizeCol = b; needsDisplay = true }
        if b != nil { NSCursor.resizeLeftRight.set() }
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        hoverRow = nil; hoverCol = nil; resizeCol = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        if resizeCol != nil || drag.map({ if case .resize = $0 { return true }; return false }) == true { NSCursor.resizeLeftRight.set() }
    }

    /// The text view under the table keeps resetting its I-beam from its cursor rects; ours win over it:
    /// ↔ on every column border, the arrow on the handle strips.
    override func resetCursorRects() {
        for (rect, cursor) in cursorRegions() { addCursorRect(rect, cursor: cursor) }
    }

    /// ↔ on every column border; the regular arrow on the row-handle strip (left of the table) and the
    /// column-handle strip (above it). Cells keep the text view's I-beam (they're text to click into).
    func cursorRegions() -> [(CGRect, NSCursor)] {
        guard layout != nil else { return [] }
        var out: [(CGRect, NSCursor)] = columnWidths.indices.map { c in
            let x = cellFrame(0, c).maxX
            return (CGRect(x: x - 4, y: tableRect.minY, width: 8, height: tableRect.height), .resizeLeftRight)
        }
        out.append((CGRect(x: 0, y: tableRect.minY, width: tableRect.minX - 4, height: tableRect.height), .arrow))
        out.append((CGRect(x: tableRect.minX, y: 0, width: tableRect.width, height: tableRect.minY), .arrow))
        return out
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if editing != nil, !(editorField?.frame.contains(p) ?? false) { endEditing(commit: true) }
        if let c = border(at: p) {
            if event.clickCount == 2 { var g = grid!; g.setWidths(nil, unit: Double(TableLayout.widthUnit(theme))); commit(g); return }
            drag = .resize(col: c, startX: p.x, widths: columnWidths, current: columnWidths[c])
            return
        }
        if let r = rowBand(at: p), p.x < tableRect.minX { drag = .row(from: r, target: r); return }
        if let c = colBand(at: p), p.y < tableRect.minY { drag = .col(from: c, target: c); return }
        if let (r, c) = cell(at: p) { beginEditing(row: r, col: c) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .resize(let col, let startX, let widths, _)?:
            NSCursor.resizeLeftRight.set()
            drag = .resize(col: col, startX: startX, widths: widths, current: max(TableLayout.minColumn(theme), widths[col] + p.x - startX))
        case .row(let f, _)?:
            // drop slot: before the row whose middle is below the pointer
            var target = layout.cells.count
            for r in layout.cells.indices where p.y < cellFrame(r, 0).midY { target = r; break }
            drag = .row(from: f, target: target)
        case .col(let f, _)?:
            var target = columnWidths.count
            for c in columnWidths.indices where p.x < cellFrame(0, c).midX { target = c; break }
            drag = .col(from: f, target: target)
        case nil: return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        var g = grid!
        switch drag {
        case .resize(let col, _, var widths, let current)?:
            guard abs(current - widths[col]) >= 1 else { return }
            widths[col] = current
            g.setWidths(widths.map { Double($0) }, unit: Double(TableLayout.widthUnit(theme)))
        case .row(let f, let target)?:
            let dest = target > f ? target - 1 : target
            guard dest != f else { return }
            g.moveRow(f, to: dest)
        case .col(let f, let target)?:
            let dest = target > f ? target - 1 : target
            guard dest != f else { return }
            g.moveColumn(f, to: dest)
        case nil: return
        }
        commit(g)
    }

    private func commit(_ g: TableGrid) {
        guard g != grid else { return }
        grid = g
        overlay?.write(g, from: from, to: to)
    }

    // MARK: drawing (handles, guides; the table is drawn by the text)

    override func draw(_ dirtyRect: NSRect) {
        guard layout != nil else { return }
        let th = theme
        let ink = th.foreground.withAlphaComponent(th.contrast * 0.6)
        let accent = th.accent
        func grip(_ rect: CGRect, vertical: Bool) {
            th.background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            th.foreground.withAlphaComponent(th.contrast * 0.18).setStroke()
            let b = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); b.lineWidth = 1; b.stroke()
            ink.setFill()
            for i in 0..<3 { for j in 0..<2 {
                let x = vertical ? rect.midX - 2.5 + CGFloat(j) * 4 : rect.midX - 4.5 + CGFloat(i) * 4
                let y = vertical ? rect.midY - 4.5 + CGFloat(i) * 4 : rect.midY - 2.5 + CGFloat(j) * 4
                NSBezierPath(ovalIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.6, height: 1.6)).fill()
            } }
        }
        switch drag {
        case .resize(let col, _, let widths, let current)?:
            let x = cellFrame(0, col).minX + current
            accent.setFill()
            NSBezierPath(rect: CGRect(x: x - 1, y: tableRect.minY, width: 2, height: tableRect.height)).fill()
            _ = widths
        case .row(let f, let target)?:
            accent.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: CGRect(x: tableRect.minX, y: cellFrame(f, 0).minY, width: tableRect.width, height: cellFrame(f, 0).height)).fill()
            let y = target < layout.cells.count ? cellFrame(target, 0).minY : tableRect.maxY
            accent.setFill()
            NSBezierPath(rect: CGRect(x: tableRect.minX, y: y - 1, width: tableRect.width, height: 2)).fill()
            grip(rowHandle(f), vertical: true)
        case .col(let f, let target)?:
            accent.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: CGRect(x: cellFrame(0, f).minX, y: tableRect.minY, width: cellFrame(0, f).width, height: tableRect.height)).fill()
            let x = target < columnWidths.count ? cellFrame(0, target).minX : tableRect.maxX
            accent.setFill()
            NSBezierPath(rect: CGRect(x: x - 1, y: tableRect.minY, width: 2, height: tableRect.height)).fill()
            grip(colHandle(f), vertical: false)
        case nil:
            if let c = resizeCol {
                accent.withAlphaComponent(0.6).setFill()
                NSBezierPath(rect: CGRect(x: cellFrame(0, c).maxX - 1, y: tableRect.minY, width: 2, height: tableRect.height)).fill()
            }
            if let r = hoverRow { grip(rowHandle(r), vertical: true) }
            if let c = hoverCol { grip(colHandle(c), vertical: false) }
        }
        if let e = editing {
            accent.setStroke()
            let b = NSBezierPath(rect: cellFrame(e.row, e.col).insetBy(dx: 1, dy: 1)); b.lineWidth = 2; b.stroke()
        }
    }

    // MARK: cell editing

    /// The editor sits on the cell's text: its first baseline on the table's first baseline (the text view
    /// has no insets), as wide as the cell's content box.
    private func fieldFrame(_ r: Int, _ c: Int) -> CGRect {
        let em = theme.baseSize
        let cell = layout.cells[r][c], f = cellFrame(r, c)
        let font = theme.font(size: em, weight: r == 0 ? 600 : 400, mono: false)
        let baseline = Self.margin.height + cell.contentTop + (cell.lines.first?.baseline ?? em)
        let top = (baseline - font.ascender).rounded()
        let padX = 0.8 * em
        return CGRect(x: f.minX + padX, y: top, width: f.width - 2 * padX - 1, height: max(f.maxY - 2 - top, font.ascender - font.descender + 4))
    }

    func beginEditing(row: Int, col: Int) {
        guard row < layout.cells.count, col < layout.cells[row].count else { return }
        if editing != nil { endEditing(commit: true) }
        let ed = CellEditor()
        ed.delegate = self
        let font = theme.font(size: theme.baseSize, weight: row == 0 ? 600 : 400, mono: false)
        let align = layout.cells[row][col].alignment ?? (row == 0 ? .center : .left)
        let para = NSMutableParagraphStyle()
        para.alignment = align == .center ? .center : align == .right ? .right : .left
        ed.font = font
        ed.textColor = theme.textColor
        ed.insertionPointColor = theme.accent
        ed.defaultParagraphStyle = para
        ed.typingAttributes = [.font: font, .foregroundColor: theme.textColor, .paragraphStyle: para]
        ed.string = TableGrid.editableText(grid.rows.indices.contains(row) && grid.rows[row].indices.contains(col) ? grid.rows[row][col] : "")
        ed.textStorage?.setAttributes(ed.typingAttributes, range: NSRange(location: 0, length: (ed.string as NSString).length))
        ed.frame = fieldFrame(row, col)
        addSubview(ed)
        editorField = ed
        editing = (row, col)
        // the text stops drawing this cell's text (TableOverlay.editingCell)
        overlay?.editor?.redrawTable(at: from)
        window?.makeFirstResponder(ed)
        ed.setSelectedRange(NSRange(location: (ed.string as NSString).length, length: 0))
        // clicked elsewhere: keep what was typed
        ed.onResign = { [weak self] in self?.endEditing(commit: true, refocus: false) }
        needsDisplay = true
    }

    /// Ends editing; `move` = then edit another cell (row/col deltas; Tab past the last cell adds a row).
    /// `refocus`: give the text back the keyboard (not when focus already went elsewhere).
    func endEditing(commit doCommit: Bool, move: (dr: Int, dc: Int)? = nil, refocus: Bool = true) {
        guard let e = editing, let ed = editorField else { return }
        editing = nil
        let text = ed.string
        ed.onResign = nil
        ed.delegate = nil
        editorField = nil
        var g = grid!
        if doCommit { g.setCell(e.row, e.col, editable: text) }
        var nextCell: (Int, Int)? = nil
        if let m = move {
            var r = e.row + m.dr, c = e.col + m.dc
            if c >= g.columnCount { c = 0; r += 1 }
            if c < 0 { c = g.columnCount - 1; r -= 1 }
            if r >= g.rowCount, m.dc != 0 || m.dr > 0 { if m.dc != 0 { g.insertRow(at: g.rowCount) } else { r = -1 } }
            if r >= 0, r < g.rowCount { nextCell = (r, c) }
        }
        if nextCell == nil, refocus { window?.makeFirstResponder(overlay?.editor?.textView) }
        ed.removeFromSuperview()
        overlay?.editor?.redrawTable(at: from)
        if g != grid {
            grid = g
            if let n = nextCell { overlay?.pendingEdit = (from, n.0, n.1) }
            overlay?.write(g, from: from, to: to)
        } else if let n = nextCell {
            beginEditing(row: n.0, col: n.1)
        }
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let s = textView.string as NSString
        let caret = textView.selectedRange().location
        switch sel {
        case #selector(NSResponder.insertTab(_:)): endEditing(commit: true, move: (0, 1)); return true
        case #selector(NSResponder.insertBacktab(_:)): endEditing(commit: true, move: (0, -1)); return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { return false }   // a line break in the cell
            endEditing(commit: true, move: (1, 0)); return true
        case #selector(NSResponder.cancelOperation(_:)): endEditing(commit: false); return true
        case #selector(NSResponder.moveUp(_:)):
            if s.substring(to: caret).contains("\n") { return false }
            endEditing(commit: true, move: (-1, 0)); return true
        case #selector(NSResponder.moveDown(_:)):
            if s.substring(from: caret).contains("\n") { return false }
            endEditing(commit: true, move: (1, 0)); return true
        default: return false
        }
    }

    // MARK: context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        var r = hoverRow ?? 0, c = hoverCol ?? 0
        if let (cr, cc) = cell(at: p) { r = cr; c = cc }
        if editing != nil { endEditing(commit: true) }
        let g = grid!
        let m = NSMenu(title: L("Table"))
        m.autoenablesItems = false
        func item(_ title: String, enabled: Bool = true, _ f: @escaping (inout TableGrid) -> Void) {
            let it = ClosureItem(L(title)) { [weak self] in
                guard let self else { return }
                var g = self.grid!
                f(&g)
                self.commit(g)
            }
            it.isEnabled = enabled
            m.addItem(it)
        }
        item("Insert Row Above") { $0.insertRow(at: r) }
        item("Insert Row Below") { $0.insertRow(at: r + 1) }
        item("Insert Column Left") { $0.insertColumn(at: c) }
        item("Insert Column Right") { $0.insertColumn(at: c + 1) }
        m.addItem(.separator())
        item("Delete Row", enabled: g.rowCount > 1) { $0.deleteRow(r) }
        item("Delete Column", enabled: g.columnCount > 1) { $0.deleteColumn(c) }
        m.addItem(.separator())
        let align = NSMenuItem(title: L("Align Column"), action: nil, keyEquivalent: "")
        let am = NSMenu()
        for (t, a) in [("Left", ParsedTable.Alignment.left), ("Center", .center), ("Right", .right)] as [(String, ParsedTable.Alignment)] {
            let it = ClosureItem(L(t)) { [weak self] in
                guard let self else { return }
                var g = self.grid!; g.setAlignment(c, a); self.commit(g)
            }
            it.state = g.alignments.indices.contains(c) && g.alignments[c] == a ? .on : .off
            am.addItem(it)
        }
        align.submenu = am
        m.addItem(align)
        if g.dashes.count > 1, Set(g.dashes).count > 1 {
            item("Reset Column Widths") { $0.setWidths(nil, unit: 1) }
        }
        m.addItem(.separator())
        m.addItem(ClosureItem(L("Edit as Markdown")) { [weak self] in
            guard let self else { return }
            self.overlay?.setMarkdownMode(self.from)
        })
        m.addItem(ClosureItem(L("Delete Table")) { [weak self] in
            guard let self else { return }
            self.overlay?.delete(from: self.from, to: self.to)
        })
        return m
    }
}

/// The in-cell editor: a bare text view (no insets, no background). A wrapping NSTextField with a
/// clear background drew its text twice while editing (cell + field editor).
final class CellEditor: NSTextView {
    var onResign: (() -> Void)?
    convenience init() {
        self.init(frame: .zero)
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = true
        focusRingType = .none
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let r = onResign { onResign = nil; DispatchQueue.main.async { r() } }
        return ok
    }
}

/// A menu item running a closure.
final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

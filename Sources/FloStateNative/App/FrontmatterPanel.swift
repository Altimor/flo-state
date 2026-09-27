import AppKit
import FloCore
import FloKit

/// Row state machine of `use-frontmatter-entries.ts` (pure, testable).
struct FrontmatterRows {
    private(set) var entries: [YamlEntry]
    /// The YAML last pushed to / read from the store (nil = no frontmatter).
    private(set) var synced: String?

    init(frontmatter: String?) {
        synced = frontmatter
        entries = FrontmatterRows.seed(frontmatter)
    }

    static func seed(_ fm: String?) -> [YamlEntry] {
        guard let fm = fm else { return [] }
        let parsed = YamlEntries.parse(fm)
        return parsed.isEmpty ? [YamlEntry(key: "", value: "", isComplex: false)] : parsed
    }

    /// Store changed underneath (disk reload / our own commit echo).
    mutating func sync(_ fm: String?) -> Bool {
        guard fm != synced else { return false }
        synced = fm
        entries = FrontmatterRows.seed(fm)
        return true
    }

    /// Returns the new frontmatter to store (`.some(nil)` removes the block).
    private mutating func commit(_ next: [YamlEntry]) -> String?? {
        entries = next
        if next.isEmpty { synced = nil; return .some(nil) }
        let yaml = YamlEntries.serialize(next)
        synced = yaml
        return .some(yaml)
    }

    mutating func update(_ i: Int, key: String? = nil, value: String? = nil) -> String?? {
        guard i < entries.count else { return nil }
        var next = entries
        if let k = key { next[i].key = k }
        if let v = value { next[i].value = v }
        return commit(next)
    }

    mutating func remove(_ i: Int) -> String?? {
        guard i < entries.count else { return nil }
        var next = entries
        next.remove(at: i)
        return commit(next)
    }

    /// Local-only placeholder row.
    mutating func add() { entries.append(YamlEntry(key: "", value: "", isComplex: false)) }

    /// Blur: reap a row whose key is still empty.
    mutating func blur(_ i: Int) -> String?? {
        guard i < entries.count, entries[i].key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return remove(i)
    }

    /// Panel height (`space-y-2 pb-6`, rows 32 with gap-1.5, add row pt-1).
    static func height(rows: Int) -> CGFloat {
        guard rows >= 0 else { return 0 }
        return CGFloat(rows) * 32 + CGFloat(max(0, rows - 1)) * 6 + 8 + 4 + 14.95 + 24
    }
}

final class FrontmatterField: NSTextField {
    var index = 0
    var isKey = true
    var onBackspaceEmpty: (() -> Bool)?
}

/// The key/value panel above the editor (`frontmatter-panel.tsx`); lives
/// inside the text view so it scrolls with the document.
@MainActor
final class FrontmatterPanelView: FlippedView, NSTextFieldDelegate {
    unowned let model: ShellModel
    let path: String
    var rows: FrontmatterRows
    private var fields: [(FrontmatterField, FrontmatterField)] = []
    var onHeightChange: (() -> Void)?
    var focusEditor: (() -> Void)?
    private var pendingFocusRow: Int?
    private var hoverRow: Int? { didSet { needsDisplay = true } }

    init(model: ShellModel, path: String) {
        self.model = model
        self.path = path
        rows = FrontmatterRows(frontmatter: model.editor.file(path)?.frontmatter)
        super.init(frame: .zero)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    var hasFrontmatter: Bool { rows.synced != nil || !rows.entries.isEmpty }
    var panelHeight: CGFloat { hasFrontmatter ? FrontmatterRows.height(rows: rows.entries.count) : 0 }

    func syncFromStore() {
        if rows.sync(model.editor.file(path)?.frontmatter) { rebuild(); onHeightChange?() }
    }

    private func apply(_ r: String??) {
        guard let change = r else { return }
        model.editor.updateFrontmatter(path, change)
        if change == nil { focusEditor?() }
    }

    private func rebuild() {
        fields.forEach { $0.0.removeFromSuperview(); $0.1.removeFromSuperview() }
        fields = []
        let p = model.palette_
        let font = UIFonts.ui(model.values)
        for (i, e) in rows.entries.enumerated() {
            func make(_ s: String, key: Bool) -> FrontmatterField {
                let f = FrontmatterField(string: s)
                f.index = i
                f.isKey = key
                f.isBordered = false
                f.drawsBackground = false
                f.focusRingType = .none
                f.font = font
                f.textColor = key ? p.textMuted : p.textPrimary
                f.placeholderAttributedString = NSAttributedString(string: key ? L("key") : L("value"),
                                                                   attributes: [.font: font, .foregroundColor: p.textMuted.withAlphaComponent(p.textMuted.alphaComponent * 0.7)])
                f.delegate = self
                f.cell?.usesSingleLineMode = true
                addSubview(f)
                return f
            }
            fields.append((make(e.key, key: true), make(e.value, key: false)))
        }
        needsLayout = true
        needsDisplay = true
        if let r = pendingFocusRow, r < fields.count {
            pendingFocusRow = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self, r < self.fields.count else { return }
                self.window?.makeFirstResponder(self.fields[r].0)
            }
        }
    }

    func rowRect(_ i: Int) -> CGRect { CGRect(x: -12, y: CGFloat(i) * 38, width: bounds.width + 24, height: 32) }
    var addRect: CGRect {
        let y = CGFloat(rows.entries.count) * 38 - (rows.entries.isEmpty ? 0 : 6) + 12
        return CGRect(x: 0, y: y, width: 16 + TextStyle(font: UIFonts.ui(model.values), color: .black).width(L("Add property")), height: 14.95)
    }

    override func layout() {
        super.layout()
        for (i, (k, v)) in fields.enumerated() {
            let r = rowRect(i)
            k.frame = CGRect(x: 0, y: r.minY + 8, width: 144, height: 16)
            v.frame = CGRect(x: 144 + 16, y: r.minY + 8, width: bounds.width - 160 - 16 - 20, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = model.palette_
        for i in rows.entries.indices {
            let r = rowRect(i).insetBy(dx: 12, dy: 0)
            let focused = (window?.firstResponder as? NSTextView).flatMap { $0.delegate as? FrontmatterField }.map { $0.index == i } ?? false
            if focused { p.surfaceSubtle.setFill(); roundedPath(rowRect(i).offsetBy(dx: 12, dy: 0).insetBy(dx: 0, dy: 0), 8).fill() }
            if hoverRow == i {
                ctx.saveGState()
                ctx.setStrokeColor(p.textIconMuted.cgColor); ctx.setLineWidth(1.5); ctx.setLineCap(.round)
                let x = r.maxX - 15, y = r.midY - 5
                ctx.move(to: CGPoint(x: x + 2, y: y + 2)); ctx.addLine(to: CGPoint(x: x + 8, y: y + 8))
                ctx.move(to: CGPoint(x: x + 8, y: y + 2)); ctx.addLine(to: CGPoint(x: x + 2, y: y + 8))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        let a = addRect
        ctx.saveGState()
        ctx.setStrokeColor(p.textMuted.cgColor); ctx.setLineWidth(1.5); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: a.minX + 6, y: a.midY - 4)); ctx.addLine(to: CGPoint(x: a.minX + 6, y: a.midY + 4))
        ctx.move(to: CGPoint(x: a.minX + 2, y: a.midY)); ctx.addLine(to: CGPoint(x: a.minX + 10, y: a.midY))
        ctx.strokePath()
        ctx.restoreGState()
        TextStyle(font: UIFonts.ui(model.values), color: p.textMuted).draw(L("Add property"), x: a.minX + 16, lineTop: a.minY, lineHeight: 14.95, in: ctx)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverRow = rows.entries.indices.first { rowRect($0).contains(p) }
    }
    override func mouseExited(with event: NSEvent) { hoverRow = nil }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if addRect.insetBy(dx: -4, dy: -4).contains(p) { addRow(); return }
        for i in rows.entries.indices {
            let r = rowRect(i).insetBy(dx: 12, dy: 0)
            if CGRect(x: r.maxX - 20, y: r.midY - 10, width: 20, height: 20).contains(p) { removeRow(i); return }
        }
    }

    func addRow() {
        rows.add()
        pendingFocusRow = rows.entries.count - 1
        rebuild()
        onHeightChange?()
    }

    func removeRow(_ i: Int) {
        apply(rows.remove(i))
        rebuild()
        onHeightChange?()
    }

    // MARK: text fields

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? FrontmatterField else { return }
        apply(f.isKey ? rows.update(f.index, key: f.stringValue) : rows.update(f.index, value: f.stringValue))
    }

    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? FrontmatterField else { return }
        needsDisplay = true
        // Moving focus to the other field of the same row is not a blur.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let cur = (self.window?.firstResponder as? NSTextView)?.delegate as? FrontmatterField, cur.index == f.index { return }
            let before = self.rows.entries.count
            self.apply(self.rows.blur(f.index))
            if self.rows.entries.count != before { self.rebuild(); self.onHeightChange?() }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let f = control as? FrontmatterField else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)), !f.isKey, f.index == rows.entries.count - 1 {
            addRow()
            return true
        }
        if sel == #selector(NSResponder.deleteBackward(_:)), f.index < rows.entries.count,
           rows.entries[f.index].key.isEmpty, rows.entries[f.index].value.isEmpty {
            removeRow(f.index)
            return true
        }
        return false
    }
}

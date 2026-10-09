import Foundation

/// A table as an editable grid (row 0 is the header row) that writes itself back as GFM markdown.
/// Used by the table editor: cell edits, inserting / deleting / moving rows and columns, widths.
public struct TableGrid: Equatable {
    /// Raw markdown of each cell (escaped pipes, `<br>` line breaks), header row first.
    public var rows: [[String]]
    public var alignments: [ParsedTable.Alignment?]
    /// Dashes per column in the delimiter row (column widths; all equal = automatic).
    public var dashes: [Int]

    public var columnCount: Int { rows.first?.count ?? 0 }
    public var rowCount: Int { rows.count }

    public init(rows: [[String]], alignments: [ParsedTable.Alignment?], dashes: [Int]) {
        self.rows = rows; self.alignments = alignments; self.dashes = dashes
        normalize()
    }

    public init?(markdown: String) {
        guard let t = ParsedTable.parse(markdown) else { return nil }
        self.init(rows: [t.headers] + t.rows, alignments: t.alignments, dashes: t.dashes)
    }

    /// An empty table: `rows` includes the header row.
    public static func empty(rows: Int, columns: Int) -> TableGrid {
        let r = max(1, rows), c = max(1, columns)
        return TableGrid(rows: Array(repeating: Array(repeating: "", count: c), count: r),
                         alignments: Array(repeating: nil, count: c), dashes: Array(repeating: 3, count: c))
    }

    /// Every row as wide as the header; alignments and dashes match the column count.
    mutating func normalize() {
        let n = max(1, rows.first?.count ?? 1)
        if rows.isEmpty { rows = [Array(repeating: "", count: n)] }
        rows = rows.map { r in r.count >= n ? Array(r.prefix(n)) : r + Array(repeating: "", count: n - r.count) }
        alignments = alignments.count >= n ? Array(alignments.prefix(n)) : alignments + Array(repeating: nil, count: n - alignments.count)
        dashes = dashes.count >= n ? Array(dashes.prefix(n)) : dashes + Array(repeating: dashes.first ?? 3, count: n - dashes.count)
        dashes = dashes.map { max(3, $0) }
    }

    // MARK: markdown

    public var markdown: String {
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let delim = (0..<columnCount).map { c -> String in
            let d = String(repeating: "-", count: dashes[c])
            switch alignments[c] {
            case .left?: return ":" + d
            case .center?: return ":" + d + ":"
            case .right?: return d + ":"
            case nil: return d
            }
        }
        var lines = [row(rows[0]), "| " + delim.joined(separator: " | ") + " |"]
        for r in rows.dropFirst() { lines.append(row(r)) }
        return lines.joined(separator: "\n")
    }

    /// The text you edit for a cell: pipes unescaped, `<br>` as line breaks.
    public static func editableText(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\|", with: "|")
    }

    /// Back to cell markdown: pipes escaped, line breaks as `<br>`, trimmed.
    public static func rawText(_ editable: String) -> String {
        var s = editable.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: "|", with: "\\|")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.components(separatedBy: .newlines).joined(separator: "<br>")
    }

    // MARK: edits

    public mutating func setCell(_ r: Int, _ c: Int, editable: String) {
        guard rows.indices.contains(r), rows[r].indices.contains(c) else { return }
        rows[r][c] = Self.rawText(editable)
    }

    public mutating func insertRow(at i: Int) {
        rows.insert(Array(repeating: "", count: columnCount), at: max(0, min(i, rowCount)))
    }

    public mutating func insertColumn(at i: Int) {
        let at = max(0, min(i, columnCount))
        for r in rows.indices { rows[r].insert("", at: at) }
        alignments.insert(nil, at: at)
        // a new column in an auto-width table stays auto; in a sized one it gets a default width
        let auto = Set(dashes).count <= 1
        dashes.insert(auto ? (dashes.first ?? 3) : 12, at: at)
    }

    /// Deleting the last row / column is refused (a table keeps at least one of each).
    public mutating func deleteRow(_ i: Int) {
        guard rowCount > 1, rows.indices.contains(i) else { return }
        rows.remove(at: i)
    }

    public mutating func deleteColumn(_ i: Int) {
        guard columnCount > 1, i >= 0, i < columnCount else { return }
        for r in rows.indices { rows[r].remove(at: i) }
        alignments.remove(at: i)
        dashes.remove(at: i)
    }

    /// Move row `from` so it ends up at index `to` (0 = the header row).
    public mutating func moveRow(_ from: Int, to: Int) {
        guard rows.indices.contains(from) else { return }
        let r = rows.remove(at: from)
        rows.insert(r, at: max(0, min(to, rows.count)))
    }

    public mutating func moveColumn(_ from: Int, to: Int) {
        guard from >= 0, from < columnCount else { return }
        let dest = max(0, min(to, columnCount - 1))
        for r in rows.indices { let v = rows[r].remove(at: from); rows[r].insert(v, at: dest) }
        let a = alignments.remove(at: from); alignments.insert(a, at: dest)
        let d = dashes.remove(at: from); dashes.insert(d, at: dest)
    }

    public mutating func setAlignment(_ c: Int, _ a: ParsedTable.Alignment?) {
        guard alignments.indices.contains(c) else { return }
        alignments[c] = a
    }

    /// Column widths in points (`unit` per dash); nil = back to automatic widths.
    public mutating func setWidths(_ widths: [Double]?, unit: Double) {
        guard let ws = widths, ws.count == columnCount else { dashes = Array(repeating: 3, count: columnCount); return }
        dashes = ws.map { max(3, Int(($0 / unit).rounded())) }
        // equal counts would read back as automatic: nudge one so the widths stick
        if let f = dashes.first, dashes.count > 1, dashes.allSatisfy({ $0 == f }) { dashes[dashes.count - 1] += 1 }
    }
}

import Foundation

// A small CodeMirror-6-shaped editor model. Commands are ported from the web
// app as `(EditorState) -> Transaction?`, so keeping the same concepts (UTF-16
// positions, lines, multi-range selections, change sets with position mapping)
// lets the ports stay line-for-line comparable with the originals.
//
// ChangeSet / SelectionRange / EditorSelection / changeByRange are direct ports
// of @codemirror/state 6.6 (sections encoding, mapPos, compose, map, invert),
// because history grouping and multi-range commands depend on the exact
// position-mapping semantics.

// MARK: - Text

public struct Line: Equatable {
    /// 1-based, like CodeMirror.
    public let number: Int
    public let from: Int
    public let to: Int
    let source: Text
    /// The line's text (built on demand).
    public var text: String { source.slice(from, to) }
    public var length: Int { to - from }
    public static func == (a: Line, b: Line) -> Bool {
        a.number == b.number && a.from == b.from && a.to == b.to && (a.source === b.source || a.text == b.text)
    }
}

public final class Text {
    public let units: [UInt16]
    /// The document as a String (built on first use; commands mostly work on units).
    public private(set) lazy var string: String = String(utf16CodeUnits: units, count: units.count)
    /// Start offset of each line (line i has number i+1).
    public let lineStarts: [Int]

    public convenience init(_ s: String) {
        // CodeMirror normalises every line break to "\n".
        let normalized = s.contains("\r") ? s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n") : s
        self.init(units: Array(normalized.utf16), string: normalized)
    }

    public convenience init(units: [UInt16]) {
        self.init(units: units, string: nil)
    }

    private init(units: [UInt16], string: String?) {
        self.units = units
        var starts = [0]
        for (i, u) in units.enumerated() where u == 10 { starts.append(i + 1) }
        lineStarts = starts
        if let s = string { self.string = s }
    }

    public static let empty = Text("")

    public var length: Int { units.count }
    public var lines: Int { lineStarts.count }

    public func line(_ number: Int) -> Line {
        let from = lineStarts[number - 1]
        let to = number < lineStarts.count ? lineStarts[number] - 1 : units.count
        return Line(number: number, from: from, to: to, source: self)
    }

    public func lineAt(_ pos: Int) -> Line {
        let p = max(0, min(pos, units.count))
        // binary search: last start <= p
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= p { lo = mid } else { hi = mid - 1 }
        }
        return line(lo + 1)
    }

    public func slice(_ from: Int, _ to: Int) -> String {
        let a = max(0, min(from, units.count)), b = max(a, min(to, units.count))
        return String(utf16CodeUnits: Array(units[a..<b]), count: b - a)
    }

    public func sliceUnits(_ from: Int, _ to: Int) -> [UInt16] {
        let a = max(0, min(from, units.count)), b = max(a, min(to, units.count))
        return Array(units[a..<b])
    }

    public func char(at pos: Int) -> UInt16? { pos >= 0 && pos < units.count ? units[pos] : nil }
}

// MARK: - Selection

public struct SelectionRange: Equatable {
    public var anchor: Int
    public var head: Int
    /// Goal column for vertical motion (kept across Up/Down like CM).
    public var goalColumn: Int?
    /// CM cursor association: -1 = with the char before, 1 = after, 0 = none.
    public var assoc: Int

    public init(anchor: Int, head: Int, goalColumn: Int? = nil, assoc: Int = 0) {
        self.anchor = anchor
        self.head = head
        self.goalColumn = goalColumn
        if anchor == head {
            self.assoc = assoc
        } else if head < anchor {
            self.assoc = 1
        } else {
            self.assoc = assoc == 0 ? -1 : assoc
        }
    }
    /// `EditorSelection.cursor(pos, assoc, _, goalColumn)`.
    public static func cursor(_ pos: Int, assoc: Int = 0, goalColumn: Int? = nil) -> SelectionRange {
        SelectionRange(anchor: pos, head: pos, goalColumn: goalColumn, assoc: assoc)
    }
    /// `EditorSelection.range(anchor, head, goalColumn, _, assoc)`.
    public static func range(_ anchor: Int, _ head: Int, goalColumn: Int? = nil, assoc: Int = 0) -> SelectionRange {
        SelectionRange(anchor: anchor, head: head, goalColumn: goalColumn, assoc: assoc)
    }
    public var from: Int { min(anchor, head) }
    public var to: Int { max(anchor, head) }
    public var empty: Bool { anchor == head }

    public static func == (a: SelectionRange, b: SelectionRange) -> Bool {
        a.anchor == b.anchor && a.head == b.head
    }

    /// CM `SelectionRange.eq`.
    public func eq(_ other: SelectionRange, includeAssoc: Bool = false) -> Bool {
        anchor == other.anchor && head == other.head && goalColumn == other.goalColumn &&
            (!includeAssoc || !empty || assoc == other.assoc)
    }

    /// CM `SelectionRange.map`: cursors map with `assoc`; ranges map `from`
    /// forward and `to` backward (they shrink around inserted text).
    public func map(_ change: ChangeSet, assoc mapAssoc: Int = -1) -> SelectionRange {
        let newFrom: Int, newTo: Int
        if empty {
            newFrom = change.mapPos(from, assoc: mapAssoc); newTo = newFrom
        } else {
            newFrom = change.mapPos(from, assoc: 1)
            newTo = change.mapPos(to, assoc: -1)
        }
        if newFrom == from && newTo == to { return self }
        // Keep flags (direction, assoc, goal column) like CM does.
        var r = self
        if head < anchor { r.head = newFrom; r.anchor = newTo } else { r.anchor = newFrom; r.head = newTo }
        return r
    }
}

public struct EditorSelection: Equatable {
    public var ranges: [SelectionRange]
    public var mainIndex: Int

    /// Raw constructor (no normalisation). Use `create` for CM semantics.
    public init(ranges: [SelectionRange], mainIndex: Int = 0) {
        self.ranges = ranges
        self.mainIndex = mainIndex
    }
    public static func single(_ anchor: Int, _ head: Int? = nil) -> EditorSelection {
        EditorSelection(ranges: [SelectionRange.range(anchor, head ?? anchor)])
    }
    public static func cursor(_ pos: Int) -> EditorSelection { single(pos) }
    public var main: SelectionRange { ranges[mainIndex] }

    public static func == (a: EditorSelection, b: EditorSelection) -> Bool {
        a.mainIndex == b.mainIndex && a.ranges == b.ranges
    }

    public func eq(_ other: EditorSelection, includeAssoc: Bool = false) -> Bool {
        guard ranges.count == other.ranges.count, mainIndex == other.mainIndex else { return false }
        for i in 0..<ranges.count where !ranges[i].eq(other.ranges[i], includeAssoc: includeAssoc) { return false }
        return true
    }

    /// CM `EditorSelection.create`: sort and merge only when needed.
    public static func create(_ ranges: [SelectionRange], mainIndex: Int = 0) -> EditorSelection {
        precondition(!ranges.isEmpty, "A selection needs at least one range")
        var pos = 0
        for r in ranges {
            if r.empty ? r.from <= pos : r.from < pos {
                return normalized(ranges, mainIndex: mainIndex)
            }
            pos = r.to
        }
        return EditorSelection(ranges: ranges, mainIndex: mainIndex)
    }

    static func normalized(_ input: [SelectionRange], mainIndex: Int) -> EditorSelection {
        // Stable sort by `from`, tracking the main range by identity (index).
        var indexed = input.enumerated().map { ($0.offset, $0.element) }
        indexed.sort { a, b in a.1.from < b.1.from || (a.1.from == b.1.from && a.0 < b.0) }
        var ranges = indexed.map { $0.1 }
        var main = indexed.firstIndex { $0.0 == mainIndex } ?? 0
        var i = 1
        while i < ranges.count {
            let range = ranges[i], prev = ranges[i - 1]
            if range.empty ? range.from <= prev.to : range.from < prev.to {
                let from = prev.from, to = max(range.to, prev.to)
                if i <= main { main -= 1 }
                i -= 1
                let merged = range.anchor > range.head ? SelectionRange.range(to, from) : SelectionRange.range(from, to)
                ranges.replaceSubrange(i...(i + 1), with: [merged])
            }
            i += 1
        }
        return EditorSelection(ranges: ranges, mainIndex: main)
    }

    /// Legacy helper kept for callers: CM normalisation.
    public func normalized() -> EditorSelection { EditorSelection.create(ranges, mainIndex: mainIndex) }

    public func map(_ changes: ChangeSet, assoc: Int = -1) -> EditorSelection {
        if changes.isEmpty { return self }
        return EditorSelection.create(ranges.map { $0.map(changes, assoc: assoc) }, mainIndex: mainIndex)
    }

    public func asSingle() -> EditorSelection {
        ranges.count == 1 ? self : EditorSelection(ranges: [main], mainIndex: 0)
    }

    public func addRange(_ range: SelectionRange, main: Bool = true) -> EditorSelection {
        EditorSelection.create([range] + ranges, mainIndex: main ? 0 : mainIndex + 1)
    }

    public func replaceRange(_ range: SelectionRange, which: Int? = nil) -> EditorSelection {
        var rs = ranges
        rs[which ?? mainIndex] = range
        return EditorSelection.create(rs, mainIndex: mainIndex)
    }
}

// MARK: - Changes

public struct Change: Equatable {
    public var from: Int
    public var to: Int
    public var insert: String
    public init(from: Int, to: Int? = nil, insert: String = "") {
        self.from = from
        self.to = to ?? from
        self.insert = insert
    }
    var insertLength: Int { insert.utf16.count }
}

/// Port of CM's ChangeSet. `sections` are pairs (length in old doc, -1 for
/// unchanged or the inserted length); `inserted[i]` is the text for section i.
public struct ChangeSet: Equatable {
    public private(set) var sections: [Int]
    var inserted: [[UInt16]]

    init(sections: [Int], inserted: [[UInt16]]) {
        self.sections = sections
        self.inserted = inserted
    }

    /// `ChangeSet.of(changes, length)`: changes are in ORIGINAL document
    /// coordinates; out-of-order specs are composed like CM does.
    public init(_ changes: [Change], docLength length: Int) {
        var sections: [Int] = [], inserted: [[UInt16]] = [], pos = 0
        var total: ChangeSet? = nil
        func flush(_ force: Bool = false) {
            if !force && sections.isEmpty { return }
            if pos < length { ChangeSet.addSection(&sections, length - pos, -1) }
            let set = ChangeSet(sections: sections, inserted: inserted)
            total = total.map { $0.compose(set.map($0)) } ?? set
            sections = []; inserted = []; pos = 0
        }
        for spec in changes {
            precondition(spec.from <= spec.to && spec.from >= 0 && spec.to <= length,
                         "Invalid change range \(spec.from) to \(spec.to) (in doc of length \(length))")
            let ins = Array(spec.insert.utf16)
            if spec.from == spec.to && ins.isEmpty { continue }
            if spec.from < pos { flush() }
            if spec.from > pos { ChangeSet.addSection(&sections, spec.from - pos, -1) }
            ChangeSet.addSection(&sections, spec.to - spec.from, ins.count)
            ChangeSet.addInsert(&inserted, sections, ins)
            pos = spec.to
        }
        flush(total == nil)
        self = total!
    }

    public static func empty(_ length: Int) -> ChangeSet {
        ChangeSet(sections: length > 0 ? [length, -1] : [], inserted: [])
    }

    /// Length of the document before the change.
    public var docLength: Int {
        var r = 0
        var i = 0
        while i < sections.count { r += sections[i]; i += 2 }
        return r
    }
    public var length: Int { docLength }

    public var newLength: Int {
        var r = 0
        var i = 0
        while i < sections.count {
            let ins = sections[i + 1]
            r += ins < 0 ? sections[i] : ins
            i += 2
        }
        return r
    }

    public var isEmpty: Bool { sections.isEmpty || (sections.count == 2 && sections[1] < 0) }

    /// The changes as a flat list in original-document coordinates.
    public var changes: [Change] {
        var out: [Change] = []
        iterChanges { fromA, toA, _, _, text in
            out.append(Change(from: fromA, to: toA, insert: String(utf16CodeUnits: text, count: text.count)))
        }
        return out
    }

    public func mapPos(_ pos: Int, assoc: Int = -1) -> Int {
        var posA = 0, posB = 0, i = 0
        while i < sections.count {
            let len = sections[i], ins = sections[i + 1]
            i += 2
            let endA = posA + len
            if ins < 0 {
                if endA > pos { return posB + (pos - posA) }
                posB += len
            } else {
                if endA > pos || (endA == pos && assoc < 0 && len == 0) {
                    return pos == posA || assoc < 0 ? posB : posB + ins
                }
                posB += ins
            }
            posA = endA
        }
        precondition(pos <= posA, "Position \(pos) is out of range for changeset of length \(posA)")
        return posB
    }

    public func touchesRange(_ from: Int, _ to: Int? = nil) -> Bool {
        let to = to ?? from
        var i = 0, pos = 0
        while i < sections.count && pos <= to {
            let len = sections[i], ins = sections[i + 1]
            i += 2
            let end = pos + len
            if ins >= 0 && pos <= to && end >= from { return true }
            pos = end
        }
        return false
    }

    public func iterChanges(individual: Bool = false,
                            _ f: (_ fromA: Int, _ toA: Int, _ fromB: Int, _ toB: Int, _ text: [UInt16]) -> Void) {
        var posA = 0, posB = 0, i = 0
        while i < sections.count {
            var len = sections[i], ins = sections[i + 1]
            i += 2
            if ins < 0 {
                posA += len; posB += len
            } else {
                var endA = posA, endB = posB
                var text: [UInt16] = []
                while true {
                    endA += len; endB += ins
                    if ins > 0 {
                        let idx = (i - 2) >> 1
                        if idx < inserted.count { text += inserted[idx] }
                    }
                    if individual || i == sections.count || sections[i + 1] < 0 { break }
                    len = sections[i]; ins = sections[i + 1]
                    i += 2
                }
                f(posA, endA, posB, endB, text)
                posA = endA; posB = endB
            }
        }
    }

    public func iterChangedRanges(individual: Bool = false, _ f: (Int, Int, Int, Int) -> Void) {
        iterChanges(individual: individual) { a, b, c, d, _ in f(a, b, c, d) }
    }

    public func iterGaps(_ f: (_ posA: Int, _ posB: Int, _ len: Int) -> Void) {
        var posA = 0, posB = 0, i = 0
        while i < sections.count {
            let len = sections[i], ins = sections[i + 1]
            i += 2
            if ins < 0 { f(posA, posB, len); posB += len } else { posB += ins }
            posA += len
        }
    }

    public func apply(to text: Text) -> Text {
        precondition(docLength == text.length, "Applying change set to a document with the wrong length")
        var out: [UInt16] = []
        out.reserveCapacity(newLength)
        var cursor = 0
        iterChanges { fromA, toA, _, _, ins in
            out.append(contentsOf: text.units[cursor..<fromA])
            out.append(contentsOf: ins)
            cursor = toA
        }
        out.append(contentsOf: text.units[cursor..<text.length])
        return Text(units: out)
    }

    /// Changed ranges expressed in new-document coordinates.
    public func changedRangesInNewDoc() -> [(from: Int, to: Int)] {
        var out: [(Int, Int)] = []
        iterChangedRanges { _, _, fromB, toB in out.append((fromB, toB)) }
        return out
    }

    public func invert(_ doc: Text) -> ChangeSet {
        var secs = sections
        var ins: [[UInt16]] = []
        var i = 0, pos = 0
        while i < secs.count {
            let len = secs[i], n = secs[i + 1]
            if n >= 0 {
                secs[i] = n; secs[i + 1] = len
                let index = i >> 1
                while ins.count < index { ins.append([]) }
                ins.append(len > 0 ? doc.sliceUnits(pos, pos + len) : [])
            }
            pos += len
            i += 2
        }
        return ChangeSet(sections: secs, inserted: ins)
    }

    public var invertedDesc: ChangeSet {
        var secs: [Int] = []
        var i = 0
        while i < sections.count {
            let len = sections[i], ins = sections[i + 1]
            if ins < 0 { secs += [len, ins] } else { secs += [ins, len] }
            i += 2
        }
        return ChangeSet(sections: secs, inserted: [])
    }

    public var desc: ChangeSet { ChangeSet(sections: sections, inserted: []) }

    public func compose(_ other: ChangeSet) -> ChangeSet {
        isEmpty ? other : other.isEmpty ? self : ChangeSet.composeSets(self, other)
    }
    public func composeDesc(_ other: ChangeSet) -> ChangeSet { compose(other).desc }

    public func map(_ other: ChangeSet, before: Bool = false) -> ChangeSet {
        other.isEmpty ? self : ChangeSet.mapSet(self, other, before: before)
    }
    public func mapDesc(_ other: ChangeSet, before: Bool = false) -> ChangeSet {
        other.isEmpty ? self : ChangeSet.mapSet(self, other, before: before)
    }

    // MARK: internals (ports of CM's addSection/addInsert/mapSet/composeSets)

    static func addSection(_ sections: inout [Int], _ len: Int, _ ins: Int, _ forceJoin: Bool = false) {
        if len == 0 && ins <= 0 { return }
        let last = sections.count - 2
        if last >= 0 && ins <= 0 && ins == sections[last + 1] {
            sections[last] += len
        } else if last >= 0 && len == 0 && sections[last] == 0 {
            sections[last + 1] += ins
        } else if forceJoin {
            sections[last] += len
            sections[last + 1] += ins
        } else {
            sections += [len, ins]
        }
    }

    static func addInsert(_ values: inout [[UInt16]], _ sections: [Int], _ value: [UInt16]) {
        if value.isEmpty { return }
        let index = (sections.count - 2) >> 1
        if index < values.count {
            values[values.count - 1] += value
        } else {
            while values.count < index { values.append([]) }
            values.append(value)
        }
    }

    struct SectionIter {
        let set: ChangeSet
        var i = 0
        var len = 0
        var ins = 0
        var off = 0
        init(_ set: ChangeSet) { self.set = set; next() }
        mutating func next() {
            if i < set.sections.count {
                len = set.sections[i]; ins = set.sections[i + 1]; i += 2
            } else {
                len = 0; ins = -2
            }
            off = 0
        }
        var done: Bool { ins == -2 }
        var len2: Int { ins < 0 ? len : ins }
        var text: [UInt16] {
            let index = (i - 2) >> 1
            return index >= set.inserted.count ? [] : set.inserted[index]
        }
        func textBit(_ l: Int?) -> [UInt16] {
            let index = (i - 2) >> 1
            if index >= set.inserted.count { return [] }
            let t = set.inserted[index]
            let a = min(off, t.count), b = l == nil ? t.count : min(t.count, off + l!)
            return a < b ? Array(t[a..<b]) : []
        }
        mutating func forward(_ l: Int) {
            if l == len { next() } else { len -= l; off += l }
        }
        mutating func forward2(_ l: Int) {
            if ins == -1 { forward(l) } else if l == ins { next() } else { ins -= l; off += l }
        }
    }

    static func mapSet(_ setA: ChangeSet, _ setB: ChangeSet, before: Bool) -> ChangeSet {
        var sections: [Int] = [], insert: [[UInt16]] = []
        var a = SectionIter(setA), b = SectionIter(setB)
        var inserted = -1
        while true {
            if (a.done && b.len != 0) || (b.done && a.len != 0) {
                fatalError("Mismatched change set lengths")
            } else if a.ins == -1 && b.ins == -1 {
                let len = min(a.len, b.len)
                addSection(&sections, len, -1)
                a.forward(len); b.forward(len)
            } else if b.ins >= 0 && (a.ins < 0 || inserted == a.i || (a.off == 0 && (b.len < a.len || (b.len == a.len && !before)))) {
                var len = b.len
                addSection(&sections, b.ins, -1)
                while len != 0 {
                    let piece = min(a.len, len)
                    if a.ins >= 0 && inserted < a.i && a.len <= piece {
                        addSection(&sections, 0, a.ins)
                        addInsert(&insert, sections, a.text)
                        inserted = a.i
                    }
                    a.forward(piece)
                    len -= piece
                }
                b.next()
            } else if a.ins >= 0 {
                var len = 0, left = a.len
                while left != 0 {
                    if b.ins == -1 {
                        let piece = min(left, b.len)
                        len += piece; left -= piece
                        b.forward(piece)
                    } else if b.ins == 0 && b.len < left {
                        left -= b.len
                        b.next()
                    } else {
                        break
                    }
                }
                addSection(&sections, len, inserted < a.i ? a.ins : 0)
                if inserted < a.i { addInsert(&insert, sections, a.text) }
                inserted = a.i
                a.forward(a.len - left)
            } else if a.done && b.done {
                return ChangeSet(sections: sections, inserted: insert)
            } else {
                fatalError("Mismatched change set lengths")
            }
        }
    }

    static func composeSets(_ setA: ChangeSet, _ setB: ChangeSet) -> ChangeSet {
        var sections: [Int] = [], insert: [[UInt16]] = []
        var a = SectionIter(setA), b = SectionIter(setB)
        var open = false
        while true {
            if a.done && b.done {
                return ChangeSet(sections: sections, inserted: insert)
            } else if a.ins == 0 {
                addSection(&sections, a.len, 0, open)
                a.next()
            } else if b.len == 0 && !b.done {
                addSection(&sections, 0, b.ins, open)
                addInsert(&insert, sections, b.text)
                b.next()
            } else if a.done || b.done {
                fatalError("Mismatched change set lengths")
            } else {
                let len = min(a.len2, b.len), sectionLen = sections.count
                if a.ins == -1 {
                    let insB = b.ins == -1 ? -1 : b.off != 0 ? 0 : b.ins
                    addSection(&sections, len, insB, open)
                    if insB > 0 { addInsert(&insert, sections, b.text) }
                } else if b.ins == -1 {
                    addSection(&sections, a.off != 0 ? 0 : a.len, len, open)
                    addInsert(&insert, sections, a.textBit(len))
                } else {
                    addSection(&sections, a.off != 0 ? 0 : a.len, b.off != 0 ? 0 : b.ins, open)
                    if b.off == 0 { addInsert(&insert, sections, b.text) }
                }
                open = (a.ins > len || (b.ins >= 0 && b.len > len)) && (open || sections.count > sectionLen)
                a.forward2(len)
                b.forward(len)
            }
        }
    }
}

// MARK: - State & transactions

public struct TransactionSpec {
    public var changes: [Change]
    /// A pre-built change set (e.g. from `changeByRange`); wins over `changes`.
    public var changeSet: ChangeSet?
    public var selection: EditorSelection?
    public var userEvent: String?
    public var scrollIntoView: Bool
    /// CM `filter: false` skips transaction filters (undo/redo use this).
    public var filter: Bool
    /// CM `Transaction.addToHistory`.
    public var addToHistory: Bool
    public init(changes: [Change] = [], changeSet: ChangeSet? = nil, selection: EditorSelection? = nil,
                userEvent: String? = nil, scrollIntoView: Bool = true, filter: Bool = true, addToHistory: Bool = true) {
        self.changes = changes
        self.changeSet = changeSet
        self.selection = selection
        self.userEvent = userEvent
        self.scrollIntoView = scrollIntoView
        self.filter = filter
        self.addToHistory = addToHistory
    }
}

public struct Transaction {
    public let startState: EditorState
    public let state: EditorState
    public let changes: ChangeSet
    public let selectionSet: Bool
    public let userEvent: String?
    public var docChanged: Bool { !changes.isEmpty }

    /// CM `Transaction.isUserEvent`: matches the event or a dotted sub-event.
    public func isUserEvent(_ event: String) -> Bool {
        guard let e = userEvent else { return false }
        return e == event || e.hasPrefix(event + ".")
    }
}

/// The last few parsed documents: the same text is often parsed for several
/// states in one keystroke (command speculation, filters, the native edit).
enum TreeCache {
    private static var entries: [(Text, SyntaxTree)] = []
    static func lookup(_ doc: Text) -> SyntaxTree? {
        for (t, tree) in entries where t === doc || (t.length == doc.length && t.units == doc.units) { return tree }
        return nil
    }
    static func store(_ doc: Text, _ tree: SyntaxTree) {
        entries.insert((doc, tree), at: 0)
        if entries.count > 3 { entries.removeLast() }
    }
}

public final class EditorState {
    public let doc: Text
    public let selection: EditorSelection
    private var _tree: SyntaxTree?
    /// Whether this document is parsed as markdown (false for .csv / plain text).
    public let markdown: Bool
    /// CM's `allowMultipleSelections` facet. The web app leaves it off, so every
    /// new selection is reduced to its main range.
    public let allowMultipleSelections: Bool

    public init(doc: Text, selection: EditorSelection = .cursor(0), markdown: Bool = true, tree: SyntaxTree? = nil,
                allowMultipleSelections: Bool = false) {
        self.doc = doc
        let len = doc.length
        let clamped = EditorSelection.create(selection.ranges.map {
            var r = $0
            r.anchor = min(max(0, $0.anchor), len)
            r.head = min(max(0, $0.head), len)
            return r
        }, mainIndex: selection.mainIndex)
        self.selection = allowMultipleSelections ? clamped : clamped.asSingle()
        self.markdown = markdown
        self.allowMultipleSelections = allowMultipleSelections
        _tree = tree
    }

    public convenience init(_ s: String, selection: EditorSelection = .cursor(0)) {
        self.init(doc: Text(s), selection: selection)
    }

    public var tree: SyntaxTree {
        if let t = _tree { return t }
        if markdown, let t = TreeCache.lookup(doc) { _tree = t; return t }
        let t = markdown ? FloMarkdown.parse(units: doc.units)
            : SyntaxTree(root: SyntaxNode(name: "Document", from: 0, to: doc.length))
        if markdown { TreeCache.store(doc, t) }
        _tree = t
        return t
    }

    public func sliceDoc(_ from: Int, _ to: Int) -> String { doc.slice(from, to) }

    /// Same document (and cached tree), different selection. Used by
    /// transaction filters that override a transaction's selection.
    public func withSelection(_ sel: EditorSelection) -> EditorState {
        EditorState(doc: doc, selection: sel, markdown: markdown, tree: _tree,
                    allowMultipleSelections: allowMultipleSelections)
    }

    /// `state.changes(spec)`.
    public func changes(_ specs: [Change]) -> ChangeSet { ChangeSet(specs, docLength: doc.length) }

    /// Core CM `state.update` (no transaction filters; see the command
    /// pipeline in FloCore/Commands for filters and history).
    public func update(_ spec: TransactionSpec) -> Transaction {
        let cs = spec.changeSet ?? ChangeSet(spec.changes, docLength: doc.length)
        let newDoc = cs.isEmpty ? doc : cs.apply(to: doc)
        let sel = spec.selection ?? selection.map(cs)
        let newTree: SyntaxTree? = cs.isEmpty ? _tree : nil
        let next = EditorState(doc: newDoc, selection: sel, markdown: markdown, tree: newTree,
                               allowMultipleSelections: allowMultipleSelections)
        return Transaction(startState: self, state: next, changes: cs,
                           selectionSet: spec.selection != nil, userEvent: spec.userEvent)
    }

    /// CodeMirror `changeByRange`: `f` returns changes in start-document
    /// coordinates and a range in the coordinates of the document after that
    /// call's own changes. Ranges are then mapped through the other ranges'
    /// changes exactly like CM does.
    public func changeByRange(_ f: (SelectionRange) -> (changes: [Change], range: SelectionRange)) -> TransactionSpec {
        let sel = selection
        let r1 = f(sel.ranges[0])
        var changes = self.changes(r1.changes)
        var ranges = [r1.range]
        for i in 1..<max(1, sel.ranges.count) {
            let result = f(sel.ranges[i])
            let newChanges = self.changes(result.changes)
            let newMapped = newChanges.map(changes)
            for j in 0..<i { ranges[j] = ranges[j].map(newMapped) }
            let mapBy = changes.mapDesc(newChanges, before: true)
            ranges.append(result.range.map(mapBy))
            changes = changes.compose(newMapped)
        }
        return TransactionSpec(changeSet: changes, selection: EditorSelection.create(ranges, mainIndex: sel.mainIndex))
    }

    /// CM `replaceSelection`.
    public func replaceSelection(_ text: String) -> TransactionSpec {
        let n = text.utf16.count
        return changeByRange { r in
            ([Change(from: r.from, to: r.to, insert: text)], SelectionRange.cursor(r.from + n))
        }
    }
}

public typealias StateCommand = (EditorState) -> TransactionSpec?

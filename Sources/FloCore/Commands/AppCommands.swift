import Foundation

// App-level commands: heading escape-left (heading-decorations.ts), daily note
// (daily-note.ts), frontmatter `---` start (use-prosemark-editor.ts), and the
// logic part of revealBlockOnArrow.ts.

public enum AppCommands {
    // MARK: heading escape-left

    static let escapeHashLeft: Command = { t in
        let sel = t.state.selection.main
        if !sel.empty { return false }
        guard let zone = Headings.findZoneEndingAt(t.state, sel.head) else { return false }
        t.dispatch(TransactionSpec(selection: .single(max(0, zone.from - 1)), userEvent: "select"))
        return true
    }

    static let escapeHashLeftExtend: Command = { t in
        let sel = t.state.selection.main
        guard let zone = Headings.findZoneEndingAt(t.state, sel.head) else { return false }
        t.dispatch(TransactionSpec(selection: EditorSelection(ranges: [SelectionRange.range(sel.anchor, max(0, zone.from - 1))]),
                                   userEvent: "select.extend"))
        return true
    }

    // MARK: daily note

    public static func todayStamp(_ now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d.%02d.%02d", c.year!, c.month!, c.day!)
    }

    static func findHeadingLine(_ doc: Text, _ heading: String) -> Int {
        for n in 1...doc.lines where CMText.trimEnd(doc.line(n).text) == heading { return n }
        return 0
    }

    static let DATED_NOTEBOOK = JSRegex("^## \\d{4}\\.\\d{2}\\.\\d{2}\\s*$", [.anchorsMatchLines])

    static func leadingPad(_ doc: Text) -> String {
        let end = doc.length
        let tail = doc.slice(max(0, end - 2), end)
        return tail.hasSuffix("\n\n") ? "" : tail.hasSuffix("\n") ? "\n" : "\n\n"
    }

    /// `ensureTodayHeading`: append today's heading to an already-dated
    /// notebook without moving the caret. Returns true when it inserted.
    @discardableResult
    public static func ensureTodayHeading(_ session: EditorSession) -> Bool {
        session.run { t in
            let doc = t.state.doc
            if !DATED_NOTEBOOK.test(doc.string) { return false }
            let heading = "## \(todayStamp(t.env.now, calendar: t.env.calendar))"
            if findHeadingLine(doc, heading) > 0 { return false }
            t.dispatch(TransactionSpec(changes: [Change(from: doc.length, insert: leadingPad(doc) + heading + "\n\n")],
                                       userEvent: "input.daily-heading"))
            return true
        }
    }

    public static let goToDailyNote: Command = { t in
        let heading = "## \(todayStamp(t.env.now, calendar: t.env.calendar))"
        let doc = t.state.doc
        let existing = findHeadingLine(doc, heading)
        if existing > 0 {
            t.dispatch(TransactionSpec(selection: .single(doc.line(existing).to)))
            return true
        }
        let end = doc.length
        let insert = leadingPad(doc) + heading + "\n\n"
        t.dispatch(TransactionSpec(changes: [Change(from: end, insert: insert)], selection: .single(end + insert.utf16.count)))
        return true
    }

    // MARK: frontmatter start (keydown "-")

    static func frontmatterStart(_ t: CommandTarget) -> Bool {
        let state = t.state
        let pos = state.selection.main.head
        let firstLine = state.doc.line(1)
        if pos != firstLine.from + 2 { return false }
        if firstLine.text != "--" { return false }
        if !t.env.createFrontmatter() { return false }
        t.dispatch(TransactionSpec(changes: [Change(from: firstLine.from, to: firstLine.from + 2)]))
        return true
    }

    // MARK: revealBlockOnArrow (logic)

    static func revealBlock(_ up: Bool) -> Command {
        return { t in
            let widgets = t.env.layout.blockWidgetRanges(t.state)
            if widgets.isEmpty { return false }
            let cursorAt = t.state.selection.main.head
            for w in widgets {
                if !up && cursorAt == w.from - 1 { t.dispatch(TransactionSpec(selection: .single(w.from))); return true }
                if up && cursorAt == w.to + 1 { t.dispatch(TransactionSpec(selection: .single(w.to))); return true }
            }
            let line = t.state.doc.lineAt(cursorAt)
            var candidate: Int? = nil
            let ws = JSRegex("^[\\t \\n\\r]+$")
            for w in widgets where !w.skipAdjacentArrowReveal {
                if up && w.to < line.from && ws.test(t.state.sliceDoc(w.to, line.from)) {
                    candidate = candidate == nil || w.to > candidate! ? w.to : candidate
                    continue
                }
                if !up && w.from > line.to && ws.test(t.state.sliceDoc(line.to, w.from)) {
                    candidate = candidate == nil || w.from < candidate! ? w.from : candidate
                }
            }
            guard let c = candidate else { return false }
            t.dispatch(TransactionSpec(selection: .single(c)))
            return true
        }
    }
}

/// A block-replace widget range (image, HR, table, math, HTML...) for the
/// Up/Down reveal logic. Supplied by the renderer through `EditorLayout`.
public struct BlockWidgetRange {
    public let from: Int
    public let to: Int
    public let skipAdjacentArrowReveal: Bool
    public init(from: Int, to: Int, skipAdjacentArrowReveal: Bool = false) {
        self.from = from; self.to = to; self.skipAdjacentArrowReveal = skipAdjacentArrowReveal
    }
}

public extension EditorLayout {
    func blockWidgetRanges(_ state: EditorState) -> [BlockWidgetRange] { [] }
}

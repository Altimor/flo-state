import Foundation

// The command runtime: CommandEnv (clock, history, layout hook), the
// transaction pipeline (filters + history, like CM's dispatch), and
// EditorSession, the object the AppKit layer drives.

/// Line-wrapping geometry for commands that CodeMirror resolves through the
/// DOM (vertical motion, visual line boundaries). The AppKit layer implements
/// this with TextKit; `MonospaceLayout` is the no-wrap default.
public protocol EditorLayout {
    /// `view.moveVertically(range, forward)`: the cursor one visual line
    /// up/down, keeping `goalColumn` (returned range carries the goal used).
    func moveVertically(_ state: EditorState, _ range: SelectionRange, forward: Bool) -> SelectionRange
    /// `view.moveToLineBoundary(range, forward, includeWrap)`.
    func moveToLineBoundary(_ state: EditorState, _ range: SelectionRange, forward: Bool, includeWrap: Bool) -> SelectionRange
    /// `view.lineBlockAt(pos)` extent (a logical line unless folded).
    func lineBlockAt(_ state: EditorState, _ pos: Int) -> (from: Int, to: Int)
    /// Block-replace widgets (image, HR, table...) for revealBlockOnArrow.
    func blockWidgetRanges(_ state: EditorState) -> [BlockWidgetRange]
}

/// No wrapping, every UTF-16 unit is one column.
public struct MonospaceLayout: EditorLayout {
    public init() {}
    public func moveVertically(_ state: EditorState, _ range: SelectionRange, forward: Bool) -> SelectionRange {
        let start = range.head
        if start == (forward ? state.doc.length : 0) { return SelectionRange.cursor(start, assoc: range.assoc) }
        let line = state.doc.lineAt(start)
        let goal = range.goalColumn ?? (start - line.from)
        let targetNumber = line.number + (forward ? 1 : -1)
        if targetNumber < 1 { return SelectionRange.cursor(0, assoc: 1, goalColumn: goal) }
        if targetNumber > state.doc.lines { return SelectionRange.cursor(state.doc.length, assoc: -1, goalColumn: goal) }
        let target = state.doc.line(targetNumber)
        return SelectionRange.cursor(target.from + min(goal, target.length), goalColumn: goal)
    }
    public func moveToLineBoundary(_ state: EditorState, _ range: SelectionRange, forward: Bool, includeWrap: Bool) -> SelectionRange {
        let line = state.doc.lineAt(range.head)
        return SelectionRange.cursor(forward ? line.to : line.from, assoc: forward ? -1 : 1)
    }
    public func lineBlockAt(_ state: EditorState, _ pos: Int) -> (from: Int, to: Int) {
        let l = state.doc.lineAt(pos)
        return (l.from, l.to)
    }
}

public final class CommandEnv {
    /// Wall-clock "now" (date commands, daily note). Local time zone.
    public var now: Date
    /// Transaction time in milliseconds, used for history grouping.
    public var time: Double
    public var history: HistoryState
    public var layout: EditorLayout
    public var calendar: Calendar
    /// Frontmatter hook for typing the third `-` on line 1: return true if the
    /// file had no frontmatter and the app created an empty one (the editor
    /// then deletes the `--`). Default: pretend the file has none.
    public var createFrontmatter: () -> Bool
    /// Observer for every dispatched transaction (autocomplete state).
    public var onTransaction: ((Transaction) -> Void)?

    public init(now: Date = Date(), time: Double? = nil, history: HistoryState = HistoryState(),
                layout: EditorLayout = MonospaceLayout(), calendar: Calendar = .current,
                createFrontmatter: @escaping () -> Bool = { true }) {
        self.now = now
        self.time = time ?? now.timeIntervalSince1970 * 1000
        self.history = history
        self.layout = layout
        self.calendar = calendar
        self.createFrontmatter = createFrontmatter
    }
}

/// What a command sees: the current state and a dispatch function (CM's
/// `{state, dispatch}` / `EditorView` shape).
public final class CommandTarget {
    public private(set) var state: EditorState
    public let env: CommandEnv
    public private(set) var dispatchCount = 0

    init(state: EditorState, env: CommandEnv) {
        self.state = state
        self.env = env
    }

    /// Set when a dispatch "threw" (CM raised a RangeError inside
    /// `view.dispatch`); like a JS exception, it ends the key handling.
    public private(set) var aborted = false

    public func dispatch(_ spec: TransactionSpec) {
        if aborted { return }
        if let s = Pipeline.dispatch(spec, on: state, env: env) { state = s } else { aborted = true }
        dispatchCount += 1
    }

    func dispatchFromHistory(_ spec: TransactionSpec, _ fh: HistoryState.FromHistory) {
        if aborted { return }
        if let s = Pipeline.dispatch(spec, on: state, env: env, fromHistory: fh) { state = s } else { aborted = true }
        dispatchCount += 1
    }
}

public typealias Command = (CommandTarget) -> Bool

enum Pipeline {
    /// CM `view.dispatch(spec)`: build the transaction, run transaction
    /// filters (in CM's reverse facet order: heading guard, then list-prefix
    /// guard), then update history.
    ///
    /// CM quirk reproduced on purpose: a filter that returns
    /// `[tr, {selection}]` goes through `mergeTransaction`, which maps the
    /// filter's selection (already in new-document coordinates) through the
    /// transaction's changes a second time. When a position lies beyond the
    /// old document length CM throws a RangeError and the whole dispatch is
    /// dropped; that is signalled here by returning nil.
    static func dispatch(_ spec: TransactionSpec, on state: EditorState, env: CommandEnv,
                         fromHistory: HistoryState.FromHistory? = nil) -> EditorState? {
        var tr = state.update(spec)
        if spec.filter {
            for filter in [Filters.headingSelectionGuard, Filters.listPrefixSelectionGuard] {
                if var sel = filter(tr) {
                    if !tr.changes.isEmpty {
                        let oldLen = tr.changes.docLength
                        if sel.ranges.contains(where: { $0.anchor > oldLen || $0.head > oldLen }) { return nil }
                        sel = sel.map(tr.changes)
                    }
                    tr = Transaction(startState: tr.startState, state: tr.state.withSelection(sel), changes: tr.changes,
                                     selectionSet: true, userEvent: tr.userEvent)
                }
            }
        }
        env.history = env.history.apply(tr, time: env.time, addToHistory: spec.addToHistory, fromHistory: fromHistory)
        env.onTransaction?(tr)
        return tr.state
    }
}

/// A document plus its editing environment. The AppKit layer owns one per
/// open file (history is per file, like the web app's per-file compartment).
public final class EditorSession {
    public private(set) var state: EditorState
    public let env: CommandEnv

    public init(state: EditorState, env: CommandEnv = CommandEnv()) {
        self.state = state
        self.env = env
    }

    /// Run a key chord ("Enter", "Mod-b", "Shift-Tab", ...). Returns true if a
    /// binding handled it.
    @discardableResult
    public func handle(_ key: String) -> Bool {
        if let s = Keymap.handle(key, state: state, env: env) { state = s; return true }
        return false
    }

    /// Typed text (IME-committed / keyDown characters).
    public func insertText(_ text: String) {
        state = Keymap.insertText(text, state: state, env: env)
    }

    /// Replace the state without touching history (document swap / reload).
    public func replaceState(_ s: EditorState, resetHistory: Bool = true) {
        state = s
        if resetHistory { env.history = HistoryState() }
    }

    /// Dispatch an arbitrary transaction through filters and history.
    public func dispatch(_ spec: TransactionSpec) {
        if let s = Pipeline.dispatch(spec, on: state, env: env) { state = s }
    }

    /// Run a command (e.g. a context-menu action).
    @discardableResult
    public func run(_ command: Command) -> Bool {
        let t = CommandTarget(state: state, env: env)
        let ok = command(t)
        state = t.state
        return ok
    }
}

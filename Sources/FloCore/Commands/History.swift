import Foundation

// Port of @codemirror/commands history.ts (HistEvent, HistoryState,
// addChanges grouping rules, selection events, undo/redo pop).

struct HistEvent {
    /// Inverted changes (nil for selection-only events).
    var changes: ChangeSet?
    /// Accumulated mapping from addToHistory=false transactions.
    var mapped: ChangeSet?
    var startSelection: EditorSelection?
    var selectionsAfter: [EditorSelection]

    func setSelAfter(_ after: [EditorSelection]) -> HistEvent {
        HistEvent(changes: changes, mapped: mapped, startSelection: startSelection, selectionsAfter: after)
    }

    static func fromTransaction(_ tr: Transaction, selection: EditorSelection? = nil) -> HistEvent? {
        if tr.changes.isEmpty { return nil }
        return HistEvent(changes: tr.changes.invert(tr.startState.doc), mapped: nil,
                         startSelection: selection ?? tr.startState.selection, selectionsAfter: [])
    }

    static func selection(_ sels: [EditorSelection]) -> HistEvent {
        HistEvent(changes: nil, mapped: nil, startSelection: nil, selectionsAfter: sels)
    }
}

public struct HistoryConfig {
    public var minDepth = 100
    /// Milliseconds.
    public var newGroupDelay: Double = 500
    public init() {}
}

/// CM's `HistoryState`, a value type the session owns.
public struct HistoryState {
    var done: [HistEvent] = []
    var undone: [HistEvent] = []
    /// CM `undoDepth`/`redoDepth` > 0 (first done event may be selection-only).
    public var canUndo: Bool { done.contains { $0.changes != nil } }
    public var canRedo: Bool { undone.contains { $0.changes != nil } }
    var prevTime: Double = 0
    var prevUserEvent: String? = nil
    public var config = HistoryConfig()

    public init() {}

    public var undoDepth: Int { done.count - (done.first.map { $0.changes == nil ? 1 : 0 } ?? 0) }
    public var redoDepth: Int { undone.count - (undone.first.map { $0.changes == nil ? 1 : 0 } ?? 0) }

    static let joinableUserEvent = JSRegex("^(input\\.type|delete)($|\\.)")
    static let selectEvent = JSRegex("^select($|\\.)")

    func isolate() -> HistoryState {
        guard prevTime != 0 else { return self }
        var h = HistoryState(); h.done = done; h.undone = undone; h.config = config
        return h
    }

    static func updateBranch(_ branch: [HistEvent], _ to: Int, _ maxLen: Int, _ newEvent: HistEvent) -> [HistEvent] {
        let start = to + 1 > maxLen + 20 ? to - maxLen - 1 : 0
        var nb = Array(branch[start..<to])
        nb.append(newEvent)
        return nb
    }

    static func isAdjacent(_ a: ChangeSet, _ b: ChangeSet) -> Bool {
        var ranges: [Int] = []
        var adj = false
        a.iterChangedRanges { f, t, _, _ in ranges += [f, t] }
        b.iterChangedRanges { _, _, f, t in
            var i = 0
            while i < ranges.count {
                let from = ranges[i], to = ranges[i + 1]
                i += 2
                if t >= from && f <= to { adj = true }
            }
        }
        return adj
    }

    static func eqSelectionShape(_ a: EditorSelection, _ b: EditorSelection) -> Bool {
        a.ranges.count == b.ranges.count && zip(a.ranges, b.ranges).allSatisfy { $0.empty == $1.empty }
    }

    static func addSelection(_ branch: [HistEvent], _ selection: EditorSelection) -> [HistEvent] {
        guard let last = branch.last else { return [HistEvent.selection([selection])] }
        var sels = Array(last.selectionsAfter.suffix(200))
        if let l = sels.last, l.eq(selection) { return branch }
        sels.append(selection)
        return updateBranch(branch, branch.count - 1, 1_000_000_000, last.setSelAfter(sels))
    }

    static func popSelection(_ branch: [HistEvent]) -> [HistEvent] {
        var nb = branch
        let last = branch[branch.count - 1]
        nb[branch.count - 1] = last.setSelAfter(Array(last.selectionsAfter.dropLast()))
        return nb
    }

    static func addMappingToBranch(_ branch: [HistEvent], _ mapping0: ChangeSet) -> [HistEvent] {
        if branch.isEmpty { return branch }
        var length = branch.count
        var selections: [EditorSelection] = []
        var mapping = mapping0
        while length > 0 {
            let event = mapEvent(branch[length - 1], mapping, selections)
            if let c = event.changes, !c.isEmpty {
                var result = Array(branch[0..<length])
                result[length - 1] = event
                return result
            }
            mapping = event.mapped ?? mapping
            length -= 1
            selections = event.selectionsAfter
        }
        return selections.isEmpty ? [] : [HistEvent.selection(selections)]
    }

    static func mapEvent(_ event: HistEvent, _ mapping: ChangeSet, _ extra: [EditorSelection]) -> HistEvent {
        let selections = event.selectionsAfter.map { $0.map(mapping) } + extra
        guard let changes = event.changes else { return HistEvent.selection(selections) }
        let mappedChanges = changes.map(mapping)
        let before = mapping.mapDesc(changes, before: true)
        let fullMapping = event.mapped.map { $0.composeDesc(before) } ?? before
        return HistEvent(changes: mappedChanges, mapped: fullMapping,
                         startSelection: event.startSelection?.map(before), selectionsAfter: selections)
    }

    func addChanges(_ event: HistEvent, time: Double, userEvent: String?, tr: Transaction) -> HistoryState {
        var done = self.done
        let lastEvent = done.last
        if let last = lastEvent, let lc = last.changes, !lc.isEmpty, let ec = event.changes,
           userEvent == nil || HistoryState.joinableUserEvent.test(userEvent!),
           (last.selectionsAfter.isEmpty && time - prevTime < config.newGroupDelay &&
               HistoryState.isAdjacent(lc, ec)) || userEvent == "input.type.compose" {
            done = HistoryState.updateBranch(done, done.count - 1, config.minDepth,
                                             HistEvent(changes: ec.compose(lc), mapped: last.mapped,
                                                       startSelection: last.startSelection, selectionsAfter: []))
        } else {
            done = HistoryState.updateBranch(done, done.count, config.minDepth, event)
        }
        var h = HistoryState(); h.done = done; h.undone = []; h.prevTime = time; h.prevUserEvent = userEvent; h.config = config
        return h
    }

    func addSelection(_ selection: EditorSelection, time: Double, userEvent: String?) -> HistoryState {
        let last = done.last?.selectionsAfter ?? []
        if !last.isEmpty && time - prevTime < config.newGroupDelay && userEvent == prevUserEvent,
           let ue = userEvent, HistoryState.selectEvent.test(ue),
           HistoryState.eqSelectionShape(last[last.count - 1], selection) {
            return self
        }
        var h = self
        h.done = HistoryState.addSelection(done, selection)
        h.prevTime = time
        h.prevUserEvent = userEvent
        return h
    }

    func addMapping(_ mapping: ChangeSet) -> HistoryState {
        var h = self
        h.done = HistoryState.addMappingToBranch(done, mapping)
        h.undone = HistoryState.addMappingToBranch(undone, mapping)
        return h
    }

    /// Info carried by an undo/redo transaction (CM's `fromHistory` annotation).
    struct FromHistory {
        let side: Int  // 0 = done (undo), 1 = undone (redo)
        let rest: [HistEvent]
        let selection: EditorSelection
    }

    /// CM `HistoryState.pop`: returns the transaction spec to dispatch.
    func pop(side: Int, state: EditorState, onlySelection: Bool) -> (TransactionSpec, FromHistory)? {
        let branch = side == 0 ? done : undone
        guard let event = branch.last else { return nil }
        let selection = event.selectionsAfter.first
            ?? (event.startSelection.map { s in event.changes.map { s.map($0.invertedDesc, assoc: 1) } ?? s } ?? state.selection)
        if onlySelection && !event.selectionsAfter.isEmpty {
            return (TransactionSpec(selection: event.selectionsAfter[event.selectionsAfter.count - 1],
                                    userEvent: side == 0 ? "select.undo" : "select.redo"),
                    FromHistory(side: side, rest: HistoryState.popSelection(branch), selection: selection))
        } else if event.changes == nil {
            return nil
        } else {
            var rest = branch.count == 1 ? [] : Array(branch.dropLast())
            if let m = event.mapped { rest = HistoryState.addMappingToBranch(rest, m) }
            return (TransactionSpec(changeSet: event.changes, selection: event.startSelection,
                                    userEvent: side == 0 ? "undo" : "redo", filter: false),
                    FromHistory(side: side, rest: rest, selection: selection))
        }
    }

    /// The history state field's `update(state, tr)`.
    func apply(_ tr: Transaction, time: Double, addToHistory: Bool, fromHistory: FromHistory?) -> HistoryState {
        if let fh = fromHistory {
            let item = HistEvent.fromTransaction(tr, selection: fh.selection)
            var other = fh.side == 0 ? undone : done
            if let item = item {
                other = HistoryState.updateBranch(other, other.count, config.minDepth, item)
            } else {
                other = HistoryState.addSelection(other, tr.startState.selection)
            }
            var h = HistoryState(); h.config = config
            h.done = fh.side == 0 ? fh.rest : other
            h.undone = fh.side == 0 ? other : fh.rest
            return h
        }
        if !addToHistory {
            return tr.changes.isEmpty ? self : addMapping(tr.changes.desc)
        }
        var state = self
        if let event = HistEvent.fromTransaction(tr) {
            state = state.addChanges(event, time: time, userEvent: tr.userEvent, tr: tr)
        } else if tr.selectionSet {
            state = state.addSelection(tr.startState.selection, time: time, userEvent: tr.userEvent)
        }
        return state
    }
}

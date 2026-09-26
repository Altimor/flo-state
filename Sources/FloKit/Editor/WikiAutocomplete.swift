import AppKit
import FloCore

// Wiki-link autocomplete (wiki-link-extension.ts wikiLinkCompletions) on a
// port of @codemirror/autocomplete 6.20.1's completion state machine:
// activate on typing (100 ms debounce), results kept while `validFor` holds
// (later typing only re-filters them with FuzzyMatcher), Backspace past the
// start closes, any other selection change resets.

// MARK: - FuzzyMatcher (verbatim port, including its reused buffers)

final class FuzzyMatcher {
    let pattern: [UInt16]
    var chars: [UInt32] = []
    var folded: [UInt32] = []
    var any: [Int] = []
    var precise: [Int] = []
    var byWord: [Int] = []
    var score = 0
    var matched: [Int] = []
    let astral: Bool

    init(_ pattern: String) {
        self.pattern = Array(pattern.utf16)
        for sc in pattern.unicodeScalars {
            chars.append(sc.value)
            let part = String(sc)
            let upper = part.uppercased()
            let f = upper == part ? part.lowercased() : upper
            folded.append(f.unicodeScalars.first!.value)
        }
        astral = self.pattern.count != chars.count
    }

    private func ret(_ score: Int, _ matched: [Int]) -> FuzzyMatcher { self.score = score; self.matched = matched; return self }

    static func codePoint(_ w: [UInt16], _ i: Int) -> (UInt32, Int) {
        let u = w[i]
        if u >= 0xD800 && u < 0xDC00 && i + 1 < w.count, w[i + 1] >= 0xDC00 && w[i + 1] < 0xE000 {
            return (0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(w[i + 1]) - 0xDC00), 2)
        }
        return (UInt32(u), 1)
    }

    private static func setAt(_ a: inout [Int], _ i: Int, _ v: Int) {
        if i < a.count { a[i] = v } else { while a.count < i { a.append(0) }; a.append(v) }
    }

    func match(_ wordStr: String) -> FuzzyMatcher? {
        let word = Array(wordStr.utf16)
        if pattern.isEmpty { return ret(-100, []) }
        if word.count < pattern.count { return nil }
        if chars.count == 1 {
            let (first, firstSize) = Self.codePoint(word, 0)
            var score = firstSize == word.count ? 0 : -100
            if first == chars[0] {} else if first == folded[0] { score += -200 } else { return nil }
            return ret(score, [0, firstSize])
        }
        let direct = Self.indexOf(word, pattern)
        if direct == 0 { return ret(word.count == pattern.count ? 0 : -100, [0, pattern.count]) }
        let len = chars.count
        var anyTo = 0
        if direct < 0 {
            var i = 0
            let e = min(word.count, 200)
            while i < e && anyTo < len {
                let (next, size) = Self.codePoint(word, i)
                if next == chars[anyTo] || next == folded[anyTo] { Self.setAt(&any, anyTo, i); anyTo += 1 }
                i += size
            }
            if anyTo < len { return nil }
        }
        var preciseTo = 0
        var byWordTo = 0, byWordFolded = false
        var adjacentTo = 0, adjacentStart = -1, adjacentEnd = -1
        let hasLower = word.contains { $0 >= 97 && $0 <= 122 }
        var wordAdjacent = true
        var i = 0, prevType = 0
        let e = min(word.count, 200)
        while i < e && byWordTo < len {
            let (next, size) = Self.codePoint(word, i)
            if direct < 0 {
                if preciseTo < len && next == chars[preciseTo] { Self.setAt(&precise, preciseTo, i); preciseTo += 1 }
                if adjacentTo < len {
                    if next == chars[adjacentTo] || next == folded[adjacentTo] {
                        if adjacentTo == 0 { adjacentStart = i }
                        adjacentEnd = i + 1
                        adjacentTo += 1
                    } else {
                        adjacentTo = 0
                    }
                }
            }
            let type: Int
            if next < 0xff {
                type = (next >= 48 && next <= 57) || (next >= 97 && next <= 122) ? 2 : (next >= 65 && next <= 90 ? 1 : 0)
            } else {
                let ch = String(Unicode.Scalar(next).map(Character.init) ?? " ")
                type = ch != ch.lowercased() ? 1 : (ch != ch.uppercased() ? 2 : 0)
            }
            if i == 0 || (type == 1 && hasLower) || (prevType == 0 && type != 0) {
                if chars[byWordTo] == next || (folded[byWordTo] == next && { byWordFolded = true; return true }()) {
                    Self.setAt(&byWord, byWordTo, i); byWordTo += 1
                } else if !byWord.isEmpty {
                    wordAdjacent = false
                }
            }
            prevType = type
            i += size
        }
        if byWordTo == len && byWord[0] == 0 && wordAdjacent {
            return result(-100 + (byWordFolded ? -200 : 0), Array(byWord.prefix(len)), word)
        }
        if adjacentTo == len && adjacentStart == 0 {
            return ret(-200 - word.count + (adjacentEnd == word.count ? 0 : -100), [0, adjacentEnd])
        }
        if direct > -1 { return ret(-700 - word.count, [direct, direct + pattern.count]) }
        if adjacentTo == len { return ret(-200 + -700 - word.count, [adjacentStart, adjacentEnd]) }
        if byWordTo == len {
            return result(-100 + (byWordFolded ? -200 : 0) + -700 + (wordAdjacent ? 0 : -1100), Array(byWord.prefix(len)), word)
        }
        return chars.count == 2 ? nil : result((any[0] != 0 ? -700 : 0) + -200 + -1100, Array(any.prefix(len)), word)
    }

    private func result(_ score: Int, _ positions: [Int], _ word: [UInt16]) -> FuzzyMatcher {
        var out: [Int] = []
        for pos in positions {
            let to = pos + (astral ? Self.codePoint(word, pos).1 : 1)
            if !out.isEmpty && out[out.count - 1] == pos { out[out.count - 1] = to } else { out.append(pos); out.append(to) }
        }
        return ret(score - word.count, out)
    }

    static func indexOf(_ hay: [UInt16], _ needle: [UInt16]) -> Int {
        if needle.isEmpty { return 0 }
        if needle.count > hay.count { return -1 }
        outer: for i in 0...(hay.count - needle.count) {
            for j in 0..<needle.count where hay[i + j] != needle[j] { continue outer }
            return i
        }
        return -1
    }
}

// MARK: - completion model

/// One completion option (a file).
public struct WikiCompletion: Equatable {
    public var label: String
    public var detail: String?
    /// Text inserted before `]]`.
    public var insert: String
    public init(label: String, detail: String?, insert: String) { self.label = label; self.detail = detail; self.insert = insert }
}

final class CompletionResultSet {
    let options: [WikiCompletion]
    let from: Int
    init(options: [WikiCompletion], from: Int) { self.options = options; self.from = from }
}

/// `ActiveSource` / `ActiveResult` for the single wiki source.
enum ActiveSource {
    case inactive
    case pending(explicit: Bool)
    case result(explicit: Bool, limit: Int, result: CompletionResultSet, from: Int, to: Int)

    var isPending: Bool { if case .pending = self { return true }; return false }
    var isInactive: Bool { if case .inactive = self { return true }; return false }
    var hasResult: Bool { if case .result = self { return true }; return false }
}

/// A rendered option: completion, matched label ranges, score.
public struct CompletionOption: Equatable {
    public var completion: WikiCompletion
    public var matched: [Int]
    var index: Int
    var score: Int
}

struct CompletionDialog {
    var options: [CompletionOption]
    var selected: Int
    var timestamp: Double
    var disabled: Bool
    var pos: Int
}

final class WikiCompletionState {
    var active: ActiveSource = .inactive
    var open: CompletionDialog?
    var popup: WikiCompletionPopup?
    var debounce: Timer?
    var pendingStart = false
    /// Clock in ms (tests override).
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
}

/// `validFor: /^[^\]#^|]*$/`.
func wikiValidFor(_ s: String) -> Bool { !s.contains(where: { "]#^|".contains($0) }) }

extension EditorFeatures {
    // MARK: source

    /// `wikiLinkCompletions(context)`: nil when not applicable.
    func wikiSource(_ state: EditorState) -> CompletionResultSet? {
        let pos = state.selection.main.head
        let line = state.doc.lineAt(pos)
        let start = max(line.from, pos - 250)
        let str = state.doc.slice(start, pos) as NSString
        let re = try! NSRegularExpression(pattern: #"\[\[([^\]#^|]*)$"#)
        guard let m = re.firstMatch(in: str as String, range: NSRange(location: 0, length: str.length)) else { return nil }
        let matchFrom = start + m.range.location
        let query = str.substring(from: m.range.location + 2)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if Self.isInsideCode(state, matchFrom) { return nil }
        if !state.selection.main.empty { return nil }
        guard editor.workspaceRoot != nil, let search = wikiCompletions else { return nil }
        let results = search(query, 20)
        if results.isEmpty { return nil }
        let options = results.map { r -> WikiCompletion in
            let insert = WikiLinkResolver.canonicalTarget(r, allFiles: results)
            let stem = LinkPaths.getFileStem(r.filename)
            let rel = r.relativePath as NSString, fn = r.filename as NSString
            var dir = rel.substring(to: max(0, rel.length - fn.length))
            if dir.hasSuffix("/") { dir.removeLast() }
            return WikiCompletion(label: stem, detail: dir.isEmpty ? nil : dir, insert: insert)
        }
        return CompletionResultSet(options: options, from: matchFrom + 2)
    }

    static let codeNodeNames: Set<String> = ["FencedCode", "InlineCode", "CodeBlock", "CodeText", "CodeInfo"]
    static func isInsideCode(_ state: EditorState, _ pos: Int) -> Bool {
        var inside = false
        state.tree.iterate(from: pos, to: pos, enter: { n, _ in
            if inside { return false }
            if codeNodeNames.contains(n.name) { inside = true; return false }
            return true
        })
        return inside
    }

    // MARK: sortOptions

    func sortOptions(_ state: EditorState) -> [CompletionOption] {
        guard case let .result(_, _, result, from, to) = completion.active else { return [] }
        let pattern = state.sliceDoc(from, to)
        let matcher = FuzzyMatcher(pattern)
        var opts: [CompletionOption] = []
        for (i, o) in result.options.enumerated() {
            if let m = matcher.match(o.label) {
                opts.append(CompletionOption(completion: o, matched: m.matched, index: i, score: m.score))
            }
        }
        opts.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let c = a.completion.label.compare(b.completion.label, locale: Locale.current)
            if c != .orderedSame { return c == .orderedAscending }
            return a.index < b.index // Array.sort is stable in JS
        }
        // drop duplicates (same label/detail/apply): apply differs per option here, so keep all
        return opts
    }

    // MARK: state updates (CompletionState.update)

    private func updateType(_ tr: Transaction) -> Int {
        if tr.isUserEvent("input.type") { return 4 | 1 }
        if tr.isUserEvent("delete.backward") { return 2 }
        if tr.selectionSet { return 8 }
        if tr.docChanged { return 16 }
        return 0
    }

    private func updateActive(_ a: ActiveSource, _ tr: Transaction) -> ActiveSource {
        let type = updateType(tr)
        var value = a
        let cur = tr.state.selection.main.head
        let touches: Bool = {
            if case let .result(_, _, _, f, t) = a { return tr.changes.touchesRange(f, t) }
            return tr.changes.touchesRange(cur)
        }()
        if type & 8 != 0 || (type & 16 != 0 && touches) { value = .inactive }
        if type & 4 != 0, value.isInactive { value = .pending(explicit: false) }
        // updateFor
        if case let .result(explicit, limit, result, from, to) = value {
            if type & 3 == 0 {
                if !tr.changes.isEmpty {
                    value = .result(explicit: explicit, limit: tr.changes.mapPos(limit), result: result,
                                    from: tr.changes.mapPos(from), to: tr.changes.mapPos(to, assoc: 1))
                }
            } else {
                let nf = tr.changes.mapPos(from), nt = tr.changes.mapPos(to, assoc: 1)
                let pos = cur
                if pos > nt || (type & 2 != 0 && (tr.startState.selection.main.head == from || pos < limit)) {
                    value = type & 4 != 0 ? .pending(explicit: false) : .inactive
                } else {
                    let nl = tr.changes.mapPos(limit)
                    if wikiValidFor(tr.state.sliceDoc(nf, nt)) {
                        value = .result(explicit: explicit, limit: nl, result: result, from: nf, to: nt)
                    } else {
                        value = .pending(explicit: explicit)
                    }
                }
            }
        }
        return value
    }

    /// Apply a batch of transactions to the completion state.
    func completionTransactions(_ trs: [Transaction]) {
        for tr in trs { completionUpdate(tr: tr, didSetActive: nil) }
        scheduleQuery()
        renderPopup()
    }

    /// One CompletionState.update step. `didSetActive` = a setActive effect.
    private func completionUpdate(tr: Transaction?, didSetActive: ActiveSource?, close: Bool = false, start: Bool = false) {
        let prevActive = completion.active
        var active = prevActive
        if let tr = tr { active = updateActive(active, tr) }
        if start { active = .pending(explicit: true) }
        if close { active = .inactive }
        let didSet = didSetActive != nil
        if let s = didSetActive { active = s }
        completion.active = active
        let state = tr?.state ?? editor.state
        var open = completion.open
        if var o = open, let tr = tr, !tr.changes.isEmpty { o.pos = tr.changes.mapPos(o.pos); open = o }
        let sameResults: Bool = {
            switch (prevActive, active) {
            case let (.result(_, _, r1, _, _), .result(_, _, r2, _, _)): return r1 === r2
            case (.result, _), (_, .result): return false
            default: return true
            }
        }()
        var touchesResult = false
        if let tr = tr, case let .result(_, _, _, f, t) = active { touchesResult = tr.changes.touchesRange(f, t) }
        if (tr?.selectionSet ?? false) || touchesResult || !sameResults || didSet {
            open = buildDialog(state, prev: open, didSet: didSet)
        } else if let o = open, o.disabled, !active.isPending {
            open = nil
        }
        if open == nil, !active.isPending, active.hasResult { completion.active = .inactive }
        completion.open = open
    }

    private func buildDialog(_ state: EditorState, prev: CompletionDialog?, didSet: Bool) -> CompletionDialog? {
        let active = completion.active
        if var p = prev, !didSet, active.isPending { p.disabled = true; return p }
        let options = sortOptions(state)
        if options.isEmpty {
            if var p = prev, active.isPending { p.disabled = true; return p }
            return nil
        }
        var selected = 0
        if let p = prev, p.selected != selected, p.selected != -1, p.selected < p.options.count {
            let value = p.options[p.selected]
            if let i = options.firstIndex(where: { $0.completion == value.completion && $0.index == value.index }) { selected = i }
        }
        guard case let .result(_, _, _, from, _) = active else { return nil }
        return CompletionDialog(options: options, selected: selected, timestamp: prev?.timestamp ?? completion.now(), disabled: false, pos: from)
    }

    // MARK: querying (completionPlugin)

    private func scheduleQuery() {
        completion.debounce?.invalidate()
        completion.debounce = nil
        guard completion.active.isPending else { return }
        let delay = completion.pendingStart ? 0.05 : 0.1
        completion.debounce = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.runPendingQuery()
        }
    }

    /// `startUpdate` + `accept` (the source is synchronous). Tests call this
    /// directly to skip the debounce.
    public func runPendingQuery() {
        completion.debounce?.invalidate()
        completion.debounce = nil
        completion.pendingStart = false
        guard case let .pending(explicit) = completion.active else { return }
        let state = editor.state
        let pos = state.selection.main.head
        if let res = wikiSource(state) {
            let limit = min(pos, res.from + (explicit ? 0 : 1))
            completionUpdate(tr: nil, didSetActive: .result(explicit: explicit, limit: limit, result: res, from: res.from, to: pos))
        } else {
            completionUpdate(tr: nil, didSetActive: .inactive)
        }
        renderPopup()
    }

    /// True while a query is waiting on its debounce.
    public var completionQueryPending: Bool { completion.debounce != nil }

    // MARK: commands (completionKeymap)

    func completionHandleKey(_ k: String) -> Bool {
        switch k {
        case "Ctrl- ", "Alt-`", "Alt-i":
            completion.pendingStart = true
            completionUpdate(tr: nil, didSetActive: nil, start: true)
            scheduleQuery(); renderPopup()
            return true
        case "Escape":
            guard !completion.active.isInactive else { return false }
            closeCompletion()
            return true
        case "ArrowDown": return moveCompletionSelection(true, page: false)
        case "ArrowUp": return moveCompletionSelection(false, page: false)
        case "PageDown": return moveCompletionSelection(true, page: true)
        case "PageUp": return moveCompletionSelection(false, page: true)
        case "Enter": return acceptCompletion()
        default: return false
        }
    }

    public func closeCompletion() {
        completionUpdate(tr: nil, didSetActive: nil, close: true)
        scheduleQuery()
        renderPopup()
    }

    private var interactive: Bool {
        guard let o = completion.open, !o.disabled else { return false }
        return completion.now() - o.timestamp >= 75
    }

    func moveCompletionSelection(_ forward: Bool, page: Bool) -> Bool {
        guard interactive, var o = completion.open else { return false }
        var step = 1
        if page { step = max(2, Int(floor(WikiCompletionPopup.listHeight(o.options.count) / WikiCompletionPopup.rowHeight)) - 1) }
        let length = o.options.count
        var sel = o.selected > -1 ? o.selected + step * (forward ? 1 : -1) : (forward ? 0 : length - 1)
        if sel < 0 { sel = page ? 0 : length - 1 } else if sel >= length { sel = page ? length - 1 : 0 }
        o.selected = sel
        completion.open = o
        renderPopup()
        return true
    }

    func acceptCompletion() -> Bool {
        guard interactive, let o = completion.open, o.selected >= 0 else { return false }
        applyCompletion(o.options[o.selected])
        return true
    }

    /// The option's `apply`: insert `target]]`, consuming a following `]]`.
    func applyCompletion(_ opt: CompletionOption) {
        guard case let .result(_, _, _, from, to) = completion.active else { return }
        editor.run { t in
            let after = t.state.sliceDoc(to, min(t.state.doc.length, to + 2))
            let end = after == "]]" ? to + 2 : to
            let insert = "\(opt.completion.insert)]]"
            t.dispatch(TransactionSpec(changes: [Change(from: from, to: end, insert: insert)], selection: .cursor(from + insert.utf16.count)))
            return true
        }
    }

    /// closeOnBlur.
    func editorDidBlur() {
        guard completion.open != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self = self, self.editor.textView.window?.firstResponder !== self.editor.textView else { return }
            self.closeCompletion()
        }
    }

    /// Options currently shown (tests).
    public var completionOptions: [CompletionOption]? { completion.open.map { $0.options } }
    public var completionSelected: Int? { completion.open?.selected }
    public var completionDisabled: Bool { completion.open?.disabled ?? false }
    func setCompletionClock(_ f: @escaping () -> Double) { completion.now = f }

    // MARK: popup

    func renderPopup() {
        guard let o = completion.open else { completion.popup?.removeFromSuperview(); completion.popup = nil; return }
        guard let host = editor.textView.window?.contentView else { return }
        let p: WikiCompletionPopup
        if let e = completion.popup { p = e } else { p = WikiCompletionPopup(); p.features = self; completion.popup = p }
        if p.superview !== host { host.addSubview(p) }
        p.dialog = o
        p.layoutFor(anchor: editor.completionAnchor(o.pos), in: host)
        p.needsDisplay = true
    }

    // MARK: pointer (link cursor)

    func pointerOverLink(_ event: NSEvent) -> Bool {
        guard editor.onLinkClick != nil else { return false }
        let tv = editor.textView
        let i = tv.characterIndexForInsertion(at: tv.convert(event.locationInWindow, from: nil))
        guard i != NSNotFound else { return false }
        return editor.link(at: i) != nil || (i > 0 && editor.link(at: i - 1) != nil)
    }
}

extension EditorController {
    /// `coordsAtPos(pos)`: x of the position and bottom of its text box
    /// (baseline + font descent), in window coordinates (top-left based rect).
    func completionAnchor(_ pos: Int) -> NSRect? {
        guard let w = textView.window else { return nil }
        let len = state.doc.length
        let p = max(0, min(pos, len))
        var actual = NSRange()
        let screen = textView.firstRect(forCharacterRange: NSRange(location: p, length: 0), actualRange: &actual)
        if screen == .zero { return nil }
        var r = w.convertFromScreen(screen)
        // text box height: the font's ascent + descent at pos
        let font = (p < len ? textView.textStorage?.attribute(.font, at: p, effectiveRange: nil) as? NSFont : nil)
            ?? (p > 0 ? textView.textStorage?.attribute(.font, at: p - 1, effectiveRange: nil) as? NSFont : nil)
        if let f = font, let bl = baselineY(p) {
            // window coords: y up. baseline in text view (flipped) → window
            let blWin = textView.convert(NSPoint(x: 0, y: bl), to: nil).y
            r = NSRect(x: r.minX, y: blWin + f.descender, width: 0, height: f.ascender - f.descender)
        }
        return r
    }

    /// Baseline of the line fragment holding `pos`, in text view coordinates.
    func baselineY(_ pos: Int) -> CGFloat? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: pos),
              let frag = tlm.textLayoutFragment(for: loc) else { return nil }
        let off = tcm.offset(from: frag.rangeInElement.location, to: loc)
        for lf in frag.textLineFragments {
            let r = lf.characterRange
            if off >= r.location && off <= r.location + r.length {
                return textView.textContainerOrigin.y + frag.layoutFragmentFrame.minY + lf.typographicBounds.minY + lf.glyphOrigin.y
            }
        }
        return nil
    }
}

/// The completion list card (`.cm-tooltip-autocomplete`).
final class WikiCompletionPopup: NSView {
    weak var features: EditorFeatures?
    var dialog: CompletionDialog?
    var scrollTop: CGFloat = 0
    override var isFlipped: Bool { true }

    static let rowHeight: CGFloat = 27
    static let maxListHeight: CGFloat = 130 // CM's 10em at 13px wins over the app's 280px
    static let pad: CGFloat = 4, border: CGFloat = 1
    static func listHeight(_ n: Int) -> CGFloat { min(maxListHeight, CGFloat(n) * rowHeight) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        applyCardBackdrop(self, cornerRadius: 16)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `box-shadow: 0 24px 60px rgba(0,0,0,.32)` from a sibling (the card clips its blur).
    let shadowView = CardShadowView(opacity: 0.32, blur: 60, offsetY: 24, cornerRadius: 16)
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        shadowView.attach(below: self)
    }
    override func removeFromSuperview() { shadowView.removeFromSuperview(); super.removeFromSuperview() }
    override func setFrameOrigin(_ p: NSPoint) { super.setFrameOrigin(p); shadowView.follow(self) }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); shadowView.follow(self) }

    var chrome: EditorChrome { features?.chrome ?? .standard }
    var font: NSFont { chrome.uiFont(13, .regular) }

    func labelAttr(_ opt: CompletionOption, color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: opt.completion.label, attributes: [.font: font, .foregroundColor: color])
        var i = 0
        while i + 1 < opt.matched.count {
            let r = NSRange(location: opt.matched[i], length: opt.matched[i + 1] - opt.matched[i])
            if r.location + r.length <= s.length { s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
            i += 2
        }
        return s
    }

    func contentWidth(_ o: CompletionOption) -> CGFloat {
        var w = labelAttr(o, color: .black).size().width + 20
        if let d = o.completion.detail { w += 6.5 + (d as NSString).size(withAttributes: [.font: font]).width }
        return ceil(w)
    }

    func layoutFor(anchor: NSRect?, in host: NSView) {
        guard let d = dialog else { return }
        let ulW = min(min(700, host.bounds.width * 0.95), max(250, d.options.map(contentWidth).max() ?? 250))
        let ulH = Self.listHeight(d.options.count)
        let w = ulW + 2 * (Self.pad + Self.border), h = ulH + 2 * (Self.pad + Self.border)
        guard let a = anchor else { return }
        // below the text box; above when it doesn't fit and there's more room above
        let hostH = host.bounds.height
        let r = host.convert(a, from: nil)
        let boxTop = host.isFlipped ? r.minY : hostH - r.maxY
        let boxBottom = host.isFlipped ? r.maxY : hostH - r.minY
        var x = r.minX
        if x + w > host.bounds.width { x = max(0, host.bounds.width - w) }
        var yTop = boxBottom
        let spaceBelow = hostH - boxBottom, spaceAbove = boxTop
        if spaceBelow < h && spaceAbove > spaceBelow { yTop = boxTop - h }
        frame = NSRect(x: x, y: host.isFlipped ? yTop : hostH - yTop - h, width: w, height: h)
        // keep the selected row visible
        let selTop = CGFloat(max(0, d.selected)) * Self.rowHeight
        if selTop < scrollTop { scrollTop = selTop }
        if selTop + Self.rowHeight > scrollTop + ulH { scrollTop = selTop + Self.rowHeight - ulH }
        scrollTop = max(0, min(scrollTop, CGFloat(d.options.count) * Self.rowHeight - ulH))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let d = dialog else { return }
        let t = chrome.tokens
        let card = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        t.bgBase.mixedWithTransparent(0.7).nsColor.setFill(); card.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 15.5, yRadius: 15.5)
        border.lineWidth = 1; t.lineSubtler.nsColor.setStroke(); border.stroke()
        let inner = Self.pad + Self.border
        let list = NSRect(x: inner, y: inner, width: bounds.width - 2 * inner, height: bounds.height - 2 * inner)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: list).addClip()
        for (i, o) in d.options.enumerated() {
            let row = NSRect(x: list.minX, y: list.minY + CGFloat(i) * Self.rowHeight - scrollTop, width: list.width, height: Self.rowHeight)
            if !row.intersects(list) { continue }
            let sel = i == d.selected
            if sel {
                t.surfaceSelected.nsColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
            }
            let color = sel ? t.textPrimary.nsColor : t.textSecondary.nsColor
            let label = labelAttr(o, color: color)
            let ls = label.size()
            let textY = row.minY + (Self.rowHeight - ls.height) / 2
            let maxW = row.width - 20
            label.draw(with: NSRect(x: row.minX + 10, y: textY, width: min(ls.width, maxW), height: ls.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if let det = o.completion.detail, ls.width + 6.5 < maxW {
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.textMuted.nsColor]
                let dx = row.minX + 10 + ls.width + 6.5
                (det as NSString).draw(with: NSRect(x: dx, y: textY, width: row.maxX - 10 - dx, height: ls.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func row(at p: NSPoint) -> Int? {
        guard let d = dialog else { return nil }
        let inner = Self.pad + Self.border
        let y = p.y - inner + scrollTop
        guard p.x >= inner, p.x <= bounds.width - inner, y >= 0 else { return nil }
        let i = Int(y / Self.rowHeight)
        return i < d.options.count ? i : nil
    }

    // mousedown on an option applies it (no focus change)
    override func mouseDown(with event: NSEvent) {
        guard let i = row(at: convert(event.locationInWindow, from: nil)), let d = dialog else { return }
        features?.applyCompletion(d.options[i])
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let d = dialog else { return }
        let ulH = Self.listHeight(d.options.count)
        scrollTop = max(0, min(scrollTop - event.scrollingDeltaY, CGFloat(d.options.count) * Self.rowHeight - ulH))
        needsDisplay = true
    }
}

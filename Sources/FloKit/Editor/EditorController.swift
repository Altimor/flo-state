import AppKit
import FloCore

public final class EditorController: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate, NSTextStorageDelegate {
    public let theme: EditorTheme
    let applier: AttributeApplier
    public let textView: FloTextView
    public let scrollView: NSScrollView
    /// Document + history + command environment (FloCore Commands).
    public let session: EditorSession
    public var state: EditorState { session.state }
    let layout = TextKitLayout()
    /// userEvent for the next native (NSTextView-driven) edit.
    var nativeUserEvent = "input"
    /// Called after every document change (for autosave etc.).
    public var onDocChanged: ((EditorState) -> Void)?
    public var onSelectionChanged: ((EditorState) -> Void)?
    /// A click on a rendered link / URL (`href`) or wiki link (`wiki` = inner text).
    public var onLinkClick: ((LinkClick) -> Void)?

    public enum LinkClick: Equatable {
        case href(String)
        case wiki(String)
    }

    /// The link under a document position, if clicking there navigates.
    public func link(at pos: Int) -> LinkClick? {
        guard let plan = plan, pos >= 0, pos < state.doc.length else { return nil }
        // wiki links (rendered widget or revealed source)
        for w in plan.widgetsOverlapping(pos, pos) where w.from <= pos && pos < w.to {
            if case .wikiLink = w.kind {
                let raw = state.doc.slice(w.from, w.to)
                if let open = raw.range(of: "[["), let close = raw.range(of: "]]", options: .backwards) {
                    return .wiki(String(raw[open.upperBound..<close.lowerBound]))
                }
            }
        }
        guard plan.style(at: pos).clickableLink else { return nil }
        // the enclosing Link / URL node
        var found: LinkClick? = nil
        state.tree.iterate(from: pos, to: pos, enter: { n, _ in
            if found != nil { return false }
            if n.name == "URL" && n.from <= pos && pos < n.to {
                found = .href(LinkPaths.normalizeMarkdownDestination(self.state.doc.slice(n.from, n.to))); return false
            }
            if n.name == "Link", let url = n.children.last(where: { $0.name == "URL" }) {  // last: autolinks in the text are URL children too
                found = .href(LinkPaths.normalizeMarkdownDestination(self.state.doc.slice(url.from, url.to))); return false
            }
            if n.name == "Autolink" || n.name == "URL" {
                let t = self.state.doc.slice(n.from, n.to)
                found = .href(t.hasPrefix("<") && t.hasSuffix(">") ? String(t.dropFirst().dropLast()) : t); return false
            }
            return true
        })
        return found
    }

    private var plan: RenderPlan?
    var currentPlan: RenderPlan? { plan }
    let planCache = PlanCache()
    /// Find/replace, wiki autocomplete, context menu, paste (EditorFeatures.swift).
    public private(set) lazy var features = EditorFeatures(editor: self)
    /// Folded heading sections (sorted by `from`), mapped through edits.
    public internal(set) var folds: [Fold] = []
    /// Foldable sections by heading line number (1-based), for the current doc.
    public internal(set) var foldSections: [Int: Fold] = [:]
    /// Lines to re-apply on the next render regardless of their signature.
    var forceLines = IndexSet()
    /// Heading line (1-based) under the mouse, and whether it's over the chevron.
    var hoverLine: Int? { didSet { if hoverLine != oldValue { redrawLines([oldValue, hoverLine]) } } }
    var hoverChevron = false { didSet { if hoverChevron != oldValue { redrawLines([hoverLine]) } } }

    func setFolds(_ new: [Fold]) {
        let doc = state.doc
        let before = foldedLineSet(folds, doc)
        let old = folds
        folds = new.sorted { $0.from < $1.from }
        let after = foldedLineSet(folds, doc)
        forceLines.formUnion(before.symmetricDifference(after))
        // heading lines whose chevron state flipped
        for f in old + folds { forceLines.insert(doc.lineAt(f.from).number - 1) }
        render()
        clampSelectionOutOfFolds(forward: true)
        onFoldsChanged?(folds)
    }

    public var onFoldsChanged: (([Fold]) -> Void)?

    func foldedLineSet(_ fs: [Fold], _ doc: Text) -> IndexSet {
        var set = IndexSet()
        for f in fs {
            let first = doc.lineAt(f.from).number      // heading line number = next line's 0-based index
            let last = doc.lineAt(f.to).number - 1     // 0-based index of the section's last line
            if last >= first { set.insert(integersIn: first...last) }
        }
        return set
    }

    private func redrawLines(_ lines: [Int?]) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return }
        for case let n? in lines where n >= 1 && n <= state.doc.lines {
            let pos = state.doc.line(n).from
            guard let loc = tcm.location(tcm.documentRange.location, offsetBy: pos), let f = tlm.textLayoutFragment(for: loc) else { continue }
            var r = f.layoutFragmentFrame.insetBy(dx: -200, dy: -4)
            r.origin.x += textView.textContainerOrigin.x; r.origin.y += textView.textContainerOrigin.y
            textView.setNeedsDisplay(r)
        }
    }
    private var lineSigs: [Int] = []
    /// Line index (new doc) touched by the last text edit, re-applied even if its signature is unchanged.
    private var editedLines: ClosedRange<Int>?
    private var suppressSync = false
    private var pendingEdit: (range: NSRange, delta: Int)?
    public var renderCount = 0
    static let trace = ProcessInfo.processInfo.environment["PERF_TRACE"] != nil
    /// (parse, plan, signatures, apply) seconds per render when PERF_TRACE is set
    public var perfLog: [(Double, Double, Double, Double)] = []

    public init(theme: EditorTheme = EditorTheme()) {
        self.theme = theme
        applier = AttributeApplier(theme: theme, gutter: 48)
        session = EditorSession(state: EditorState(""))
        textView = FloTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView()
        super.init()
        layout.controller = self
        session.env.layout = layout
        configure()
        _ = features
        installAsyncWidgetHooks()
    }

    private func configure() {
        textView.controller = self
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false // history lives in the session (CM history)
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = false // the app's own find card (FindOverlay.swift)
        textView.isIncrementalSearchingEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.insertionPointColor = theme.primaryColor
        textView.selectedTextAttributes = [.backgroundColor: theme.selectionColor]
        textView.textLayoutManager?.delegate = self
        textView.textStorage?.delegate = self
        textView.typingAttributes = [.font: theme.font(size: theme.baseSize, weight: 400, mono: false),
                                     .foregroundColor: theme.textColor]
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
    }

    // MARK: layout column (App.css / prosemark-theme.css)

    /// Top of the first line: frontmatter wrapper pt 9rem + pb-6 + 12px border.
    public var topInset: CGFloat = 180

    public func layoutColumn() {
        let oldInset = textView.textContainerInset, oldW = textView.textContainer?.size.width
        defer {
            // the column moved or resized: images moved too; the hover box comes back on the next hover
            if imageOverlay.hit != nil, oldInset != textView.textContainerInset || oldW != textView.textContainer?.size.width { imageOverlay.show(nil) }
        }
        let w = scrollView.contentSize.width
        let sidePad = min(64, max(24, 0.04 * (scrollView.window?.frame.width ?? w)))
        let textW = max(100, min(theme.maxTextWidth, w - 2 * sidePad))
        let left = (w - textW) / 2 - applier.gutter
        // TextKit drops paragraphSpacingBefore on the first paragraph; CSS doesn't.
        var firstPad: CGFloat = 0
        if state.doc.lines > 0, let ps = textView.textStorage?.length ?? 0 > 0 ? textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil {
            firstPad = ps.paragraphSpacingBefore
        }
        textView.textContainerInset = NSSize(width: max(0, left), height: topInset + firstPad)
        let widthChanged = textView.textContainer?.size.width != textW + applier.gutter
        textView.textContainer?.size = NSSize(width: textW + applier.gutter, height: .greatestFiniteMagnitude)
        if widthChanged { scheduleFullLayout() }
        if applier.columnWidth != textW {
            applier.columnWidth = textW
            // image widths clamp to the column: re-apply lines holding images
            if plan?.widgets.contains(where: { if case .image = $0.kind { return true }; if case .wikiLink(_, true) = $0.kind { return true }; return false }) == true {
                lineSigs = []; render(force: true)
            }
        }
        textView.frame.size.width = w
        textView.minSize = NSSize(width: w, height: scrollView.contentSize.height)
        // bottom padding 40vh
        let bottom = 0.4 * (scrollView.window?.frame.height ?? 800)
        textView.bottomPadding = bottom
    }

    /// A new container width throws TextKit 2 back onto estimated heights for
    /// everything off screen, which makes the scroller lie (at the bottom it
    /// shows the middle) and scroll positions jump. Lay the whole document out
    /// again once the width settles.
    private var fullLayoutPending = false
    func scheduleFullLayout() {
        guard !fullLayoutPending else { return }
        fullLayoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.textView.inLiveResize {
                // retry after the resize ends
                self.fullLayoutPending = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.scheduleFullLayout() }
                return
            }
            self.fullLayoutPending = false
            self.ensureFullLayout()
        }
    }

    public func ensureFullLayout() {
        guard let tlm = textView.textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        textView.sizeToFit()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: document

    /// Launch tracing hook (set by the app when FLO_TRACE_LAUNCH is on).
    public static var launchTrace: ((String, Date) -> Void)?

    public func load(_ text: String, selection: EditorSelection = .cursor(0)) {
        let t = Text(text)
        session.replaceState(EditorState(doc: t, selection: selection))
        suppressSync = true
        textView.string = t.string
        suppressSync = false
        lineSigs = []
        plan = nil
        planCache.reset()
        folds = []
        foldSections = [:]
        var lt = Date()
        render(force: true)
        EditorController.launchTrace?("    render(force)", lt); lt = Date()
        layoutColumn()
        applyDefaultParagraphStyle()
        // Lay out the whole document now: TextKit 2's estimated heights for
        // unlaid-out text make the scroll position and click targets jump.
        ensureFullLayout()
        EditorController.launchTrace?("    ensureFullLayout", lt)
        setNativeSelection(state.selection)
        textView.undoManager?.removeAllActions()
        features.documentReplaced()
    }

    public var text: String { state.doc.string }

    /// The trailing empty line after a final newline has no characters to carry
    /// attributes; TextKit lays it out with the typing attributes, so give those
    /// the body paragraph box (else the caret sits at the far left).
    func applyDefaultParagraphStyle() {
        let para = NSMutableParagraphStyle()
        let lineH = theme.baseSize * theme.lineHeight
        para.minimumLineHeight = lineH; para.maximumLineHeight = lineH
        para.firstLineHeadIndent = applier.gutter; para.headIndent = applier.gutter
        textView.defaultParagraphStyle = para
        var attrs = textView.typingAttributes
        attrs[.paragraphStyle] = para
        if attrs[.font] == nil { attrs[.font] = theme.font(size: theme.baseSize, weight: 400, mono: false) }
        textView.typingAttributes = attrs
    }

    /// The open note's absolute path (image and embed resolution, paste target).
    public var documentPath: String? {
        get { applier.images.documentPath }
        set { applier.images.documentPath = newValue; applier.images.invalidate(); if plan != nil { lineSigs = []; render(force: true) } }
    }
    public var workspaceRoot: String? {
        get { applier.images.workspaceRoot }
        set { applier.images.workspaceRoot = newValue }
    }
    /// Drop cached image sizes (an attachment changed on disk).
    /// Last drawn rect of each image widget (keyed by source position); see ImageResize.swift.
    var imageRects: [Int: ImageHit] = [:]
    /// Double-clicking a rendered image opens its file (default: the user's image app, e.g. Preview).
    public var openImageFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    lazy var imageOverlay: ImageResizeOverlay = {
        let o = ImageResizeOverlay()
        o.controller = self
        o.isHidden = true
        textView.addSubview(o)
        return o
    }()

    public func reloadImages() { applier.images.invalidate(); lineSigs = []; render(force: true) }

    // MARK: rendering

    func render(force: Bool = false) {
        guard let storage = textView.textStorage else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = state.tree
        let t1 = CFAbsoluteTimeGetCurrent()
        if force { planCache.invalidated = true }
        let upd = planCache.update(state)
        let newPlan = upd.plan
        if upd.change != nil || force || foldSections.isEmpty && state.doc.lines > 1 {
            updateFoldsForDocChange(upd.change)
        }
        applier.foldedLines = foldedLineSet(folds, state.doc)
        var toggles: [Int: Bool] = [:]
        for (line, sec) in foldSections { toggles[line - 1] = folds.contains { $0.from == sec.from } }
        applier.foldToggles = toggles
        let t2 = CFAbsoluteTimeGetCurrent()
        var t3 = t2
        defer {
            if Self.trace {
                let t4 = CFAbsoluteTimeGetCurrent()
                perfLog.append((t1 - t0, t2 - t1, t3 - t2, t4 - t3))
            }
        }
        let doc = state.doc
        applier.state_units = doc.units
        suppressSync = true
        storage.beginEditing()
        var toApply: [Int] = []
        var newSigs: [Int]
        if !force, let dirty = upd.dirtyLines, lineSigs.count > 0 {
            // Map the old per-line signatures onto the new line numbering;
            // only re-planned lines can have changed.
            let unknown = Int.min
            if let sh = upd.lineShift {
                newSigs = [Int](repeating: unknown, count: doc.lines)
                let head = min(sh.oldFirst, doc.lines, lineSigs.count)
                for i in 0..<head { newSigs[i] = lineSigs[i] }
                let d = sh.newLast - sh.oldLast
                if sh.newLast + 1 < doc.lines {
                    for i in (sh.newLast + 1)..<doc.lines where i - d >= 0 && i - d < lineSigs.count { newSigs[i] = lineSigs[i - d] }
                }
            } else {
                newSigs = lineSigs.count == doc.lines ? lineSigs : [Int](repeating: unknown, count: doc.lines)
            }
            let edited = editedLines
            for r in dirty {
                for i in r where i < doc.lines {
                    let sig = applier.lineSignature(plan: newPlan, line: doc.line(i + 1), index: i)
                    if sig != newSigs[i] || edited?.contains(i) == true { toApply.append(i) }
                    newSigs[i] = sig
                }
            }
            if let e = edited {
                for i in e where i < doc.lines && !toApply.contains(i) { toApply.append(i) }
            }
            for i in forceLines where i < doc.lines {
                newSigs[i] = applier.lineSignature(plan: newPlan, line: doc.line(i + 1), index: i)
                if !toApply.contains(i) { toApply.append(i) }
            }
            if newSigs.contains(unknown) {
                // safety net: anything not re-signed gets signed and applied
                for i in 0..<doc.lines where newSigs[i] == unknown {
                    newSigs[i] = applier.lineSignature(plan: newPlan, line: doc.line(i + 1), index: i)
                    toApply.append(i)
                }
            }
        } else {
            newSigs = (0..<doc.lines).map { applier.lineSignature(plan: newPlan, line: doc.line($0 + 1), index: $0) }
            let old = force ? [] : lineSigs
            var prefix = 0
            while prefix < old.count, prefix < newSigs.count, old[prefix] == newSigs[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < old.count - prefix, suffix < newSigs.count - prefix,
                  old[old.count - 1 - suffix] == newSigs[newSigs.count - 1 - suffix] { suffix += 1 }
            if !force, let e = editedLines {
                prefix = min(prefix, e.lowerBound)
                suffix = min(suffix, max(0, newSigs.count - 1 - e.upperBound))
            }
            toApply = Array(prefix..<max(prefix, newSigs.count - suffix))
        }
        editedLines = nil
        forceLines = IndexSet()
        t3 = CFAbsoluteTimeGetCurrent()
        for i in toApply {
            applier.apply(to: storage, plan: newPlan, line: doc.line(i + 1), index: i)
        }
        storage.endEditing()
        suppressSync = false
        DispatchQueue.main.async { [weak self] in self?.textView.refreshDocumentHeight() }
        lineSigs = newSigs
        plan = newPlan
        renderCount += 1
    }

    // MARK: state <-> text storage

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        guard !suppressSync, editedMask.contains(.editedCharacters) else { return }
        if let p = pendingEdit {
            // merge (rare: multiple processEditing before textDidChange)
            let lo = min(p.range.location, editedRange.location)
            let hi = max(p.range.location + p.range.length, editedRange.location + editedRange.length)
            pendingEdit = (NSRange(location: lo, length: hi - lo), p.delta + delta)
        } else {
            pendingEdit = (editedRange, delta)
        }
    }

    public func textDidChange(_ notification: Notification) {
        guard !suppressSync, let edit = pendingEdit, let storage = textView.textStorage else { return }
        pendingEdit = nil
        let insert = (storage.string as NSString).substring(with: edit.range)
        let oldTo = edit.range.location + edit.range.length - edit.delta
        let sel = nativeSelection()
        session.env.time = Date().timeIntervalSince1970 * 1000
        session.dispatch(TransactionSpec(changes: [Change(from: edit.range.location, to: oldTo, insert: insert)],
                                         selection: sel, userEvent: nativeUserEvent))
        nativeUserEvent = "input"
        markEdited(from: edit.range.location, to: edit.range.location + edit.range.length, in: session.state.doc)
        if session.state.doc.length != storage.length {
            // a filter rejected the edit: put the text view back in sync
            resyncStorage()
        }
        render()
        if session.state.selection != sel { setNativeSelection(session.state.selection) }
        onDocChanged?(state)
        features.stateDidChange()
    }

    public func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var n = new
        if n[.paragraphStyle] == nil, let p = textView.defaultParagraphStyle { n[.paragraphStyle] = p }
        return n
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !suppressSync, pendingEdit == nil else { return }
        let sel = nativeSelection()
        guard sel != state.selection else { return }
        let before = touchedLines(state)
        session.env.time = Date().timeIntervalSince1970 * 1000
        session.dispatch(TransactionSpec(selection: sel, userEvent: "select"))
        if session.state.selection != sel { setNativeSelection(session.state.selection) }
        // live preview reveals per line: only re-render when the caret's lines change
        if touchedLines(state) != before { render() } else if state.doc.length > 0 { render() }
        onSelectionChanged?(state)
        features.stateDidChange()
    }

    private func touchedLines(_ s: EditorState) -> [Int] {
        s.selection.ranges.flatMap { [s.doc.lineAt($0.from).number, s.doc.lineAt($0.to).number] }
    }

    func nativeSelection() -> EditorSelection {
        let ranges = textView.selectedRanges.map { $0.rangeValue }
        let affinityHeadFirst = textView.selectionAffinity == .upstream
        let sr = ranges.map { r -> SelectionRange in
            affinityHeadFirst && r.length > 0
                ? SelectionRange(anchor: r.location + r.length, head: r.location)
                : SelectionRange(anchor: r.location, head: r.location + r.length)
        }
        return EditorSelection(ranges: sr.isEmpty ? [.cursor(0)] : sr, mainIndex: 0)
    }

    func setNativeSelection(_ sel: EditorSelection) {
        suppressSync = true
        let ranges = sel.ranges.map { NSValue(range: NSRange(location: $0.from, length: $0.to - $0.from)) }
        textView.setSelectedRanges(ranges, affinity: sel.main.head < sel.main.anchor ? .upstream : .downstream, stillSelecting: false)
        suppressSync = false
    }

    /// Apply a command result: diff old->new doc, replace through NSTextView
    /// (so it lands in the undo stack), then set the selection.
    /// Run a key chord through the keymap. Returns false when unbound.
    public func handleKey(_ chord: String) -> Bool {
        if features.handleKeyFirst(chord) { return true }
        switch Keymap.normalize(chord) {
        case Keymap.normalize("Mod-Alt-["): return foldAtCaret(true)
        case Keymap.normalize("Mod-Alt-]"): return foldAtCaret(false)
        case Keymap.normalize("Ctrl-Alt-["): return collapseAllHeadings()
        case Keymap.normalize("Ctrl-Alt-]"): return expandAllHeadings()
        default: break
        }
        let before = state
        session.env.time = Date().timeIntervalSince1970 * 1000
        session.env.now = Date()
        guard session.handle(chord) else { return features.handleKeyLast(chord) }
        sync(from: before)
        if !folds.isEmpty {
            let fwd = state.selection.main.head >= before.selection.main.head
            clampSelectionOutOfFolds(forward: fwd)
        }
        return true
    }

    /// Typed text. Plain inserts stay on the native NSTextView path (so text
    /// replacement, autocorrect and IME behave natively); only input handlers
    /// that do something special (auto-pairing, list continuation...) take over.
    public func insertTyped(_ s: String) -> Bool {
        let before = state
        let savedHistory = session.env.history
        session.env.time = Date().timeIntervalSince1970 * 1000
        session.env.now = Date()
        let next = Keymap.insertText(s, state: before, env: session.env)
        let plain = before.update(before.replaceSelection(s)).state
        if next.doc.units == plain.doc.units && next.selection == plain.selection {
            session.env.history = savedHistory
            features.pendingTransactions.removeAll() // the probe's, not real
            nativeUserEvent = "input.type"
            return false
        }
        session.replaceState(next, resetHistory: false)
        sync(from: before)
        return true
    }

    /// Run an arbitrary command (menus, context menu).
    @discardableResult
    public func run(_ command: @escaping Command) -> Bool {
        let before = state
        session.env.time = Date().timeIntervalSince1970 * 1000
        session.env.now = Date()
        let ok = session.run(command)
        sync(from: before)
        return ok
    }

    private func resyncStorage() {
        suppressSync = true
        textView.string = state.doc.string
        suppressSync = false
        lineSigs = []
    }

    /// Recompute foldable sections and map folds through a text change;
    /// folds the change touches are dropped (their lines are re-applied).
    private func updateFoldsForDocChange(_ change: (a: Int, bOld: Int, bNew: Int)?) {
        let doc = state.doc
        let oldSections = foldSections
        foldSections = HeadingSections.all(doc)
        if oldSections.count != foldSections.count || oldSections.keys.sorted() != foldSections.keys.sorted() {
            for l in Set(oldSections.keys).symmetricDifference(foldSections.keys) where l >= 1 && l <= doc.lines { forceLines.insert(l - 1) }
        }
        guard !folds.isEmpty, let c = change else { return }
        let delta = c.bNew - c.bOld
        var kept: [Fold] = []
        for f in folds {
            if c.bOld < f.from { kept.append(Fold(from: f.from + delta, to: f.to + delta)); continue }
            if c.a > f.to { kept.append(f); continue }
            // touched: drop, and re-apply the lines it covered
            let a = max(0, min(f.from, doc.length)), b = max(a, min(f.to + max(0, delta), doc.length))
            forceLines.insert(integersIn: (doc.lineAt(a).number - 1)...(doc.lineAt(b).number - 1))
        }
        // a fold must still match its heading's section
        folds = kept.filter { f in foldSections.values.contains { $0 == f } }
    }

    private func markEdited(from: Int, to: Int, in d: Text) {
        let a = d.lineAt(max(0, min(from, d.length))).number - 1
        let b = d.lineAt(max(0, min(to, d.length))).number - 1
        editedLines = min(a, editedLines?.lowerBound ?? a)...max(b, editedLines?.upperBound ?? b)
    }

    /// Push the session state into the text view: diff old->new doc, replace
    /// the changed span, re-render, restore the selection.
    func sync(from before: EditorState, scroll: Bool = true) {
        let next = state
        let old = before.doc.units, new = next.doc.units
        if old != new {
            var prefix = 0
            while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < old.count - prefix, suffix < new.count - prefix,
                  old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            let range = NSRange(location: prefix, length: old.count - prefix - suffix)
            let insert = String(utf16CodeUnits: Array(new[prefix..<(new.count - suffix)]), count: new.count - suffix - prefix)
            markEdited(from: prefix, to: new.count - suffix, in: next.doc)
            if textView.shouldChangeText(in: range, replacementString: insert) {
                suppressSync = true
                textView.textStorage?.replaceCharacters(in: range, with: insert)
                suppressSync = false
                pendingEdit = nil
                textView.didChangeText()
            }
        }
        render()
        setNativeSelection(state.selection)
        if scroll { textView.scrollRangeToVisible(NSRange(location: state.selection.main.head, length: 0)) }
        if old != new { onDocChanged?(state) }
        features.stateDidChange()
    }

    // MARK: TextKit 2 fragments

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                                  in textElement: NSTextElement) -> NSTextLayoutFragment {
        let f = FloLayoutFragment(textElement: textElement, range: textElement.elementRange)
        f.editor = self
        return f
    }
}

public final class FloTextView: NSTextView {
    weak var controller: EditorController?
    var bottomPadding: CGFloat = 0
    /// Height of window chrome (tabs, drag strip) overlapping the top of the editor, in window points.
    public var topChromeHeight: CGFloat = 0 { didSet { window?.invalidateCursorRects(for: self) } }

    private var chromeRect: NSRect {
        guard topChromeHeight > 0, let w = window, let cv = w.contentView else { return .zero }
        // window coordinates are bottom-up: the strip is the top of the content view's frame
        let f = cv.frame
        let r = NSRect(x: f.minX, y: f.maxY - topChromeHeight, width: f.width, height: topChromeHeight)
        return convert(r, from: nil).intersection(visibleRect)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let s = self { s.window?.invalidateCursorRects(for: s) } }
            }
        }
    }

    public override func resetCursorRects() {
        let chrome = chromeRect
        if chrome.isEmpty { super.resetCursorRects(); return }
        let vr = visibleRect
        let below = NSRect(x: vr.minX, y: chrome.maxY, width: vr.width, height: max(0, vr.maxY - chrome.maxY))
        addCursorRect(below, cursor: .iBeam)
        addCursorRect(chrome, cursor: .arrow)
    }

    public override func cursorUpdate(with event: NSEvent) {
        if chromeRect.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
        else if let c = controller, c.imageOverlay.handleContains(convert(event.locationInWindow, from: nil)) { ImageResizeOverlay.diagonalCursor.set() }
        else if let c = controller, c.features.pointerOverLink(event) { NSCursor.pointingHand.set() }
        else { super.cursorUpdate(with: event) }
    }

    /// Unshifted base characters by virtual key code (US layout), for CM's
    /// "Shift-<base>" fallback (Mod-Shift-8 arrives as "*").
    static let baseChars: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]

    /// Chord names in CM keymap lookup order ("Mod-Shift-x"): the key's own
    /// name first, then for shifted non-letters the Shift-<base> form.
    static func chords(_ e: NSEvent) -> [String] {
        var mods: [String] = []
        let f = e.modifierFlags
        if f.contains(.control) { mods.append("Ctrl") }
        if f.contains(.option) { mods.append("Alt") }
        if f.contains(.command) { mods.append("Mod") }
        let shift = f.contains(.shift)
        let named: [UInt16: String] = [36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "Escape",
                                       123: "Left", 124: "Right", 125: "Down", 126: "Up", 115: "Home", 119: "End",
                                       116: "PageUp", 121: "PageDown", 49: "Space"]
        if let n = named[e.keyCode] {
            if mods.isEmpty && !shift && n == "Space" { return [] }
            return [(mods + (shift ? ["Shift"] : []) + [n]).joined(separator: "-")]
        }
        // Alt changes the produced character on macOS; CM falls back to the base key.
        guard let raw = e.charactersIgnoringModifiers, !raw.isEmpty else { return [] }
        // Plain printable keys are text input, not chords.
        if mods.isEmpty { return [] }
        var out: [String] = []
        let isLetter = raw.count == 1 && raw.lowercased() != raw.uppercased()
        if isLetter {
            out.append((mods + (shift ? ["Shift"] : []) + [raw.lowercased()]).joined(separator: "-"))
        } else {
            out.append((mods + [raw]).joined(separator: "-"))
            if let base = baseChars[e.keyCode] {
                out.append((mods + (shift ? ["Shift"] : []) + [base]).joined(separator: "-"))
            }
        }
        return out
    }

    public override func keyDown(with event: NSEvent) {
        if let c = controller, !hasMarkedText(), Self.chords(event).contains(where: { c.handleKey($0) }) { return }
        super.keyDown(with: event)
    }

    /// Keymap bindings win over menu key equivalents (as CM's keydown handler
    /// runs before the web app's window-level shortcuts).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let c = controller, !hasMarkedText(),
           event.modifierFlags.contains(.command), Self.chords(event).contains(where: { c.handleKey($0) }) { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        if let c = controller, !hasMarkedText(), replacementRange.location == NSNotFound,
           let s = (string as? String) ?? (string as? NSAttributedString)?.string, c.insertTyped(s) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    // Links: mousedown on a link doesn't move the caret; navigation on click.
    private var linkDown: EditorController.LinkClick?

    /// The link under the mouse: the characters on either side of the nearest insertion point.
    private func linkUnder(_ event: NSEvent) -> EditorController.LinkClick? {
        guard let c = controller else { return nil }
        let i = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard i != NSNotFound else { return nil }
        return c.link(at: i) ?? (i > 0 ? c.link(at: i - 1) : nil)
    }

    /// The foldable heading whose chevron is under the point (view coordinates).
    func chevronLine(at p: NSPoint) -> Int? {
        guard let c = controller, c.applier.showFoldToggles, !c.foldSections.isEmpty else { return nil }
        let i = characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x + c.applier.gutter + 1, y: p.y))
        guard i != NSNotFound else { return nil }
        let line = c.state.doc.lineAt(i).number
        guard c.foldSections[line] != nil, let r = c.chevronRect(line: line) else { return nil }
        return r.insetBy(dx: -4, dy: -4).contains(p) ? line : nil
    }

    public override func mouseMoved(with event: NSEvent) {
        // on an image's resize handle: keep the resize cursor (super would reset the I-beam every move)
        if let c = controller, c.imageOverlay.handleContains(convert(event.locationInWindow, from: nil)) {
            ImageResizeOverlay.diagonalCursor.set()
            return
        }
        super.mouseMoved(with: event)
        if chromeRect.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set(); return }
        if let c = controller, c.features.pointerOverLink(event) { NSCursor.pointingHand.set() }
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let i = characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x + c.applier.gutter + 1, y: p.y))
        let line = i == NSNotFound ? nil : c.state.doc.lineAt(i).number
        c.hoverLine = line.flatMap { c.foldSections[$0] != nil ? $0 : nil }
        c.hoverChevron = chevronLine(at: p) != nil
        let img = c.image(at: p, slop: ImageResizeOverlay.handle)
        if img != c.imageOverlay.hit { c.imageOverlay.show(img) }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.hoverLine = nil
        controller?.hoverChevron = false
        controller?.imageOverlay.show(nil)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self && t.userInfo?["flo"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["flo": true]))
    }

    /// First click of a possible double-click on an image: the image and the
    /// selection before that click (the single click selects the image source).
    private var imageClick: (url: URL, selection: [NSValue])?

    public override func mouseDown(with event: NSEvent) {
        if let c = controller, event.clickCount == 1, !event.modifierFlags.contains(.shift),
           c.toggleCheckbox(at: convert(event.locationInWindow, from: nil)) { return }
        if let c = controller, let line = chevronLine(at: convert(event.locationInWindow, from: nil)) {
            c.toggleFold(line: line)
            return
        }
        // Double-click on a rendered image: open the file, and undo the first click's
        // source selection (the image may have moved under the revealed source line).
        if let c = controller, !event.modifierFlags.contains(.shift) {
            if event.clickCount == 2, let first = imageClick {
                imageClick = nil
                setSelectedRanges(first.selection, affinity: .downstream, stillSelecting: false)
                c.openImageFile(first.url)
                return
            }
            imageClick = event.clickCount == 1 ? c.imageFileURL(at: convert(event.locationInWindow, from: nil)).map { ($0, selectedRanges) } : nil
        }
        if let c = controller, event.clickCount == 1, !event.modifierFlags.contains(.shift),
           c.onLinkClick != nil, let link = linkUnder(event) {
            linkDown = link
            return
        }
        linkDown = nil
        if let c = controller, event.clickCount == 1, let href = c.htmlBlockLink(at: convert(event.locationInWindow, from: nil)) {
            c.onLinkClick?(.href(href))
            return
        }
        if let c = controller, !event.modifierFlags.contains(.shift),
           let r = c.blockWidgetRange(at: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
               ?? c.inlineWidgetRange(at: convert(event.locationInWindow, from: nil)) {
            // selectAllDecorationsOnSelectExtension: clicking a rendered block selects its source
            window?.makeFirstResponder(self)
            // (to, from) = a backwards selection (HTML blocks select head-first)
            setSelectedRanges([NSValue(range: NSRange(location: min(r.0, r.1), length: abs(r.1 - r.0)))],
                              affinity: r.0 > r.1 ? .upstream : .downstream, stillSelecting: false)
            return
        }
        super.mouseDown(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if let l = linkDown {
            linkDown = nil
            if let c = controller, linkUnder(event) == l { c.onLinkClick?(l) }
            return
        }
        super.mouseUp(with: event)
    }

    @objc func undo(_ sender: Any?) { _ = controller?.handleKey("Mod-z") }
    @objc func redo(_ sender: Any?) { _ = controller?.handleKey("Mod-Shift-z") }

    public override func paste(_ sender: Any?) {
        if let c = controller, c.features.paste(NSPasteboard.general, plain: false) { return }
        controller?.nativeUserEvent = "input.paste"
        super.paste(sender)
    }

    // MARK: editor features hooks (EditorFeatures.swift)

    public override func pasteAsPlainText(_ sender: Any?) {
        if let c = controller, c.features.paste(NSPasteboard.general, plain: true) { return }
        super.pasteAsPlainText(sender)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        controller?.features.drawHighlights(dirtyRect)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let base = controller?.features.contextMenu(for: event) ?? super.menu(for: event)
        guard let c = controller, let hit = c.image(at: convert(event.locationInWindow, from: nil)) else { return base }
        let menu = base ?? NSMenu()
        let items = c.imageSizeMenuItems(for: hit)
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for it in items.reversed() { menu.insertItem(it, at: 0) }
        return menu
    }

    /// NSTextView's own completion popup (Esc / F5) is replaced by the wiki autocomplete.
    public override func complete(_ sender: Any?) {}

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { controller?.features.editorDidBlur() }
        return ok
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return controller.map { $0.session.env.history.canUndo } ?? false }
        if item.action == #selector(redo(_:)) { return controller.map { $0.session.env.history.canRedo } ?? false }
        return super.validateUserInterfaceItem(item)
    }

    /// `padding-bottom: 40vh`: the document extends `bottomPadding` below the
    /// last line (so the end can scroll up), without making short documents
    /// scrollable. (Shell edit: replaces scroll-view contentInsets, which
    /// shrink NSTextView's visible rect and made scroll-to-caret jump.)
    public override func setFrameSize(_ newSize: NSSize) {
        var s = newSize
        if bottomPadding > 0, !inHeightLayout, let tlm = textLayoutManager {
            // never size from TextKit's estimates (see refreshDocumentHeight)
            inHeightLayout = true
            tlm.ensureLayout(for: tlm.documentRange)
            inHeightLayout = false
        }
        if bottomPadding > 0, let h = contentHeight() {
            // Whatever height AppKit asks for, the document is exactly
            // top inset + laid-out text + the 40vh padding (no bottom inset).
            s.height = max(minSize.height, h + bottomPadding)
        }
        super.setFrameSize(s)
    }

    /// Bottom of the laid-out text in view coordinates (never an estimate
    /// smaller than what is actually laid out).
    func contentHeight() -> CGFloat? {
        guard let tlm = textLayoutManager else { return nil }
        var lastMaxY: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation, options: [.reverse]) { f in
            lastMaxY = f.layoutFragmentFrame.maxY; return false
        }
        return textContainerOrigin.y + max(lastMaxY, tlm.usageBoundsForTextContainer.maxY)
    }

    public override func layout() {
        super.layout()
        refreshDocumentHeight()
    }

    /// Re-derive the frame height from the current layout (after edits).
    public static var layoutTime: [Double] = []
    private var inHeightLayout = false
    func refreshDocumentHeight() {
        guard bottomPadding > 0 else { return }
        // TextKit 2 re-estimates the height of text it hasn't (re)laid out after
        // an edit — here ~15% taller — which made the document height flip and
        // the view jump. Keep the whole document laid out (cheap: only
        // invalidated fragments are redone) so the height is always real.
        if let tlm = textLayoutManager {
            let t0 = CFAbsoluteTimeGetCurrent()
            tlm.ensureLayout(for: tlm.documentRange)
            FloTextView.layoutTime.append(CFAbsoluteTimeGetCurrent() - t0)
        }
        guard let h = contentHeight() else { return }
        let want = max(minSize.height, h + bottomPadding)
        if abs(frame.height - want) > 0.5 { super.setFrameSize(NSSize(width: frame.width, height: want)) }
    }
}

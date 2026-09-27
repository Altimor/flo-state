import AppKit
import FloCore

// Find/replace (editor-search-overlay.tsx, editor-search-store.ts,
// editor-search-overview.tsx, the search scroll handler in
// use-prosemark-editor.ts).

/// `EDITOR_SAFE_SCROLL_MARGIN`.
let editorSafeScrollMargin: CGFloat = 24

extension EditorFeatures {
    // MARK: store actions

    /// `openEditorSearch(view)` + the overlay's open effect.
    public func openFind() {
        let o = ensureFindOverlay()
        if let old = o.editor, old !== editor { old.features.searchPanelOpen = false; old.features.storeQuery = ""; old.textView.needsDisplay = true; old.features.updateOverview() }
        searchPanelOpen = true
        o.open(on: editor, host: findOverlayHost ?? editor.scrollView.superview)
    }

    /// `closeEditorSearch({restoreFocus})`.
    public func closeFind(restoreFocus: Bool = false) {
        guard let o = findOverlayIfCreated, o.editor === editor else { return }
        o.close(restoreFocus: restoreFocus)
    }

    /// `applyEditorSearchQuery`: set this view's CM query and the store mirror.
    func applySearchQuery(_ query: String, _ replace: String) {
        searchQuery = FindQuery(search: query, replace: replace)
        storeQuery = query
        editor.textView.needsDisplay = true
        updateOverview()
    }

    /// `searchCommand(f)`: run with a valid query, otherwise open the panel.
    private func searchCommand(_ f: (EditorState) -> TransactionSpec?) -> Bool {
        guard searchQuery.valid else {
            searchPanelOpen = true
            editor.textView.needsDisplay = true
            return true
        }
        guard let spec = f(editor.state) else { return false }
        applySearch(spec)
        return true
    }

    @discardableResult public func findNext() -> Bool { searchCommand(searchQuery.findNext) }
    @discardableResult public func findPrevious() -> Bool { searchCommand(searchQuery.findPrevious) }
    @discardableResult public func replaceNext() -> Bool { searchCommand(searchQuery.replaceNext) }
    @discardableResult public func replaceAll() -> Bool { searchCommand(searchQuery.replaceAll) }

    /// `jumpToMatch` (overview tick click).
    func jumpToMatch(_ m: SearchMatch) {
        applySearch(TransactionSpec(selection: .single(m.from, m.to), userEvent: "select.search"))
    }

    /// Dispatch a search transaction; search navigation scrolls into the safe band.
    func applySearch(_ spec: TransactionSpec) {
        let before = editor.state
        editor.session.env.time = Date().timeIntervalSince1970 * 1000
        editor.session.dispatch(spec)
        editor.sync(from: before, scroll: false)
        let ev = spec.userEvent ?? ""
        // replaceAll requests no scroll; the others use scrollToMatch.
        if ev == "select.search" || ev == "input.replace" {
            scrollIntoSafeBand(editor.state.selection.main.head)
        }
    }

    /// The search scrollHandler: move the match's line block into the band
    /// `EDITOR_SAFE_SCROLL_MARGIN` inside the scroller, only when outside it.
    func scrollIntoSafeBand(_ pos: Int) {
        guard let block = editor.lineBlockRect(pos) else { return }
        let clip = editor.scrollView.contentView
        let scrollTop = clip.bounds.minY
        let clientHeight = clip.bounds.height
        let matchTop = block.minY - scrollTop, matchBottom = block.maxY - scrollTop
        let safeTop = editorSafeScrollMargin, safeBottom = clientHeight - editorSafeScrollMargin
        var delta: CGFloat
        if matchTop < safeTop { delta = matchTop - safeTop }
        else if matchBottom > safeBottom && block.height <= safeBottom - safeTop { delta = matchBottom - safeBottom }
        else { return }
        // TextKit 2 grows the text view lazily as layout advances
        if editor.textView.frame.height < block.maxY { editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport() }
        let maxTop = max(0, editor.textView.frame.height - clientHeight)
        let next = max(0, min(scrollTop + delta, maxTop))
        if abs(scrollTop - next) < 1 { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: next))
        editor.scrollView.reflectScrolledClipView(clip)
    }

    // MARK: highlights (searchHighlighter)

    /// cm-searchMatch / cm-searchMatch-selected (CM light theme: the app never sets `dark`).
    static let matchColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 0x54 / 255.0)
    static let selectedMatchColor = NSColor(srgbRed: 1, green: 0x6a / 255.0, blue: 0, alpha: 0x54 / 255.0)

    /// Matches the highlighter shows in the visible range, with their "selected" flag.
    public func visibleHighlights() -> [(SearchMatch, Bool)] {
        guard searchPanelOpen, searchQuery.valid else { return [] }
        let st = editor.state
        let (from, to) = editor.visibleCharacterRange()
        return searchQuery.highlight(st.doc, from, to).map { m in
            (m, st.selection.ranges.contains { $0.from == m.from && $0.to == m.to })
        }
    }

    func drawHighlights(_ dirty: NSRect) {
        let hs = visibleHighlights()
        guard !hs.isEmpty else { return }
        for (m, sel) in hs {
            (sel ? Self.selectedMatchColor : Self.matchColor).setFill()
            for r in editor.segmentRects(m.from, m.to) where r.intersects(dirty) { r.fill(using: .sourceOver) }
        }
    }

    // MARK: overview (editor-search-overview.tsx)

    func updateOverview() {
        let show = isFindOpen && !storeQuery.isEmpty
        guard show, let host = editor.scrollView.superview else { overview?.isHidden = true; return }
        let v: FindOverviewView
        if let o = overview { v = o } else {
            v = FindOverviewView(); v.features = self; overview = v
            v.autoresizingMask = [.minXMargin, .height]
        }
        if v.superview !== host { host.addSubview(v, positioned: .above, relativeTo: editor.scrollView) }
        let f = editor.scrollView.frame
        // absolute right-1 top-0 bottom-0 w-[6px]
        v.frame = NSRect(x: f.maxX - 4 - 6, y: f.minY, width: 6, height: f.height)
        v.matches = FindCount.collect(editor.state, storeQuery)
        v.isHidden = v.matches == nil || v.matches!.ranges.isEmpty
        v.needsDisplay = true
    }
}

extension EditorController {
    /// Top/bottom of the line block (logical line) holding `pos`, in text view coordinates.
    func lineBlockRect(_ pos: Int) -> NSRect? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let p = max(0, min(pos, state.doc.length))
        guard let loc = tcm.location(tcm.documentRange.location, offsetBy: p) else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: tcm.documentRange.location, end: loc) ?? tlm.documentRange)
        guard let frag = tlm.textLayoutFragment(for: loc) else { return nil }
        var r = frag.layoutFragmentFrame
        r.origin.x += textView.textContainerOrigin.x
        r.origin.y += textView.textContainerOrigin.y
        return r
    }

    /// Character range intersecting the scroll view's visible rect.
    func visibleCharacterRange() -> (Int, Int) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return (0, state.doc.length) }
        let vis = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        var lo = Int.max, hi = 0
        tlm.enumerateTextLayoutFragments(from: tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, vis.minY)))?.rangeInElement.location ?? tcm.documentRange.location,
                                         options: [.ensuresLayout]) { f in
            if f.layoutFragmentFrame.minY > vis.maxY { return false }
            let a = tcm.offset(from: tcm.documentRange.location, to: f.rangeInElement.location)
            let b = tcm.offset(from: tcm.documentRange.location, to: f.rangeInElement.endLocation)
            lo = min(lo, a); hi = max(hi, b)
            return true
        }
        if lo == Int.max { return (0, 0) }
        return (lo, min(hi, state.doc.length))
    }

    /// Text segment rects for `from..<to` in text view coordinates.
    func segmentRects(_ from: Int, _ to: Int) -> [NSRect] {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let a = tcm.location(tcm.documentRange.location, offsetBy: from),
              let b = tcm.location(tcm.documentRange.location, offsetBy: to),
              let range = NSTextRange(location: a, end: b) else { return [] }
        var out: [NSRect] = []
        let o = textView.textContainerOrigin
        tlm.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, r, _, _ in
            if r.width > 0 { out.append(r.offsetBy(dx: o.x, dy: o.y)) }
            return true
        }
        return out
    }
}

/// Match ticks over the scrollbar track.
public final class FindOverviewView: NSView {
    weak var features: EditorFeatures?
    var matches: (ranges: [SearchMatch], activeIndex: Int, docLength: Int)?
    public override var isFlipped: Bool { true }

    /// (index, topPx, active) after per-pixel coalescing.
    var marks: [(Int, CGFloat, Bool)] {
        guard let m = matches, !m.ranges.isEmpty else { return [] }
        let track = bounds.height
        if track == 0 { return [] }
        var seen = Set<Int>()
        var out: [(Int, CGFloat, Bool)] = []
        for (i, r) in m.ranges.enumerated() {
            let top = (Double(r.from) / Double(m.docLength) * Double(track)).rounded(.toNearestOrAwayFromZero)
            let active = i == m.activeIndex
            if !active && seen.contains(Int(top)) { continue }
            seen.insert(Int(top))
            out.append((i, CGFloat(top), active))
        }
        return out
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let f = features else { return }
        let accent = f.chrome.tokens.accent.nsColor
        for (_, top, active) in marks {
            let h: CGFloat = active ? 4 : 2
            let r = NSRect(x: 0, y: top - h / 2, width: bounds.width, height: h)
            (active ? accent : accent.withAlphaComponent(accent.alphaComponent * 0.45)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return markIndex(at: p) != nil ? self : nil
    }

    func markIndex(at p: NSPoint) -> Int? {
        // later marks paint on top: search from the end
        for (i, top, active) in marks.reversed() {
            let h: CGFloat = active ? 4 : 2
            if p.x >= 0 && p.x <= bounds.width && p.y >= top - h / 2 && p.y <= top + h / 2 { return i }
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        guard let i = markIndex(at: convert(event.locationInWindow, from: nil)), let m = matches else { return }
        features?.jumpToMatch(m.ranges[i])
    }

    public override func resetCursorRects() {
        for (_, top, active) in marks {
            let h: CGFloat = active ? 4 : 2
            addCursorRect(NSRect(x: 0, y: top - h / 2, width: bounds.width, height: h), cursor: .pointingHand)
        }
    }
}

// MARK: - the card

final class FindField: NSTextField {
    weak var overlay: FindOverlayView?
    override func becomeFirstResponder() -> Bool { super.becomeFirstResponder() }
}

/// The find/replace card (`EditorSearchOverlay`). One per editor area; its
/// query/replace/row state persists across close/open like the React state.
public final class FindOverlayView: NSView, NSTextFieldDelegate {
    public private(set) weak var editor: EditorController?
    public private(set) var isOpen = false
    public private(set) var query = ""
    public private(set) var replaceText = ""
    public private(set) var showReplace = false

    let findField = FindField()
    let replaceField = FindField()
    private var hover: String?
    private var pressed: String?

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 50))
        for f in [findField, replaceField] {
            f.overlay = self
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.isBezeled = false
            f.usesSingleLineMode = true
            f.cell?.isScrollable = true
            f.cell?.wraps = false
            f.lineBreakMode = .byClipping
            f.delegate = self
            addSubview(f)
        }
        replaceField.isHidden = true
        wantsLayer = true
        // the blur is clipped to the card (masksToBounds); the shadow lives in a sibling below it
        layer?.masksToBounds = true
        layer?.cornerRadius = 16
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    var chrome: EditorChrome { editor?.features.chrome ?? .standard }
    var tokens: ThemeTokens { chrome.tokens }

    // MARK: geometry (px, from the web layout)

    static let pad: CGFloat = 8, border: CGFloat = 1, control: CGFloat = 32, gap: CGFloat = 6
    static let toggleWidth: CGFloat = 58.98, replaceButtonWidth: CGFloat = 65.08, allWidth: CGFloat = 34.73

    struct Layout {
        var findInput = NSRect.zero, prev = NSRect.zero, next = NSRect.zero, toggle = NSRect.zero, close = NSRect.zero
        var replaceInput = NSRect.zero, replaceButton = NSRect.zero, all = NSRect.zero
    }

    func computeLayout() -> Layout {
        let inner = Self.border + Self.pad
        let w = bounds.width
        var l = Layout()
        var x = w - inner
        x -= Self.control; l.close = NSRect(x: x, y: inner, width: Self.control, height: Self.control)
        x -= Self.gap + measuredToggleWidth; l.toggle = NSRect(x: x, y: inner, width: measuredToggleWidth, height: Self.control)
        x -= Self.gap + Self.control; l.next = NSRect(x: x, y: inner, width: Self.control, height: Self.control)
        x -= Self.gap + Self.control; l.prev = NSRect(x: x, y: inner, width: Self.control, height: Self.control)
        x -= Self.gap
        l.findInput = NSRect(x: inner, y: inner, width: max(0, x - inner), height: Self.control)
        let y2 = inner + Self.control + Self.gap
        var x2 = w - inner
        x2 -= measuredAllWidth; l.all = NSRect(x: x2, y: y2, width: measuredAllWidth, height: Self.control)
        x2 -= Self.gap + measuredReplaceWidth; l.replaceButton = NSRect(x: x2, y: y2, width: measuredReplaceWidth, height: Self.control)
        x2 -= Self.gap
        l.replaceInput = NSRect(x: inner + 28, y: y2, width: max(0, x2 - inner - 28), height: Self.control)
        return l
    }

    private func textWidth(_ s: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
        var a: [NSAttributedString.Key: Any] = [.font: font]
        if kern != 0 { a[.kern] = kern }
        return ceil((s as NSString).size(withAttributes: a).width * 100) / 100
    }
    var measuredToggleWidth: CGFloat { textWidth(L("Replace"), chrome.uiFont(12, .regular), kern: -0.3) + 16 }
    var measuredReplaceWidth: CGFloat { textWidth(L("Replace"), chrome.uiFont(12, .regular)) + 20 }
    var measuredAllWidth: CGFloat { textWidth(L("All"), chrome.uiFont(12, .medium)) + 20 }

    /// `bottom-2 right-3 w-[min(560px, 100% - 1.5rem)]`.
    func place(in host: NSView) {
        let w = min(560, host.bounds.width - 24)
        let h: CGFloat = showReplace ? 88 : 50
        let y = host.isFlipped ? host.bounds.height - 8 - h : 8
        frame = NSRect(x: host.bounds.width - 12 - w, y: y, width: max(0, w), height: h)
        autoresizingMask = host.isFlipped ? [.minXMargin, .minYMargin] : [.minXMargin, .maxYMargin]
        layoutFields()
    }

    func layoutFields() {
        let l = computeLayout()
        let font = chrome.uiFont(13, .regular)
        let lh = ceil(font.ascender - font.descender + font.leading)
        func inset(_ r: NSRect, left: CGFloat, right: CGFloat) -> NSRect {
            NSRect(x: r.minX + left, y: r.minY + (r.height - lh) / 2, width: max(0, r.width - left - right), height: lh)
        }
        // NSTextField's cell insets its text by 2px: compensate so text starts at the CSS padding
        findField.frame = inset(l.findInput, left: 34 - 2, right: 64 - 2)
        replaceField.frame = inset(l.replaceInput, left: 8 - 2, right: 8 - 2)
        replaceField.isHidden = !showReplace
    }

    func restyle() {
        let font = chrome.uiFont(13, .regular)
        for (f, ph) in [(findField, L("Find")), (replaceField, L("Replace"))] {
            f.font = font
            f.textColor = tokens.textPrimary.nsColor
            f.placeholderAttributedString = NSAttributedString(string: ph, attributes: [.font: font, .foregroundColor: tokens.textMuted.nsColor])
        }
        if let host = superview { place(in: host) }
        needsDisplay = true
    }

    // MARK: open / close

    func open(on c: EditorController, host: NSView?) {
        editor = c
        isOpen = true
        if let host = host {
            if superview !== host { removeFromSuperview(); host.addSubview(self) }
            else { host.addSubview(self, positioned: .above, relativeTo: nil) }
        }
        applyBackdropBlur()
        restyle()
        isHidden = false
        shadowView.attach(below: self)
        // pre-fill from a single-line selection
        let sel = c.state.selection.main
        var next = query
        if sel.from != sel.to {
            let t = c.state.sliceDoc(sel.from, sel.to)
            if !t.contains("\n") { next = t; query = t }
        }
        findField.stringValue = query
        replaceField.stringValue = replaceText
        c.features.applySearchQuery(next, replaceText)
        refreshCounter()
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    func close(restoreFocus: Bool) {
        guard let c = editor else { return }
        c.features.searchPanelOpen = false
        c.features.storeQuery = ""
        c.textView.needsDisplay = true
        isOpen = false
        editor = nil
        c.features.updateOverview()
        let fr = (window?.firstResponder as? NSTextView)?.delegate
        let hadFocus = fr === findField || fr === replaceField
        isHidden = true
        if restoreFocus { c.textView.window?.makeFirstResponder(c.textView) } else if hadFocus { window?.makeFirstResponder(nil) }
    }

    func applyBackdropBlur() {
        applyCardBackdrop(self, cornerRadius: 16)
    }

    /// `box-shadow: 0 15px 35px rgba(0,0,0,.15)`, drawn by a sibling so the card can clip its blur.
    let shadowView = CardShadowView(opacity: 0.15, blur: 35, offsetY: 15, cornerRadius: 16)
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        shadowView.attach(below: self)
    }
    public override func setFrameOrigin(_ p: NSPoint) { super.setFrameOrigin(p); shadowView.follow(self) }
    public override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); shadowView.follow(self) }
    public override var isHidden: Bool { didSet { shadowView.isHidden = isHidden } }
    public override func removeFromSuperview() { shadowView.removeFromSuperview(); super.removeFromSuperview() }

    // MARK: counter

    var matchInfo: FindCount.Info? {
        guard isOpen, let c = editor else { return nil }
        return FindCount.matchInfo(c.state, query)
    }
    /// The counter text, nil when hidden.
    public var counterText: String? {
        guard let m = matchInfo, !query.isEmpty else { return nil }
        return m.total == 0 ? L("No matches") : "\(m.current)/\(m.total)"
    }
    private var cachedCounter: String?
    func refreshCounter() {
        let t = counterText
        if t != cachedCounter { cachedCounter = t; needsDisplay = true }
    }

    // MARK: actions

    public func next() { if let c = editor, !query.isEmpty { c.features.findNext() } }
    public func prev() { if let c = editor, !query.isEmpty { c.features.findPrevious() } }
    public func doReplace() { if let c = editor, !query.isEmpty { c.features.replaceNext() } }
    public func doReplaceAll() { if let c = editor, !query.isEmpty { c.features.replaceAll() } }
    public func doClose() { close(restoreFocus: true) }

    public func toggleReplace() {
        showReplace.toggle()
        if let host = superview { place(in: host) }
        needsDisplay = true
    }

    /// Typing in the find input (`onQueryChange`).
    public func setQuery(_ q: String) {
        query = q
        if findField.stringValue != q { findField.stringValue = q }
        editor?.features.applySearchQuery(q, replaceText)
        refreshCounter()
    }

    public func setReplaceText(_ r: String) {
        replaceText = r
        if replaceField.stringValue != r { replaceField.stringValue = r }
        if let c = editor { c.features.applySearchQuery(query, r) }
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === findField { setQuery(f.stringValue) } else if f === replaceField { setReplaceText(f.stringValue) }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)):
            doClose(); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            if control === findField { if shift { prev() } else { next() } } else { doReplace() }
            return true
        default:
            return false
        }
    }

    /// Cmd-G / Cmd-Shift-G inside either input.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isOpen, let fr = window?.firstResponder as? NSTextView,
              fr.delegate === findField || fr.delegate === replaceField else { return super.performKeyEquivalent(with: event) }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (f.contains(.command) || f.contains(.control)), event.charactersIgnoringModifiers?.lowercased() == "g" {
            if f.contains(.shift) { prev() } else { next() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Key handling entry for tests: "Enter", "Shift-Enter", "Escape", "Mod-g", "Mod-Shift-g" in `field`.
    public func key(_ chord: String, inReplace: Bool = false) {
        switch Keymap.normalize(chord) {
        case "Escape": doClose()
        case "Enter": if inReplace { doReplace() } else { next() }
        case "Shift-Enter": if inReplace { doReplace() } else { prev() }
        case "Mod-g", "Ctrl-g": next()
        case "Mod-Shift-g", "Ctrl-Shift-g": prev()
        default: break
        }
    }

    // MARK: mouse

    private func button(at p: NSPoint) -> String? {
        let l = computeLayout()
        let list: [(String, NSRect)] = [("prev", l.prev), ("next", l.next), ("toggle", l.toggle), ("close", l.close)]
            + (showReplace ? [("replace", l.replaceButton), ("all", l.all)] : [])
        return list.first { $0.1.contains(p) }?.0
    }

    public override func mouseMoved(with event: NSEvent) {
        let h = button(at: convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
    }
    public override func mouseExited(with event: NSEvent) { if hover != nil { hover = nil; needsDisplay = true } }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let l = computeLayout()
        if l.findInput.contains(p) { window?.makeFirstResponder(findField); return }
        if showReplace && l.replaceInput.contains(p) { window?.makeFirstResponder(replaceField); return }
        guard let b = button(at: p) else { return }
        switch b {
        case "prev": prev()
        case "next": next()
        case "toggle": toggleReplace()
        case "close": doClose()
        case "replace": doReplace()
        case "all": doReplaceAll()
        default: break
        }
    }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        let t = tokens
        let b = bounds
        let card = NSBezierPath(roundedRect: b, xRadius: 16, yRadius: 16)
        t.surfaceCard.nsColor.setFill(); card.fill()
        t.bgBase.mixedWithTransparent(0.55).nsColor.setFill(); card.fill()
        let border = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 15.5, yRadius: 15.5)
        border.lineWidth = 1
        t.lineSubtler.nsColor.setStroke(); border.stroke()

        let l = computeLayout()
        let input = t.surfaceInput.nsColor
        input.setFill()
        NSBezierPath(roundedRect: l.findInput, xRadius: 8, yRadius: 8).fill()
        // search icon: left-2.5, 16px, fg-base @ 0.54
        let iconColor = t.fgBase.mixedWithTransparent(0.54).nsColor
        FindIcons.search.draw(in: NSRect(x: l.findInput.minX + 10, y: l.findInput.midY - 8, width: 16, height: 16), color: iconColor, strokeWidth: 2)
        if let ct = cachedCounter ?? counterText {
            let f = chrome.uiFont(12, .regular)
            let font = NSFont(descriptor: f.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]]), size: 12) ?? f
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: t.textMuted.nsColor]
            let s = (ct as NSString).size(withAttributes: a)
            (ct as NSString).draw(at: NSPoint(x: l.findInput.maxX - 10 - s.width, y: l.findInput.midY - s.height / 2), withAttributes: a)
        }
        func iconButton(_ id: String, _ r: NSRect, _ icon: FindIcons.Icon) {
            let hot = hover == id
            if hot { t.surfaceSubtle.nsColor.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            let c = hot ? t.textSecondary.nsColor : t.textMuted.nsColor
            icon.draw(in: NSRect(x: r.midX - 7, y: r.midY - 7, width: 14, height: 14), color: c, strokeWidth: 2)
        }
        iconButton("prev", l.prev, FindIcons.arrowUp)
        iconButton("next", l.next, FindIcons.arrowDown)
        // Replace toggle
        do {
            let r = l.toggle
            var color = t.textMuted.nsColor
            if showReplace {
                t.surfaceSelected.nsColor.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                color = t.textPrimary.nsColor
            } else if hover == "toggle" {
                t.surfaceSubtle.nsColor.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                color = t.textSecondary.nsColor
            }
            drawLabel(L("Replace"), in: r, font: chrome.uiFont(12, .regular), color: color, kern: -0.3)
        }
        iconButton("close", l.close, FindIcons.cancel)
        if showReplace {
            input.setFill()
            NSBezierPath(roundedRect: l.replaceInput, xRadius: 8, yRadius: 8).fill()
            let hot = hover == "replace"
            if hot { t.surfaceSubtle.nsColor.setFill(); NSBezierPath(roundedRect: l.replaceButton, xRadius: 6, yRadius: 6).fill() }
            drawLabel(L("Replace"), in: l.replaceButton, font: chrome.uiFont(12, .regular), color: hot ? t.textPrimary.nsColor : t.textSecondary.nsColor)
            let allColor = hover == "all" ? t.accent.mixedWithTransparent(0.9).nsColor : t.accent.nsColor
            allColor.setFill(); NSBezierPath(roundedRect: l.all, xRadius: 6, yRadius: 6).fill()
            drawLabel(L("All"), in: l.all, font: chrome.uiFont(12, .medium), color: .white)
        }
    }

    private func drawLabel(_ s: String, in r: NSRect, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { a[.kern] = kern }
        let size = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: a)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// Hugeicons (stroke 2, 24px viewBox) used by the card.
enum FindIcons {
    struct Icon {
        let build: (CGMutablePath) -> Void
        func draw(in rect: NSRect, color: NSColor, strokeWidth: CGFloat) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let p = CGMutablePath()
            build(p)
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: rect.width / 24, y: rect.height / 24)
            ctx.addPath(p)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(strokeWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
    static let search = Icon { p in
        p.move(to: CGPoint(x: 17, y: 17)); p.addLine(to: CGPoint(x: 21, y: 21))
        p.addEllipse(in: CGRect(x: 3, y: 3, width: 16, height: 16))
    }
    static let arrowUp = Icon { p in
        p.move(to: CGPoint(x: 17.9998, y: 15))
        p.addCurve(to: CGPoint(x: 11.9998, y: 9), control1: CGPoint(x: 17.9998, y: 15), control2: CGPoint(x: 13.5809, y: 9.00001))
        p.addCurve(to: CGPoint(x: 5.99985, y: 15), control1: CGPoint(x: 10.4187, y: 8.99999), control2: CGPoint(x: 5.99985, y: 15))
    }
    static let arrowDown = Icon { p in
        p.move(to: CGPoint(x: 18, y: 9.00005))
        p.addCurve(to: CGPoint(x: 12, y: 15), control1: CGPoint(x: 18, y: 9.00005), control2: CGPoint(x: 13.5811, y: 15))
        p.addCurve(to: CGPoint(x: 6, y: 9), control1: CGPoint(x: 10.4188, y: 15), control2: CGPoint(x: 6, y: 9))
    }
    static let cancel = Icon { p in
        p.move(to: CGPoint(x: 18, y: 6)); p.addLine(to: CGPoint(x: 6.00081, y: 17.9992))
        p.move(to: CGPoint(x: 17.9992, y: 18)); p.addLine(to: CGPoint(x: 6, y: 6.00085))
    }
}

/// CSS `backdrop-filter: blur(16px)` limited to the view's rounded rect: the
/// Gaussian blur's output extent grows past its input, so without clipping it
/// spreads over everything behind the view.
@MainActor func applyCardBackdrop(_ v: NSView, cornerRadius: CGFloat) {
    v.wantsLayer = true
    v.layerUsesCoreImageFilters = true
    v.layer?.masksToBounds = true
    v.layer?.cornerRadius = cornerRadius
    if v.layer?.backgroundFilters?.isEmpty ?? true, let f = CIFilter(name: "CIGaussianBlur") {
        f.setDefaults()
        f.setValue(8, forKey: kCIInputRadiusKey)
        v.layer?.backgroundFilters = [f]
    }
}

/// A card's drop shadow, as a sibling view directly below the card.
final class CardShadowView: NSView {
    init(opacity: Float, blur: CGFloat, offsetY: CGFloat, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = opacity
        layer?.shadowRadius = blur / 2
        layer?.shadowOffset = CGSize(width: 0, height: -offsetY)
    }
    required init?(coder: NSCoder) { fatalError() }
    let cornerRadius: CGFloat
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
    func attach(below card: NSView) {
        guard let host = card.superview else { removeFromSuperview(); return }
        if superview !== host || host.subviews.firstIndex(of: self).map({ $0 + 1 }) != host.subviews.firstIndex(of: card) {
            removeFromSuperview()
            host.addSubview(self, positioned: .below, relativeTo: card)
        }
        follow(card)
    }
    func follow(_ card: NSView) {
        frame = card.frame
        autoresizingMask = card.autoresizingMask
        isHidden = card.isHidden
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
}

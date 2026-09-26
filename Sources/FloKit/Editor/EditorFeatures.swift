import AppKit
import FloCore

/// Chrome styling for editor-level overlays (find card, completion popup):
/// the app's theme tokens and `--ui-font`.
public struct EditorChrome {
    public var tokens: ThemeTokens
    public var uiFont: (CGFloat, NSFont.Weight) -> NSFont
    public init(tokens: ThemeTokens, uiFont: @escaping (CGFloat, NSFont.Weight) -> NSFont = { NSFont.systemFont(ofSize: $0, weight: $1) }) {
        self.tokens = tokens
        self.uiFont = uiFont
    }
    public static var standard: EditorChrome { EditorChrome(tokens: ThemeTokens(settings: SettingsValues([:]), mode: .light)) }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Editor-level UI features layered on an EditorController: find/replace,
/// wiki-link autocomplete, context menu, paste. Kept out of the controller
/// itself; the controller calls in through a handful of hooks.
public final class EditorFeatures {
    unowned let editor: EditorController
    public var chrome = EditorChrome.standard {
        didSet { findOverlayIfCreated?.restyle(); completion.popup?.needsDisplay = true; overview?.needsDisplay = true }
    }

    let completion: WikiCompletionState

    init(editor: EditorController) {
        self.editor = editor
        completion = WikiCompletionState()
        editor.session.env.onTransaction = { [weak self] tr in self?.observe(tr) }
        // tooltips follow the text when the editor scrolls
        editor.scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.completion.open != nil { self?.renderPopup() } }
        }
    }
    private var scrollObserver: NSObjectProtocol?
    deinit { if let o = scrollObserver { NotificationCenter.default.removeObserver(o) } }

    /// The document was swapped/reloaded (`writer.swap` / `writer.reload`).
    func documentReplaced() {
        pendingTransactions.removeAll()
        if completion.open != nil || !completion.active.isInactive { closeCompletion() }
        if searchPanelOpen { editor.textView.needsDisplay = true }
        if isFindOpen { findOverlayIfCreated?.refreshCounter(); updateOverview() }
    }

    /// Frontmatter paste hook: the clipboard's frontmatter; return true when the
    /// file had none and the app set it (then only the body is inserted).
    public var frontmatterPaste: ((String) -> Bool)?
    /// Wiki-link completion source (`tauri.fuzzySearch(query, 20)`).
    public var wikiCompletions: ((String, Int) -> [SearchResult])?
    let menuTarget = MenuTarget()

    // MARK: find state (CM searchState of this view)

    /// The CM search query of this view (`setSearchQuery`).
    public internal(set) var searchQuery = FindQuery(search: "")
    /// CM `searchState.panel`: gates the match highlighter.
    public internal(set) var searchPanelOpen = false
    /// Mirror of the overlay's query for the overview (`useEditorSearchStore.query`).
    var storeQuery = ""

    /// Where the find card goes (the editor area). Defaults to the scroll view's superview.
    public weak var findOverlayHost: NSView?
    /// A shared find card (one per editor area); created on demand when nil.
    public var findOverlay: FindOverlayView? {
        get { findOverlayIfCreated }
        set { findOverlayIfCreated = newValue }
    }
    var findOverlayIfCreated: FindOverlayView?
    var overview: FindOverviewView?

    func ensureFindOverlay() -> FindOverlayView {
        if let o = findOverlayIfCreated { return o }
        let o = FindOverlayView()
        findOverlayIfCreated = o
        return o
    }

    /// True when the (shared) overlay is open on this editor.
    public var isFindOpen: Bool { findOverlayIfCreated?.isOpen == true && findOverlayIfCreated?.editor === editor }

    // MARK: transaction observation

    var pendingTransactions: [Transaction] = []
    var bufferTransactions = false

    func observe(_ tr: Transaction) {
        pendingTransactions.append(tr)
    }

    /// Called by the controller after every state change reached the text view.
    func stateDidChange() {
        let trs = pendingTransactions
        pendingTransactions.removeAll()
        if !bufferTransactions { completionTransactions(trs) }
        if searchPanelOpen { editor.textView.needsDisplay = true }
        if isFindOpen { findOverlayIfCreated?.refreshCounter(); updateOverview() }
    }

    // MARK: key routing

    /// Prec.highest bindings (completion keymap, Mod-f / Mod-g). True if handled.
    func handleKeyFirst(_ chord: String) -> Bool {
        let k = Keymap.normalize(chord)
        if completionHandleKey(k) { return true }
        switch k {
        case "Mod-f":
            openFind(); return true
        case "Mod-g":
            if !isFindOpen { openFind(); return true }
            return findNext()
        case "Mod-Shift-g":
            if !isFindOpen { openFind(); return true }
            return findPrevious()
        default:
            return false
        }
    }

    /// Bindings below the default keymap (searchKeymap's Escape).
    func handleKeyLast(_ chord: String) -> Bool {
        if Keymap.normalize(chord) == "Escape" {
            // closeSearchPanel: hides highlights; the React overlay stays up.
            if searchPanelOpen { searchPanelOpen = false; editor.textView.needsDisplay = true; return true }
        }
        return false
    }
}

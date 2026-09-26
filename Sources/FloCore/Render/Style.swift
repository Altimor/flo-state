import Foundation

/// Color roles resolved against the theme by the view layer. Mirrors the CSS
/// variables the web app styles with, so parity tests can compare roles.
public enum ColorRole: Hashable {
    case text            // --text-secondary (fg 80%)
    case primary         // --text-primary (fg 100%)
    case muted           // --text-muted (fg 54%)
    case link            // --link-color (accent)
    case heading1        // theme heading-color
    case subheading      // editor.subheading-color (H2/H3)
    case transparent
    case syntax(String)  // code-block token colours by name (keyword, string, ...)
    case invalid
    /// Inherit the enclosing colour (escape marks).
    case inherit
}

public enum HiddenKind: Hashable {
    /// Not rendered at all and takes no space (CodeMirror Decoration.replace).
    case removed
    /// Rendered with font-size 0 (`.cm-hidden-token`).
    case zeroSize
    /// Invisible but keeps its advance (`.cm-transparent-token`, list prefixes).
    case transparent
    /// Heading hash: absolutely positioned in the left margin; `visible`
    /// tells whether it is shown (caret on the line).
    case margin(visible: Bool)
}

/// Fully resolved inline style for a run of characters.
public struct CharStyle: Hashable {
    public var mono = false
    /// Font size relative to the editor base size (1.6 for H1 etc.).
    public var sizeEm: Double = 1
    public var weight = 400
    public var italic = false
    public var underline = false
    public var strike = false
    public var color: ColorRole = .text
    public var codeBackground = false
    public var hidden: HiddenKind? = nil
    /// Extra left padding in ch units (ordered list markers: 1ch).
    public var paddingLeftCh: Double = 0
    public var clickableLink = false
    public var opacity: Double = 1

    public init() {}
}

public enum LineKind: Hashable {
    case paragraph
    case blank
    case heading(level: Int)
    case setextUnderline
    case listItem(depth: Int, task: TaskState?)
    case orderedItem
    case fencedCode(first: Bool, last: Bool)
    case tableSource(first: Bool, last: Bool)
    case frontmatter
}

public enum TaskState: Hashable { case unchecked, checked }

public struct LineStyle: Hashable {
    public var kind: LineKind = .paragraph
    /// Hanging indent for list lines: first line pulled back by this, wraps aligned.
    public var paddingLeftCh: Double = 0
    public var textIndentCh: Double = 0
    public var blockquoteDepth = 0
    public var isListLine: Bool {
        if case .listItem = kind { return true }
        if case .orderedItem = kind { return true }
        return false
    }
    public init() {}
}

public enum WidgetKind: Hashable {
    case bullet(depth: Int)
    case checkbox(depth: Int, checked: Bool)
    case emoji(String)
    case dash(String)
    case horizontalRule
    case wikiLink(display: String, resolvedImage: Bool)
    case image(src: String, alt: String, width: Int?, block: Bool)
    case math(source: String, display: Bool)
    case table(source: String)
    case htmlBlock(source: String)
    case mermaid(source: String)
    case tab
}

public struct Widget: Hashable {
    public var from: Int
    public var to: Int
    public var kind: WidgetKind
    /// Replace widgets hide [from, to) and draw instead; decoration widgets
    /// (bullets, checkboxes) draw over existing (transparent) text.
    public var replaces: Bool
    public var block: Bool
}

public struct StyleRun: Hashable {
    public var from: Int
    public var to: Int
    public var style: CharStyle
}

/// Everything the view layer needs to render a document at a given selection.
public struct RenderPlan {
    public var runs: [StyleRun]          // covering [0, doc.length), sorted
    public var lines: [LineStyle]        // one per document line
    public var widgets: [Widget] { didSet { index() } }
    public var lineNumbersWithRevealedHash: Set<Int>
    /// widgets sorted by `from`, and the longest widget span (for range queries)
    private var sorted: [Widget] = []
    private var maxSpan = 0

    public init(runs: [StyleRun], lines: [LineStyle], widgets: [Widget], lineNumbersWithRevealedHash: Set<Int>) {
        self.runs = runs; self.lines = lines; self.widgets = widgets
        self.lineNumbersWithRevealedHash = lineNumbersWithRevealedHash
        index()
    }

    private mutating func index() {
        sorted = widgets.sorted { $0.from < $1.from }
        maxSpan = widgets.map { $0.to - $0.from }.max() ?? 0
    }

    /// Widgets with from <= to' && to >= from' (touching counts), in `from` order.
    public func widgetsOverlapping(_ from: Int, _ to: Int) -> [Widget] {
        var lo = 0, hi = sorted.count
        while lo < hi { let m = (lo + hi) / 2; if sorted[m].from < from - maxSpan { lo = m + 1 } else { hi = m } }
        var out: [Widget] = []
        var i = lo
        while i < sorted.count, sorted[i].from <= to {
            if sorted[i].to >= from { out.append(sorted[i]) }
            i += 1
        }
        return out
    }

    public func style(at pos: Int) -> CharStyle {
        var lo = 0, hi = runs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = runs[mid]
            if pos < r.from { hi = mid - 1 } else if pos >= r.to { lo = mid + 1 } else { return r.style }
        }
        return CharStyle()
    }
}

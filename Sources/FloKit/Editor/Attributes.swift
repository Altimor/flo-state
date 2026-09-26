import AppKit
import FloCore

extension NSAttributedString.Key {
    /// LineStyle for the paragraph (set on every char of the line).
    static let floLine = NSAttributedString.Key("flo.line")
    /// Widget to draw at this char (first char of the widget range).
    static let floWidget = NSAttributedString.Key("flo.widget")
    /// Char belongs to an inline code span (rounded background).
    static let floInlineCode = NSAttributedString.Key("flo.inlineCode")
    /// Heading hash hanging in the margin: value = (text, visible).
    static let floHeadingHash = NSAttributedString.Key("flo.headingHash")
    /// Opacity multiplier for the char (headerMark 0.4).
    static let floOpacity = NSAttributedString.Key("flo.opacity")
    /// Points to raise the line's glyphs when drawing (CSS baseline vs TextKit's).
    static let floGlyphShift = NSAttributedString.Key("flo.glyphShift")
    /// On a foldable heading line: NSNumber(bool) = currently folded.
    static let floFoldToggle = NSAttributedString.Key("flo.foldToggle")
}

final class WidgetBox: NSObject {
    let widget: Widget
    let width: CGFloat
    // images
    var image: LoadedImage?
    var size: CGSize = .zero
    /// Image top relative to the top of the visual line holding the widget char.
    var yOffset: CGFloat = 0
    /// Drawn after the attributed char (a widget placed at the end of its source).
    var trailing = false
    /// Unresolved `![[embed]]`: raw text drawn muted.
    var placeholder: String?
    /// Rendered table (block widget drawn on its first line).
    var table: TableLayout?
    /// Rendered KaTeX formula.
    var math: MathRenderer.Result?
    /// Rendered HTML block.
    var html: HtmlBlockRenderer.Result?
    /// Mermaid canvas snapshot (nil while rendering: the empty frame is drawn).
    var mermaid: NSImage?
    init(_ w: Widget, width: CGFloat) { widget = w; self.width = width }
}

final class LineBox: NSObject {
    let style: LineStyle
    let lineNumber: Int
    init(_ s: LineStyle, _ n: Int) { style = s; lineNumber = n }
    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? LineBox else { return false }
        return o.style == style && o.lineNumber == lineNumber
    }
}

/// Converts a RenderPlan into text-storage attributes, line by line.
final class AttributeApplier {
    let theme: EditorTheme
    /// Left gutter inside the text container (room for hanging hashes and
    /// for the ordered-list -0.4ch first-line indent).
    let gutter: CGFloat
    lazy var hiddenFont = NSFont.systemFont(ofSize: 0.01)

    init(theme: EditorTheme, gutter: CGFloat) {
        self.theme = theme
        self.gutter = gutter
    }

    /// Signature of everything that affects one line's attributes, used to skip
    /// untouched lines on re-render.
    func lineSignature(plan: RenderPlan, line: Line, index: Int) -> Int {
        var h = Hasher()
        h.combine(plan.lines[index])
        var i = runIndex(plan, line.from)
        // positions relative to the line, so lines that merely shifted keep their signature
        while i < plan.runs.count, plan.runs[i].from <= line.to {
            let r = plan.runs[i]
            h.combine(max(r.from, line.from) - line.from); h.combine(min(r.to, line.to + 1) - line.from); h.combine(r.style)
            i += 1
        }
        for w in plan.widgetsOverlapping(line.from, line.to) {
            var rel = w; rel.from -= line.from; rel.to -= line.from
            h.combine(rel)
            if case .math = w.kind, w.from >= line.from, let key = mathKey(w, plan: plan, index: index) {
                h.combine(MainActor.assumeIsolated { MathRenderer.shared.cached(key) != nil })
            }
            if case .htmlBlock(let src) = w.kind, w.from >= line.from {
                let key = HtmlBlockRenderer.Key(raw: src, width: columnWidth, style: MainActor.assumeIsolated { HtmlBlockRenderer.style(theme: theme) })
                h.combine(MainActor.assumeIsolated { HtmlBlockRenderer.shared.cached(key) != nil })
            }
            if case .mermaid = w.kind, w.from >= line.from, let key = mermaidKey(w) {
                h.combine(MainActor.assumeIsolated { MermaidRenderer.shared.cached(key) != nil })
            }
        }
        h.combine(foldedLines.contains(index))
        h.combine(foldToggles[index])
        return h.finalize()
    }

    func runIndex(_ plan: RenderPlan, _ pos: Int) -> Int {
        var lo = 0, hi = plan.runs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if plan.runs[mid].to <= pos { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func widgetWidth(_ w: Widget, font: NSFont) -> CGFloat {
        switch w.kind {
        case .emoji(let e): return (e as NSString).size(withAttributes: [.font: theme.emojiFont(size: font.pointSize)]).width
        case .dash(let d): return (d as NSString).size(withAttributes: [.font: font]).width
        case .tab: return theme.ch * 4
        case .wikiLink(let display, let image):
            return image ? 0 : (display as NSString).size(withAttributes: [.font: font]).width
        default: return 0
        }
    }

    var state_units: [UInt16] = []
    /// 0-based indices of lines hidden inside folded sections.
    var foldedLines = IndexSet()
    /// 0-based heading line index → folded?, for foldable headings.
    var foldToggles: [Int: Bool] = [:]
    var showFoldToggles = true
    let images = ImageStore()
    let tables = TableCache()
    /// Text column width (the CSS line box width images are clamped to).
    var columnWidth: CGFloat = 734

    /// Ordered marker box (CSS): 3ch border-box with 1ch left padding, marker
    /// centred in the remaining width; kern after the marker closes the box.
    func orderedMarkerOffset(line: Line, storage: NSTextStorage) -> CGFloat {
        let text = line.text as NSString
        let m = text.range(of: #"^\s*\d+[.)]"#, options: .regularExpression)
        guard m.location != NSNotFound else { return 0 }
        let lead = text.substring(to: m.location + m.length).prefix { $0 == " " || $0 == "\t" }.utf16.count
        let markRange = NSRange(location: line.from + lead, length: m.length - lead)
        let markW = storage.attributedSubstring(from: markRange).size().width
        let ch = theme.ch
        let content = max(2 * ch, markW)
        let before = ch + (content - markW) / 2
        let after = content - markW - (content - markW) / 2
        if markRange.length > 0 {
            storage.addAttribute(.kern, value: after, range: NSRange(location: markRange.location + markRange.length - 1, length: 1))
        }
        return before
    }

    func mermaidKey(_ w: Widget) -> MermaidRenderer.Key? {
        guard case .mermaid(let body) = w.kind, w.to <= state_units.count else { return nil }
        let fence = String(utf16CodeUnits: Array(state_units[w.from..<w.to]), count: w.to - w.from)
        return MermaidRenderer.Key(body: body, fenceText: fence, width: columnWidth,
                                   page: MainActor.assumeIsolated { MermaidRenderer.style(theme: theme) })
    }

    /// KaTeX render key: the widget inherits the line's font size and colour.
    func mathKey(_ w: Widget, plan: RenderPlan, index: Int) -> MathRenderer.Key? {
        guard case .math(let formula, let display) = w.kind else { return nil }
        // widgets sit outside the highlight marks: the line's own font (body size, text colour), even in headings
        let size = theme.baseSize
        let color = theme.textColor
        return MathRenderer.Key(formula: formula, display: display, fontSize: size, lineHeight: size * theme.lineHeight,
                                color: color.cssRGBA, fontFamily: theme.cssFontFamily,
                                errorColor: NSColor(oklchL: 0.7593, c: 0.182, h: 28.91).cssRGBA, codeBackground: theme.codeBackground.cssRGBA,
                                // CodeMirror wraps every inline widget in cm-widgetBuffer images
                                bufferBefore: true, bufferAfter: true)
    }

    /// Apply attributes for one document line [line.from, line.to] (+ newline).
    func apply(to storage: NSTextStorage, plan: RenderPlan, line: Line, index: Int) {
        let ls = plan.lines[index]
        let end = min(storage.length, line.to + 1)
        let fullRange = NSRange(location: line.from, length: end - line.from)
        guard fullRange.length >= 0, line.from <= storage.length else { return }

        if foldedLines.contains(index) {
            // inside a folded section: no visible trace (CM's placeholder is invisible)
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = 0.001; para.maximumLineHeight = 0.001
            storage.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: para,
                                   .floLine: LineBox(ls, line.number)], range: fullRange)
            return
        }
        // Lines after the first of a multi-line block widget (tables): the
        // widget is drawn on its first line; the rest take no space.
        if plan.widgetsOverlapping(line.from, line.to).contains(where: { w in
            guard w.replaces && w.from < line.from && w.to >= line.from else { return false }
            if case .table = w.kind { return w.block }
            if case .mermaid = w.kind { return w.block }
            if case .htmlBlock = w.kind { return w.block }
            if case .math(_, true) = w.kind { return w.to >= line.to }
            return false
        }) {
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = 0.001; para.maximumLineHeight = 0.001
            storage.setAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: para,
                                   .floLine: LineBox(ls, line.number)], range: fullRange)
            return
        }
        let base = theme.baseSize
        var maxInlineSize: CGFloat = 0
        let ch = theme.ch

        // character runs
        var i = runIndex(plan, line.from)
        while i < plan.runs.count, plan.runs[i].from < end {
            let r = plan.runs[i]
            let a = max(r.from, line.from), b = min(r.to, end)
            if a < b {
                let st = r.style
                var attrs: [NSAttributedString.Key: Any] = [.floLine: LineBox(ls, line.number)]
                let size = base * CGFloat(st.sizeEm)
                let font = theme.font(size: size, weight: st.weight, mono: st.mono)
                switch st.hidden {
                case .removed?, .zeroSize?:
                    attrs[.font] = hiddenFont
                    attrs[.foregroundColor] = NSColor.clear
                    if st.codeBackground { attrs[.floInlineCode] = true }  // hidden backticks: still inside the padding box
                case .margin(let visible)?:
                    attrs[.font] = hiddenFont
                    attrs[.foregroundColor] = NSColor.clear
                    attrs[.floHeadingHash] = visible
                    attrs[.floOpacity] = st.opacity
                case .transparent?:
                    attrs[.font] = font
                    attrs[.foregroundColor] = NSColor.clear
                    maxInlineSize = max(maxInlineSize, size)
                case nil:
                    attrs[.font] = font
                    var color = theme.color(st.color)
                    if st.opacity < 1 { color = color.withAlphaComponent(color.alphaComponent * CGFloat(st.opacity)) }
                    attrs[.foregroundColor] = color
                    maxInlineSize = max(maxInlineSize, size)
                    if st.italic && !theme.hasItalicFace() { attrs[.obliqueness] = 0.2 }
                    if st.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if st.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if st.codeBackground { attrs[.floInlineCode] = true }
                }
                storage.setAttributes(attrs, range: NSRange(location: a, length: b - a))
            }
            i += 1
        }

        // `.cm-inline-code { padding: 0.2rem }`: the padding takes inline space on both sides
        // of the InlineCode node (kern after the char before it / after its last char).
        var codeStartIndent: CGFloat = 0
        do {
            var j = runIndex(plan, line.from)
            var spans: [(Int, Int)] = []
            while j < plan.runs.count, plan.runs[j].from < line.to {
                let r = plan.runs[j]
                if r.style.codeBackground {
                    let a = max(r.from, line.from), b = min(r.to, line.to)
                    if let last = spans.last, last.1 == a { spans[spans.count - 1].1 = b } else if a < b { spans.append((a, b)) }
                }
                j += 1
            }
            let pad = 0.2 * theme.rem
            func addKern(_ i: Int) {
                let k = (storage.attribute(.kern, at: i, effectiveRange: nil) as? CGFloat) ?? 0
                storage.addAttribute(.kern, value: k + pad, range: NSRange(location: i, length: 1))
            }
            for (a, b) in spans {
                if a > line.from { addKern(a - 1) } else { codeStartIndent += pad }
                addKern(b - 1)
            }
        }

        // emoji in visible text: Chrome's 1em-advance emoji
        if line.text.unicodeScalars.contains(where: { $0.value >= 0x2190 }) {
            var pos = line.from
            for c in line.text {
                let n = c.utf16.count
                if EditorTheme.isEmoji(c), pos + n <= storage.length,
                   let f = storage.attribute(.font, at: pos, effectiveRange: nil) as? NSFont, f.pointSize > 0.5,
                   storage.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? NSColor != NSColor.clear {
                    storage.addAttribute(.font, value: theme.emojiFont(size: f.pointSize), range: NSRange(location: pos, length: n))
                }
                pos += n
            }
        }

        // widgets: reserve width and remember what to draw
        var listFirstIndent: CGFloat? = nil
        var blockImage: WidgetBox?, afterImage: WidgetBox?, inlineImages: [WidgetBox] = []
        var tableBox: WidgetBox?, mermaidBox: WidgetBox?, htmlBox: WidgetBox?
        var mathDisplay: WidgetBox?, mathInline: [WidgetBox] = []
        let lineWidgets = plan.widgetsOverlapping(line.from, max(end, line.from + 1))
        for w in lineWidgets where w.from >= line.from && w.from < max(end, line.from + 1) {
            let font = theme.font(size: base, weight: 400, mono: false)
            switch w.kind {
            case .bullet(let depth), .checkbox(let depth, _):
                // The prefix source is invisible. CodeMirror splits the fixed-width
                // prefix span around tab widgets and each piece keeps the full width.
                let prefixWidth = CGFloat(depth + 1) * RenderPlanner.listUnitCh * ch
                let len = min(w.to, end) - w.from
                guard len > 0 else { continue }
                storage.addAttributes([.font: hiddenFont, .foregroundColor: NSColor.clear],
                                      range: NSRange(location: w.from, length: len))
                storage.removeAttribute(.kern, range: NSRange(location: w.from, length: len))
                var total: CGFloat = 0, segOpen = false, markerX: CGFloat = 0
                let markPos = (0..<len).first { i in let c = state_units[w.from + i]; return c == 45 || c == 42 || c == 43 } ?? 0
                for i in 0..<len {
                    let c = state_units[w.from + i]
                    if c == 9 { if segOpen { total += prefixWidth; segOpen = false }; total += 4 * ch; continue }
                    if !segOpen { segOpen = true; if i <= markPos { markerX = total } }
                }
                if segOpen { total += prefixWidth }
                listFirstIndent = total
                storage.addAttribute(.floWidget, value: WidgetBox(w, width: markerX + CGFloat(depth) * RenderPlanner.listUnitCh * ch),
                                     range: NSRange(location: w.from, length: 1))
            case .image(let src, _, let width, let block):
                guard let img = images.resolve(markdownSource: src) else { continue }
                let size = WidgetBox.imageSize(img, explicitWidth: width, block: block, columnWidth: columnWidth)
                let box = WidgetBox(w, width: size.width)
                box.image = img; box.size = size
                if w.replaces {
                    guard w.to > w.from else { continue }
                    if block { blockImage = box } else {
                        inlineImages.append(box)
                        storage.addAttribute(.kern, value: size.width, range: NSRange(location: w.from, length: 1))
                    }
                    storage.addAttribute(.floWidget, value: box, range: NSRange(location: w.from, length: 1))
                } else {
                    guard w.from > line.from else { continue }
                    box.trailing = true
                    if block { afterImage = box } else {
                        inlineImages.append(box)
                        storage.addAttribute(.kern, value: size.width, range: NSRange(location: w.from - 1, length: 1))
                    }
                    storage.addAttribute(.floWidget, value: box, range: NSRange(location: w.from - 1, length: 1))
                }
            case .math(_, let display) where w.to > w.from:
                guard let key = mathKey(w, plan: plan, index: index),
                      let r = MainActor.assumeIsolated({ MathRenderer.shared.result(key) }) else { continue }
                let box = WidgetBox(w, width: r.width)
                box.math = r
                if display { mathDisplay = box } else {
                    mathInline.append(box)
                    storage.addAttribute(.kern, value: r.width, range: NSRange(location: w.from, length: 1))
                }
                storage.addAttribute(.floWidget, value: box, range: NSRange(location: w.from, length: 1))
            case .htmlBlock(let src) where w.to > w.from:
                let key = HtmlBlockRenderer.Key(raw: src, width: columnWidth, style: MainActor.assumeIsolated { HtmlBlockRenderer.style(theme: theme) })
                let box = WidgetBox(w, width: columnWidth)
                box.html = MainActor.assumeIsolated { HtmlBlockRenderer.shared.result(key) }
                htmlBox = box
                storage.addAttribute(.floWidget, value: box, range: NSRange(location: w.from, length: 1))
            case .mermaid where w.to > w.from:
                guard let key = mermaidKey(w) else { continue }
                let box = WidgetBox(w, width: columnWidth)
                box.mermaid = MainActor.assumeIsolated { MermaidRenderer.shared.image(key) }
                mermaidBox = box
                storage.addAttribute(.floWidget, value: box, range: NSRange(location: w.from, length: 1))
            case .table(let source) where w.to > w.from:
                guard let t = tables.layout(source: source, theme: theme, available: columnWidth) else { continue }
                let box = WidgetBox(w, width: 0)
                box.table = t
                tableBox = box
                storage.addAttribute(.floWidget, value: box, range: NSRange(location: w.from, length: 1))
            case .wikiLink(let display, true) where w.to > w.from:
                let box: WidgetBox
                if let img = images.resolve(embed: display) {
                    let size = WidgetBox.imageSize(img, explicitWidth: nil, block: false, columnWidth: columnWidth)
                    box = WidgetBox(w, width: size.width)
                    box.image = img; box.size = size
                    inlineImages.append(box)
                } else {
                    let raw = String(utf16CodeUnits: Array(state_units[w.from..<w.to]), count: w.to - w.from)
                    box = WidgetBox(w, width: (raw as NSString).size(withAttributes: [.font: font]).width)
                    box.placeholder = raw
                }
                storage.addAttribute(.kern, value: box.width, range: NSRange(location: w.from, length: 1))
                storage.addAttribute(.floWidget, value: box, range: NSRange(location: w.from, length: 1))
            case .tab where lineWidgets.contains { o in
                    if case .bullet = o.kind { return o.from <= w.from && w.from < o.to }
                    if case .checkbox = o.kind { return o.from <= w.from && w.from < o.to }
                    return false }:
                continue // already counted in the list prefix width
            case .tab:
                // 4ch fixed widget; reserve on the previous char so the caret after
                // the tab sits exactly at the text (TextKit reports kerned gaps mid-way).
                if w.from > line.from {
                    storage.addAttribute(.kern, value: 4 * ch, range: NSRange(location: w.from - 1, length: 1))
                } else {
                    listFirstIndent = (listFirstIndent ?? 0) + 4 * ch
                }
            default:
                let width = widgetWidth(w, font: font)
                if w.to > w.from {
                    storage.addAttribute(.kern, value: width, range: NSRange(location: w.from, length: 1))
                    storage.addAttribute(.floWidget, value: WidgetBox(w, width: width), range: NSRange(location: w.from, length: 1))
                }
            }
        }

        // paragraph box (CSS line box emulation)
        let para = NSMutableParagraphStyle()
        let isBlank = line.from == line.to
        let strut = base * theme.lineHeight
        var lineH = max(strut, maxInlineSize * theme.lineHeight)
        if isBlank || ls.kind == .blank { lineH = base }
        if case .setextUnderline = ls.kind, plan.style(at: line.from).hidden == .removed { lineH = 0.01 }
        var before: CGFloat = 0, after: CGFloat = 0
        // A block widget replacing the whole line takes the widget's own height.
        let blockWidget = plan.widgetsOverlapping(line.from, line.to).first { w in
            guard w.block && w.replaces else { return false }
            if case .table = w.kind { return w.from <= line.to && w.to >= line.from }
            if case .mermaid = w.kind { return w.from <= line.to && w.to >= line.from }
            if case .htmlBlock = w.kind { return w.from <= line.to && w.to >= line.from }
            return w.from <= line.from && w.to >= line.to
        }
        if let bw = blockWidget {
            switch bw.kind {
            case .horizontalRule: lineH = 1.4 * base
            case .image: if let b = blockImage { lineH = b.size.height }
            case .table: if let t = tableBox?.table { lineH = t.widgetHeight }
            case .mermaid: if mermaidBox != nil { lineH = MermaidRenderer.widgetHeight }
            case .htmlBlock: if let r = htmlBox?.html, !r.empty { lineH = max(0.01, r.height) }
            default: break
            }
        }
        switch blockWidget == nil ? ls.kind : .blank {
        case .heading:
            before = theme.rem + theme.headingSpaceBefore
            after = theme.headingSpaceAfter
        case .listItem, .orderedItem:
            after = theme.bulletSpacing
        case .blank:
            break
        default:
            after = theme.paragraphSpacing
        }
        // Images: a block image is followed by an 8px gap; an inline image sits
        // on the baseline, growing the line box above the strut.
        if blockImage != nil { after += 8 }
        // CM splits the line at a block widget placed at its end: the empty
        // remainder renders as an extra blank line box below the image.
        if let a = afterImage { a.yOffset = lineH; after += a.size.height + 8 + base }
        var imageBaseline: CGFloat? = nil
        if let m = mathDisplay?.math {
            // the merged line: empty line box, 0.5em margins around .katex-display, line box after
            lineH = m.lineHeight
            // text after the formula sits in the line box below the .katex-display block
            let f = theme.font(size: base, weight: 400, mono: false)
            let a = f.ascender.rounded(), d = (-f.descender).rounded(), L = base * theme.lineHeight
            imageBaseline = m.lineHeight - L + ((L - (a + d)) / 2).rounded(.down) + a
        } else if !mathInline.isEmpty {
            let f = theme.font(size: max(base, maxInlineSize), weight: 400, mono: false)
            let a = f.ascender.rounded(), d = (-f.descender).rounded()
            var above = ((lineH - (a + d)) / 2).rounded(.down) + a
            var below = lineH - above
            for b in mathInline { if let m = b.math { above = max(above, m.baseline); below = max(below, m.lineHeight - m.baseline) } }
            for b in mathInline { if let m = b.math { b.yOffset = above - m.baseline } }
            lineH = above + below
            imageBaseline = above
        }
        if let tallest = inlineImages.map({ $0.size.height }).max(), !(isBlank || ls.kind == .blank) {
            let f = theme.font(size: base, weight: 400, mono: false)
            let c = f.ascender - f.descender
            let above = (strut - c) / 2 + f.ascender, below = (strut - c) / 2 - f.descender
            let b = max(tallest, above)
            imageBaseline = b
            lineH = max(lineH, b + below)
            for box in inlineImages { box.yOffset = b - box.size.height }
        }
        para.minimumLineHeight = lineH
        para.maximumLineHeight = lineH
        para.paragraphSpacingBefore = before
        para.paragraphSpacing = after
        var head = gutter, first = gutter
        if ls.paddingLeftCh != 0 || ls.textIndentCh != 0 {
            head += CGFloat(ls.paddingLeftCh) * ch
            first += CGFloat(ls.paddingLeftCh + ls.textIndentCh) * ch
        }
        if ls.blockquoteDepth > 0 {
            // `.cm-blockquote-line { padding-inline-start: 1em }` whatever the depth;
            // nested quotes only add a bar at the nested `>`
            head += base; first += base
        }
        if case .fencedCode = ls.kind {
            // `.cm-blockquote-line` padding-left replaces the code line's 12px inside a quote
            if ls.blockquoteDepth == 0 { head += 12; first += 12 }
            para.tailIndent = -12
        }
        // .cm-table-source-line's 12px padding loses to the `.cm-line` padding rule: text flush with the background
        if case .frontmatter = ls.kind { head += 12; first += 12 }
        // CodeMirror lines are `white-space: break-spaces`: the space before a
        // soft wrap must fit inside the line (it doesn't hang as in TextKit).
        let spaceW = theme.spaceWidth
        para.tailIndent = para.tailIndent - spaceW
        if let lf = listFirstIndent { first = ls.isListLine ? gutter + lf : first + lf }
        if case .orderedItem = ls.kind { first += orderedMarkerOffset(line: line, storage: storage) }
        first += codeStartIndent
        para.headIndent = head
        para.firstLineHeadIndent = first
        para.lineBreakMode = .byWordWrapping
        // Tabs are rendered as fixed 4ch widgets (tabWidthExtension); stop
        // TextKit from advancing the hidden tab char to a tab stop.
        para.tabStops = []
        para.defaultTabInterval = 0.0001
        storage.addAttribute(.paragraphStyle, value: para, range: fullRange)
        if let folded = foldToggles[index], showFoldToggles, line.to > line.from {
            storage.addAttribute(.floFoldToggle, value: NSNumber(value: folded), range: NSRange(location: line.from, length: 1))
        } else if line.to > line.from {
            storage.removeAttribute(.floFoldToggle, range: NSRange(location: line.from, length: 1))
        }
        if line.from == line.to && fullRange.length > 0 {
            // TextKit 2 ignores min/max line height on an empty paragraph and uses
            // the newline's natural height; size that invisible font so the
            // natural height equals the CSS line box.
            let ref = theme.font(size: base, weight: 400, mono: false)
            let natural = ref.ascender - ref.descender + ref.leading
            storage.addAttribute(.font, value: theme.font(size: base * lineH / natural, weight: 400, mono: false), range: fullRange)
            return
        }

        // Baseline. TextKit 2 puts a fixed-height line's baseline at
        // lineH - round(descent) and ignores negative baselineOffset when
        // drawing (positive values shrink the line), so the fragment shifts the
        // glyphs itself. CSS (Chrome) centres round(ascent)+round(descent) in
        // the line box; an inline image instead pushes the baseline down.
        var dominant: NSFont? = nil
        storage.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let f = value as? NSFont, f.pointSize > 0.5 else { return }
            if storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == NSColor.clear,
               dominant != nil { return }
            if dominant == nil || f.pointSize > dominant!.pointSize { dominant = f }
        }
        storage.removeAttribute(.baselineOffset, range: fullRange)
        if let f = dominant {
            let a = f.ascender.rounded(), d = (-f.descender).rounded()
            let natural = lineH - d
            // Chrome floors the half-leading to whole pixels
            let css = imageBaseline ?? (((lineH - (a + d)) / 2).rounded(.down) + a)
            storage.addAttribute(.floGlyphShift, value: natural - css, range: fullRange)
        } else {
            storage.removeAttribute(.floGlyphShift, range: fullRange)
        }
    }
}

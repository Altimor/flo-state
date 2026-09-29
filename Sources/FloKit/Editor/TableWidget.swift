import AppKit
import CoreText
import FloCore

/// Rendered GFM table (table-decorations.ts TableWidget + tableTheme): an
/// inline-block `<table>` with separate borders, 8px radius, cells padded
/// 0.5em / 0.8em, min-width 6em, line-height 1.4, header weight 600 on the
/// subtle surface. Laid out with WebKit's auto table layout algorithm.
final class TableLayout {
    struct Line {
        var line: CTLine
        var x: CGFloat          // relative to the cell's content box
        var baseline: CGFloat   // relative to the cell's content box top
        var range: NSRange      // in the cell's attributed string
        var bottom: CGFloat = 0 // line box bottom relative to the content box top
        var top: CGFloat = 0    // line box top relative to the content box top
    }
    struct Cell {
        var frame: CGRect       // border box relative to the table's top-left
        var content: NSAttributedString
        var lines: [Line] = []
        var contentTop: CGFloat = 0   // content box top relative to the table
        var header: Bool
        var alignment: ParsedTable.Alignment?
    }

    let table: ParsedTable
    var cells: [[Cell]] = []
    /// Table border box.
    var size: CGSize = .zero
    /// The widget block height (padding + inline-block line box).
    var widgetHeight: CGFloat = 0
    /// Top of the table inside the widget.
    var tableTop: CGFloat = 0

    static let border: CGFloat = 1

    init(table: ParsedTable, theme: EditorTheme, available: CGFloat) {
        self.table = table
        layout(theme: theme, available: available)
    }

    // MARK: attributed cell content

    static let codeFontKey = NSAttributedString.Key("flo.table.code")
    static let wikiKey = NSAttributedString.Key("flo.table.wiki")
    static let hrefKey = NSAttributedString.Key("flo.table.href")
    /// First char of an inline code whose left padding is a kern on the previous char.
    static let codePadKey = NSAttributedString.Key("flo.table.codePad")
    static let obliqueKey = NSAttributedString.Key("flo.table.oblique")
    static let emojiKey = NSAttributedString.Key("flo.table.emoji")

    /// Fixed-advance placeholder (CTRunDelegate) for padding at a line start.
    static func spacer(_ width: CGFloat, font: NSFont) -> NSAttributedString {
        final class W { let w: CGFloat; init(_ w: CGFloat) { self.w = w } }
        var cb = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { p in Unmanaged<W>.fromOpaque(p).release() },
                                        getAscent: { _ in 0 }, getDescent: { _ in 0 },
                                        getWidth: { p in Unmanaged<W>.fromOpaque(p).takeUnretainedValue().w })
        let d = CTRunDelegateCreate(&cb, Unmanaged.passRetained(W(width)).toOpaque())!
        return NSAttributedString(string: "\u{FFFC}", attributes: [.font: font, NSAttributedString.Key(kCTRunDelegateAttributeName as String): d,
                                                                   codeFontKey: true, .foregroundColor: NSColor.clear])
    }

    struct Ctx { var weight: Int; var italic = false; var strike = false; var underline = false; var color: NSColor; var code = false
        var href: String? = nil; var wiki: String? = nil }

    static func attributed(_ nodes: [CellInline], header: Bool, theme: EditorTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let size = theme.baseSize
        func font(_ c: Ctx) -> NSFont {
            if c.code { return theme.font(size: size, weight: c.weight, mono: true) }
            var f = theme.font(size: size, weight: c.weight, mono: false)
            if c.italic {
                let conv = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
                if conv.fontDescriptor.symbolicTraits.contains(.italic) { f = conv }
            }
            return f
        }
        func append(_ s: String, _ c: Ctx) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font(c), .foregroundColor: c.color]
            if c.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if c.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if c.code { attrs[codeFontKey] = true; attrs[.ligature] = 0; attrs[.kern] = 0 }
            if c.italic, !((attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) ?? true) {
                attrs[obliqueKey] = true   // synthesised oblique (skewed when drawn), as the editor's obliqueness 0.2
            }
            if let h = c.href { attrs[hrefKey] = h }
            if let w = c.wiki { attrs[wikiKey] = w }
            out.append(NSAttributedString(string: s, attributes: attrs))
        }
        func walk(_ ns: [CellInline], _ c: Ctx) {
            for n in ns {
                switch n {
                case .text(let t): append(t, c)
                case .lineBreak: append("\n", c)
                case .element(let tag, let cls, let href, let wiki, let kids):
                    var k = c
                    switch tag {
                    case .strong: k.weight = c.weight >= 600 ? 900 : 700 // `bolder`
                    case .em: k.italic = true
                    case .s: k.strike = true
                    case .code:
                        k.code = true
                        let pad = 0.2 * theme.rem
                        if out.length > 0, (out.string as NSString).character(at: out.length - 1) != 10 {
                            // left padding: extra advance after the previous char
                            let prev = NSRange(location: out.length - 1, length: 1)
                            let k0 = (out.attribute(.kern, at: prev.location, effectiveRange: nil) as? CGFloat) ?? 0
                            out.addAttribute(.kern, value: k0 + pad, range: prev)
                        } else {
                            out.append(Self.spacer(pad, font: font(k)))
                        }
                        let start = out.length
                        walk(kids, k)
                        if out.length > start {
                            out.addAttribute(.kern, value: pad, range: NSRange(location: out.length - 1, length: 1))
                            out.addAttribute(codePadKey, value: true, range: NSRange(location: start, length: 1))
                        } else {
                            out.append(Self.spacer(pad, font: font(k)))
                        }
                        continue
                    case .span:
                        if cls == "cm-rendered-link" { k.color = theme.accent; k.underline = true; k.href = href }
                        if cls == "cm-wiki-link" { k.color = theme.accent; k.underline = false; k.wiki = wiki }
                    }
                    walk(kids, k)
                }
            }
        }
        walk(nodes, Ctx(weight: header ? 600 : 400, color: theme.textColor))
        // the widget inherits CodeMirror's `white-space: break-spaces`: spaces are kept
        emojiFonts(out, theme: theme)
        return out
    }

    static func emojiFonts(_ s: NSMutableAttributedString, theme: EditorTheme) {
        var pos = 0
        for c in s.string {
            let n = c.utf16.count
            if EditorTheme.isEmoji(c), let f = s.attribute(.font, at: pos, effectiveRange: nil) as? NSFont {
                s.addAttributes([.font: theme.emojiFont(size: f.pointSize), emojiKey: true], range: NSRange(location: pos, length: n))
            }
            pos += n
        }
    }

    // MARK: layout

    /// CSS line box of one line of text: fonts' rounded ascent/descent each
    /// centred in `lh`, the box spans the extremes.
    static func lineBox(_ s: NSAttributedString, _ range: NSRange, lh: CGFloat, strut: NSFont) -> (above: CGFloat, below: CGFloat) {
        var above: CGFloat = 0, below: CGFloat = 0
        var seen = Set<String>()
        func add(_ f: NSFont) {
            let key = "\(f.fontName)|\(f.pointSize)"
            if !seen.insert(key).inserted { return }
            let a = f.ascender.rounded(), d = (-f.descender).rounded()
            // WebKit floors the top half-leading; the remainder goes below
            let top = ((lh - (a + d)) / 2).rounded(.down)
            above = max(above, a + top); below = max(below, lh - a - top)
        }
        // the cell's strut (primary font of the cell)
        add(strut)
        // with a fixed line-height only elements' primary fonts count, not fallback (emoji) fonts
        if range.length > 0 {
            s.enumerateAttributes(in: range) { attrs, _, _ in
                if attrs[emojiKey] == nil, let f = attrs[.font] as? NSFont { add(f) }
            }
        }
        return (above, below)
    }

    /// Hard lines (split at <br>) → (min-content, max-content) widths.
    static func intrinsic(_ s: NSAttributedString) -> (min: CGFloat, max: CGFloat) {
        let str = s.string as NSString
        var mn: CGFloat = 0, mx: CGFloat = 0
        var start = 0
        func width(_ r: NSRange) -> CGFloat {
            guard r.length > 0 else { return 0 }
            let line = CTLineCreateWithAttributedString(s.attributedSubstring(from: r))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        }
        for i in 0...str.length {
            if i == str.length || str.character(at: i) == 10 {
                let hard = NSRange(location: start, length: i - start)
                mx = max(mx, width(hard))
                // words: break opportunities at spaces
                var ws = start
                for j in start...i {
                    if j == i || str.character(at: j) == 32 {
                        mn = max(mn, width(NSRange(location: ws, length: j - ws)))
                        ws = j + 1
                    }
                }
                start = i + 1
            }
        }
        return (mn, mx)
    }

    func layout(theme: EditorTheme, available: CGFloat) {
        let em = theme.baseSize
        let padX = 0.8 * em, padY = 0.5 * em
        let lh = 1.4 * em
        let minCell = 6 * em
        let strut = theme.font(size: em, weight: 400, mono: false)
        let ncols = table.headers.count
        var grid: [[Cell]] = []
        let head = (0..<ncols).map { c in
            Cell(frame: .zero, content: Self.attributed(CellMarkdown.parse(table.headers[c]), header: true, theme: theme),
                 header: true, alignment: table.alignments.indices.contains(c) ? table.alignments[c] : nil)
        }
        grid.append(head)
        for r in table.rows {
            grid.append((0..<ncols).map { c in
                Cell(frame: .zero, content: Self.attributed(CellMarkdown.parse(c < r.count ? r[c] : ""), header: false, theme: theme),
                     header: false, alignment: table.alignments.indices.contains(c) ? table.alignments[c] : nil)
            })
        }
        let nrows = grid.count
        func borderRight(_ c: Int) -> CGFloat { c == ncols - 1 ? 0 : Self.border }
        func borderBottom(_ r: Int) -> CGFloat { (r == nrows - 1 && r > 0) ? 0 : Self.border }

        // column min/max (border box)
        var mins = [CGFloat](repeating: 0, count: ncols), maxs = mins
        for row in grid {
            for (c, cell) in row.enumerated() {
                let w = Self.intrinsic(cell.content)
                let extra = 2 * padX + borderRight(c)
                mins[c] = max(mins[c], max(minCell, w.min + extra))
                maxs[c] = max(maxs[c], max(minCell, w.max + extra))
            }
        }
        for c in 0..<ncols { maxs[c] = max(maxs[c], mins[c]) }
        // shrink-to-fit inline-block: min(max(minPref, avail), maxPref)
        let borders = 2 * Self.border
        let sumMin = mins.reduce(0, +), sumMax = maxs.reduce(0, +)
        let tableW = min(max(sumMin + borders, available), sumMax + borders)
        var widths = mins
        var remaining = tableW - borders
        if remaining >= sumMax {
            widths = maxs
        } else {
            // AutoTableLayout::layout: auto columns take max(min, avail * max / totalAuto)
            var totalAuto = sumMax
            for c in 0..<ncols {
                let w = totalAuto > 0 ? max(mins[c], remaining * maxs[c] / totalAuto) : mins[c]
                widths[c] = w; remaining -= w; totalAuto -= maxs[c]
            }
            if remaining < 0 {
                var beyond = (0..<ncols).reduce(CGFloat(0)) { $0 + widths[$1] - mins[$1] }
                var c = ncols
                while c > 0 && beyond > 0 {
                    c -= 1
                    let diff = widths[c] - mins[c]
                    let reduce = remaining * diff / beyond
                    widths[c] += reduce; remaining -= reduce; beyond -= diff
                    if remaining >= 0 { break }
                }
            }
        }
        // lines + row heights
        var y = Self.border
        for r in 0..<nrows {
            var rowContent: CGFloat = 0
            var x = Self.border
            for c in 0..<ncols {
                var cell = grid[r][c]
                let contentW = widths[c] - 2 * padX - borderRight(c)
                cell.lines = Self.breakLines(cell.content, width: contentW, lh: lh, strut: strut)
                cell.frame = CGRect(x: x, y: 0, width: widths[c], height: 0)
                let h = cell.lines.last?.bottom ?? lh
                rowContent = max(rowContent, h)
                // horizontal alignment: header default centre (UA `th`)
                let align = cell.alignment ?? (cell.header ? .center : .left)
                for i in cell.lines.indices {
                    let w = CGFloat(CTLineGetTypographicBounds(cell.lines[i].line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(cell.lines[i].line))
                    switch align {
                    case .left: cell.lines[i].x = 0
                    case .center: cell.lines[i].x = (contentW - w) / 2
                    case .right: cell.lines[i].x = contentW - w
                    }
                }
                grid[r][c] = cell
                x += widths[c]
            }
            let rowH = (rowContent + 2 * padY + borderBottom(r) + 0.001).rounded(.down)
            for c in 0..<ncols {
                var cell = grid[r][c]
                let h = cell.lines.last?.bottom ?? lh
                cell.frame.origin.y = y
                cell.frame.size.height = rowH
                // vertical-align: middle
                let inner = rowH - 2 * padY - borderBottom(r)
                cell.contentTop = y + padY + ((inner - h) / 2)
                grid[r][c] = cell
            }
            y += rowH
        }
        cells = grid
        size = CGSize(width: tableW, height: y + Self.border)
        // widget: padding 0.25em, inline-block sitting on the baseline of a
        // body line box (its baseline is the table's bottom edge)
        let f = theme.font(size: em, weight: 400, mono: false)
        let L = em * theme.lineHeight
        let a = f.ascender.rounded(), d = (-f.descender).rounded()
        let strutAbove = ((L - (a + d)) / 2).rounded(.down) + a
        let strutBelow = L - strutAbove
        let pad = 0.25 * em
        tableTop = pad + max(0, strutAbove - size.height)
        widgetHeight = pad + max(size.height, strutAbove) + strutBelow + pad
    }

    static func breakLines(_ s: NSAttributedString, width: CGFloat, lh: CGFloat, strut: NSFont) -> [Line] {
        var out: [Line] = []
        let str = s.string as NSString
        var y: CGFloat = 0
        var hardStart = 0
        for i in 0...str.length where i == str.length || str.character(at: i) == 10 {
            let hard = NSRange(location: hardStart, length: i - hardStart)
            hardStart = i + 1
            if hard.length == 0 {
                let box = lineBox(s, hard, lh: lh, strut: strut)
                y += (box.above + box.below + 0.001).rounded(.down)  // WebKit line boxes are whole pixels here
                out.append(Line(line: CTLineCreateWithAttributedString(NSAttributedString(string: "")), x: 0, baseline: y - box.below, range: hard, bottom: y))
                continue
            }
            let sub = s.attributedSubstring(from: hard)
            let ts = CTTypesetterCreateWithAttributedString(sub)
            var pos = 0
            while pos < hard.length {
                var n = CTTypesetterSuggestLineBreak(ts, pos, Double(max(1, width)))
                if n <= 0 { n = 1 }
                let r = NSRange(location: hard.location + pos, length: n)
                let line = CTTypesetterCreateLine(ts, CFRange(location: pos, length: n))
                let box = lineBox(s, r, lh: lh, strut: strut)
                let top = y
                y += (box.above + box.below + 0.001).rounded(.down)  // WebKit line boxes are whole pixels here
                out.append(Line(line: line, x: 0, baseline: top + box.above, range: r, bottom: y, top: top))
                pos += n
            }
        }
        return out
    }

    // MARK: drawing

    func draw(at origin: CGPoint, theme: EditorTheme, in context: CGContext) {
        let rect = CGRect(origin: origin, size: size)
        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
        let clip = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        let borderColor = theme.foreground.withAlphaComponent(theme.contrast * 0.24)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        // header surface
        if let head = cells.first {
            theme.foreground.withAlphaComponent(theme.contrast * 0.18).setFill()
            for c in head { NSBezierPath(rect: c.frame.offsetBy(dx: origin.x, dy: origin.y)).fill() }
        }
        // cell borders (right / bottom)
        borderColor.setFill()
        for (r, row) in cells.enumerated() {
            for (c, cell) in row.enumerated() {
                let f = cell.frame.offsetBy(dx: origin.x, dy: origin.y)
                if c < row.count - 1 { NSBezierPath(rect: CGRect(x: f.maxX - 1, y: f.minY, width: 1, height: f.height)).fill() }
                if !(r == cells.count - 1 && r > 0) { NSBezierPath(rect: CGRect(x: f.minX, y: f.maxY - 1, width: f.width, height: 1)).fill() }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        borderColor.setStroke()
        outer.lineWidth = 1
        outer.stroke()

        let em = theme.baseSize, padX = 0.8 * em
        for row in cells {
            for cell in row {
                let left = origin.x + cell.frame.minX + padX
                let top = origin.y + cell.contentTop
                for l in cell.lines { drawLine(l, cell.content, x: left + l.x, baseline: top + l.baseline, theme: theme, context: context) }
            }
        }
    }

    private func drawLine(_ l: Line, _ s: NSAttributedString, x: CGFloat, baseline: CGFloat, theme: EditorTheme, context: CGContext) {
        guard l.range.length > 0 else { return }
        // x of a string index: lines from the typesetter index the whole cell string, so
        // map through the line's own string range (subtracting the line start put every
        // pill after a cell's first line at the wrong place)
        let base = CTLineGetStringRange(l.line).location - l.range.location
        func offset(_ i: Int) -> CGFloat { CTLineGetOffsetForStringIndex(l.line, i + base, nil) }
        // inline code pills behind the glyphs
        s.enumerateAttribute(Self.codeFontKey, in: l.range) { v, r, _ in
            guard v != nil, let f = s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont else { return }
            var x0 = offset(r.location)
            if s.attribute(Self.codePadKey, at: r.location, effectiveRange: nil) != nil, r.location > l.range.location {
                x0 -= 0.2 * theme.rem
            }
            var x1 = offset(r.location + r.length)
            if r.location + r.length == l.range.location + l.range.length {
                x1 = CGFloat(CTLineGetTypographicBounds(l.line, nil, nil, nil))
            }
            // padding stays inside the line box, so code on consecutive lines doesn't overlap
            let pad = 0.2 * theme.rem
            let lineTop = baseline - l.baseline + l.top, lineBottom = baseline - l.baseline + l.bottom
            let top = max(baseline - f.ascender - pad, lineTop + 1), bottom = min(baseline - f.descender + pad, lineBottom - 1)
            let pill = CGRect(x: x + x0, y: top, width: x1 - x0, height: max(f.ascender - f.descender, bottom - top))
            theme.codeBackground.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 0.4 * theme.rem, yRadius: 0.4 * theme.rem).fill()
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for run in (CTLineGetGlyphRuns(l.line) as? [CTRun]) ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            context.saveGState()
            if attrs[Self.obliqueKey] != nil {
                // skew about the baseline: x' = x - 0.2 (y - baseline) in the flipped space
                context.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.2, d: 1, tx: 0.2 * baseline, ty: 0))
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTRunDraw(run, context, CFRange(location: 0, length: 0))
            context.restoreGState()
        }
        context.restoreGState()
        // underline / line-through (CTLineDraw doesn't draw them)
        s.enumerateAttributes(in: l.range) { attrs, r, _ in
            let u = attrs[.underlineStyle] != nil, st = attrs[.strikethroughStyle] != nil
            guard u || st, let f = attrs[.font] as? NSFont else { return }
            let x0 = offset(r.location)
            let x1 = offset(r.location + r.length)
            let color = (attrs[.foregroundColor] as? NSColor) ?? theme.textColor
            color.setFill()
            let t = max(1, f.underlineThickness.rounded())
            if u {
                let y = (baseline - f.underlinePosition).rounded()
                NSBezierPath(rect: CGRect(x: x + x0, y: y, width: x1 - x0, height: t)).fill()
            }
            if st {
                let y = (baseline - f.xHeight / 2).rounded() - t / 2
                NSBezierPath(rect: CGRect(x: x + x0, y: y, width: x1 - x0, height: t)).fill()
            }
        }
    }

    func dump() -> [[Double]] {
        cells.flatMap { $0.map { [Double($0.frame.minX), Double($0.frame.minY), Double($0.frame.width), Double($0.frame.height)] } }
    }
}

/// Table layouts keyed by source + available width (theme changes recreate the applier).
final class TableCache {
    private var cache: [String: TableLayout] = [:]
    func layout(source: String, theme: EditorTheme, available: CGFloat) -> TableLayout? {
        let key = "\(available)|\(source)"
        if let hit = cache[key] { return hit }
        guard let t = ParsedTable.parse(source) else { return nil }
        let l = TableLayout(table: t, theme: theme, available: available)
        if ProcessInfo.processInfo.environment["FLO_DUMP_TABLES"] != nil,
           let j = try? JSONSerialization.data(withJSONObject: ["size": [l.size.width, l.size.height], "widget": l.widgetHeight,
                                                                "top": l.tableTop, "cells": l.dump()]) {
            FileHandle.standardError.write(j + Data("\n".utf8))
        }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = l
        return l
    }
}

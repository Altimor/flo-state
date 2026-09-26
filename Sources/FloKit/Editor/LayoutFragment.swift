import AppKit
import FloCore

/// Draws everything CSS draws around the text: bullets and checkboxes (list
/// prefix ::before), fenced-code and table-source backgrounds, inline code
/// pills, blockquote bars, margin heading hashes and replacement widgets.
final class FloLayoutFragment: NSTextLayoutFragment {
    weak var editor: EditorController?

    private var paragraph: NSAttributedString? { (textElement as? NSTextParagraph)?.attributedString }

    override var renderingSurfaceBounds: CGRect {
        // Hashes hang left of the text column and widgets may exceed glyph bounds.
        // Block images and backgrounds span the whole column, beyond the glyphs.
        let full = CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        return super.renderingSurfaceBounds.union(full).insetBy(dx: -120, dy: -4)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let para = paragraph, let editor = editor else {
            super.draw(at: point, in: context)
            return
        }
        let theme = editor.theme
        let lineBox = para.length > 0 ? para.attribute(.floLine, at: 0, effectiveRange: nil) as? LineBox : nil
        let frame = CGRect(origin: point, size: layoutFragmentFrame.size)
        let ctx = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        // layoutFragmentFrame starts at the paragraph's indent and is only as
        // wide as the text; the column is fixed in container coordinates.
        let containerLeft = point.x - layoutFragmentFrame.minX
        let columnLeft = containerLeft + editor.applier.gutter
        let columnRight = containerLeft + containerWidth

        // --- backgrounds under the text ---
        if let ls = lineBox?.style {
            let para = paragraphStyle(para)
            let top = point.y + (para?.paragraphSpacingBefore ?? 0)
            let bottom = point.y + layoutFragmentFrame.height - (para?.paragraphSpacing ?? 0)
            switch ls.kind {
            case .fencedCode(let first, let last), .tableSource(let first, let last):
                let rect = CGRect(x: columnLeft, y: top, width: columnRight - columnLeft, height: bottom - top)
                fillRounded(rect, radius: 0.4 * theme.rem, top: first, bottom: last, color: theme.codeBackground)
            default: break
            }
            if ls.blockquoteDepth > 0 {
                // border widths snap down to device pixels (2x)
                let w = (0.3 * theme.baseSize * 2).rounded(.down) / 2
                theme.blockquoteBar.setFill()
                NSBezierPath(rect: CGRect(x: columnLeft, y: top, width: w, height: bottom - top)).fill()
                // blockQuote.ts: a bar per nested QuoteMark at 6px + its measured offset from the line start
                let str = (paragraph?.string ?? "") as NSString
                var i = 0
                let x0 = charOrigin(0, origin: point)?.x
                while i < str.length, let c = Optional(str.character(at: i)), c == 32 || c == 9 || c == 62 {
                    if c == 62, i > 0, let x0 = x0, let xm = charOrigin(i, origin: point)?.x {
                        NSBezierPath(rect: CGRect(x: columnLeft + 6 + (xm - x0), y: top, width: w, height: bottom - top)).fill()
                    }
                    i += 1
                }
            }
        }
        // inline code pills
        para.enumerateAttribute(.floInlineCode, in: NSRange(location: 0, length: para.length)) { v, range, _ in
            guard v != nil else { return }
            for r in rects(for: range, origin: point) {
                // padding box: 0.2rem around the content area; the right padding is already the
                // kern after the last char (inside r), the left one precedes r
                let pad = 0.2 * theme.rem
                let pill = CGRect(x: r.minX - pad, y: r.minY - pad, width: r.width + pad, height: r.height + 2 * pad)
                theme.codeBackground.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 0.4 * theme.rem, yRadius: 0.4 * theme.rem).fill()
            }
        }

        let shift = para.length > 0 ? (para.attribute(.floGlyphShift, at: 0, effectiveRange: nil) as? CGFloat) ?? 0 : 0
        if shift != 0 {
            context.saveGState()
            context.translateBy(x: 0, y: -shift)
            super.draw(at: point, in: context)
            context.restoreGState()
        } else {
            super.draw(at: point, in: context)
        }

        // --- decorations over the text ---
        para.enumerateAttribute(.floWidget, in: NSRange(location: 0, length: para.length)) { v, range, _ in
            guard let box = v as? WidgetBox, let origin = self.charOrigin(range.location, origin: point) else { return }
            let trailingX = box.trailing ? self.charOrigin(range.location + 1, origin: point)?.x : nil
            self.drawWidget(box, at: origin, lineLeft: columnLeft, theme: theme, trailingX: trailingX)
        }
        // heading fold chevron (heading-fold.ts): only while the line is hovered
        if para.length > 0, let folded = (para.attribute(.floFoldToggle, at: 0, effectiveRange: nil) as? NSNumber)?.boolValue,
           let line = lineBox?.lineNumber, editor.hoverLine == line, let lf = textLineFragments.first {
            let em = editor.headingFontSize(line)
            let top = point.y + lf.typographicBounds.minY
            let cy = top + lf.typographicBounds.height / 2 + 4
            let box = CGRect(x: columnLeft - 0.55 * em - em, y: cy - em / 2, width: em, height: em)
            let w = 0.34 * em, h = 0.52 * em
            // triangle pointing right, centred in the box; rotated 90° (down) when expanded
            let tri = NSBezierPath()
            tri.move(to: CGPoint(x: -w * 0.4, y: -h / 2))
            tri.line(to: CGPoint(x: w * 0.6, y: 0))
            tri.line(to: CGPoint(x: -w * 0.4, y: h / 2))
            tri.close()
            var t = AffineTransform(translationByX: box.midX - w * 0.1, byY: box.midY)
            if !folded { t.rotate(byDegrees: 90) }
            tri.transform(using: t)
            let color = editor.hoverChevron ? theme.foreground : theme.mutedColor.withAlphaComponent(theme.mutedColor.alphaComponent * 0.75)
            color.setFill()
            tri.fill()
        }
        para.enumerateAttribute(.floHeadingHash, in: NSRange(location: 0, length: para.length)) { v, range, _ in
            guard let visible = v as? Bool, visible, let origin = self.charOrigin(range.location, origin: point) else { return }
            let text = (para.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
            // hash inherits the heading's font size (font-size: inherit !important)
            let headingFont = self.headingFont(para, theme: theme)
            let opacity = (para.attribute(.floOpacity, at: range.location, effectiveRange: nil) as? Double) ?? 1
            let attrs: [NSAttributedString.Key: Any] = [
                .font: headingFont,
                .foregroundColor: theme.mutedColor.withAlphaComponent(theme.mutedColor.alphaComponent * CGFloat(opacity)),
            ]
            // The margin span holds "# " (mark + space) and ends ~0.25em before
            // the heading text (measured in WebKit: `# H` at 28.8px → # at 300.6,
            // space to 325.8, text at 333).
            let full = (para.string as NSString).substring(with: range)
            let boxW = NSAttributedString(string: full, attributes: attrs).size().width
            let s = NSAttributedString(string: text, attributes: attrs)
            s.draw(at: CGPoint(x: origin.x - 0.251 * headingFont.pointSize - boxW, y: origin.textTop(font: headingFont)))
        }
    }

    private func headingFont(_ para: NSAttributedString, theme: EditorTheme) -> NSFont {
        var best: NSFont = theme.font(size: theme.baseSize, weight: 600, mono: false)
        para.enumerateAttribute(.font, in: NSRange(location: 0, length: para.length)) { v, _, _ in
            if let f = v as? NSFont, f.pointSize > best.pointSize { best = f }
        }
        return best
    }

    private func paragraphStyle(_ para: NSAttributedString) -> NSParagraphStyle? {
        para.length > 0 ? para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
    }

    /// Top-left of the line fragment containing char `index`, and its x.
    func charOrigin(_ index: Int, origin: CGPoint) -> CharPos? {
        for lf in textLineFragments {
            let r = lf.characterRange
            if index >= r.location && index <= r.location + r.length {
                let p = lf.locationForCharacter(at: index)
                return CharPos(x: origin.x + lf.typographicBounds.minX + p.x,
                               lineTop: origin.y + lf.typographicBounds.minY,
                               lineHeight: lf.typographicBounds.height,
                               baseline: origin.y + lf.typographicBounds.minY + lf.glyphOrigin.y)
            }
        }
        return nil
    }

    /// Where char i's glyph really starts: TextKit reports the position after a
    /// kerned char half-way into the kern (the glyphs are drawn at the full kern).
    func glyphX(_ lf: NSTextLineFragment, _ i: Int) -> CGFloat {
        var x = lf.locationForCharacter(at: i).x
        if i > lf.characterRange.location, let p = paragraph, i - 1 < p.length,
           let k = p.attribute(.kern, at: i - 1, effectiveRange: nil) as? CGFloat, k != 0 {
            x += k / 2
        }
        return x
    }

    func rects(for range: NSRange, origin: CGPoint) -> [CGRect] {
        var out: [CGRect] = []
        for lf in textLineFragments {
            let r = lf.characterRange
            let a = max(range.location, r.location), b = min(range.location + range.length, r.location + r.length)
            guard a < b else { continue }
            let x0 = glyphX(lf, a), x1 = glyphX(lf, b)
            let top = origin.y + lf.typographicBounds.minY
            // the range's real font (hidden marks carry a tiny one)
            var font = NSFont.systemFont(ofSize: 18)
            var best: CGFloat = 0
            paragraph?.enumerateAttribute(.font, in: NSRange(location: a, length: b - a)) { v, _, _ in
                if let f = v as? NSFont, f.pointSize > best { best = f.pointSize; font = f }
            }
            // CSS inline box: content area = ascender-descender, centred in the line
            let contentH = font.ascender - font.descender
            let y = top + (lf.typographicBounds.height - contentH) / 2
            out.append(CGRect(x: origin.x + lf.typographicBounds.minX + x0, y: y, width: x1 - x0, height: contentH))
        }
        return out
    }

    private func fillRounded(_ r: CGRect, radius: CGFloat, top: Bool, bottom: Bool, color: NSColor) {
        color.setFill()
        let path = NSBezierPath()
        let tl = top ? radius : 0, bl = bottom ? radius : 0
        path.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        path.line(to: CGPoint(x: r.maxX - tl, y: r.minY))
        if tl > 0 { path.appendArc(withCenter: CGPoint(x: r.maxX - tl, y: r.minY + tl), radius: tl, startAngle: 270, endAngle: 360) }
        path.line(to: CGPoint(x: r.maxX, y: r.maxY - bl))
        if bl > 0 { path.appendArc(withCenter: CGPoint(x: r.maxX - bl, y: r.maxY - bl), radius: bl, startAngle: 0, endAngle: 90) }
        path.line(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { path.appendArc(withCenter: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: 90, endAngle: 180) }
        path.line(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { path.appendArc(withCenter: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: 180, endAngle: 270) }
        path.close()
        path.fill()
    }

    static let bulletLift: CGFloat = 1.5

    private func drawWidget(_ box: WidgetBox, at p: CharPos, lineLeft: CGFloat, theme: EditorTheme, trailingX: CGFloat? = nil) {
        let font = theme.font(size: theme.baseSize, weight: 400, mono: false)
        let unit = RenderPlanner.listUnitCh * theme.ch
        switch box.widget.kind {
        case .bullet:
            // "•" centred in a 3ch column at the marker offset, muted
            let s = NSAttributedString(string: "\u{2022}", attributes: [.font: font, .foregroundColor: theme.mutedColor])
            let w = s.size().width
            let x = lineLeft + box.width + (unit - w) / 2
            // raised 1.5pt: at the plain text position the dot sat ~1.25pt below the x-height centre
            s.draw(at: CGPoint(x: x, y: p.textTop(font: font) - Self.bulletLift))
        case .checkbox(_, let checked):
            // 18x18, 1.5px border, radius 5, left at markerOffset + (3ch - 28px)/2, v-centred
            let x = lineLeft + box.width + (unit - 28) / 2
            let rect = CGRect(x: x, y: p.lineTop + (p.lineHeight - 18) / 2, width: 18, height: 18)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            path.lineWidth = 1.5
            if checked {
                theme.accent.setFill(); theme.accent.setStroke()
                path.fill(); path.stroke()
                let check = NSBezierPath()
                // SVG path M8 12.5L10.5 15L16 9 in a 24 box drawn at 20px centred
                let s: CGFloat = 20 / 24, ox = rect.midX - 10, oy = rect.midY - 10
                check.move(to: CGPoint(x: ox + 8 * s, y: oy + 12.5 * s))
                check.line(to: CGPoint(x: ox + 10.5 * s, y: oy + 15 * s))
                check.line(to: CGPoint(x: ox + 16 * s, y: oy + 9 * s))
                check.lineWidth = 3 * s
                check.lineCapStyle = .round; check.lineJoinStyle = .round
                NSColor.white.setStroke(); check.stroke()
            } else {
                theme.mutedColor.setStroke(); path.stroke()
            }
        case .emoji(let e):
            let ef = theme.emojiFont(size: font.pointSize)
            let s = NSAttributedString(string: e, attributes: [.font: ef, .foregroundColor: theme.textColor])
            s.draw(at: CGPoint(x: p.x, y: p.cssBaseline(font: font) - ef.ascender))
        case .dash(let e):
            let s = NSAttributedString(string: e, attributes: [.font: font, .foregroundColor: theme.textColor])
            s.draw(at: CGPoint(x: p.x, y: p.cssBaseline(font: font) - font.ascender))
        case .wikiLink(let display, let image):
            if !image {
                let s = NSAttributedString(string: display, attributes: [.font: font, .foregroundColor: theme.accent])
                s.draw(at: CGPoint(x: p.x, y: p.textTop(font: font)))
            }
        case .image, .wikiLink(_, true):
            if let text = box.placeholder {
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: theme.mutedColor])
                s.draw(at: CGPoint(x: p.x, y: p.textTop(font: font)))
                return
            }
            guard let img = box.image?.image else { return }
            var x = p.x
            if case .image(_, _, _, true) = box.widget.kind { x = lineLeft + 6 }
            else if box.trailing, let after = trailingX { x = after - box.width }
            let rect = CGRect(x: x, y: p.lineTop + box.yOffset, width: box.size.width, height: box.size.height)
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
        case .math(_, let display):
            guard let m = box.math else { return }
            let rect: CGRect
            if display {
                rect = CGRect(x: lineLeft, y: p.lineTop, width: m.width, height: m.lineHeight)
            } else {
                rect = CGRect(x: p.x - m.pad, y: p.lineTop + box.yOffset - m.pad, width: m.width + 2 * m.pad, height: m.lineHeight + 2 * m.pad)
            }
            m.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high.rawValue])
        case .htmlBlock:
            guard let r = box.html, let img = r.image else { return }
            img.draw(in: CGRect(x: lineLeft, y: p.lineTop, width: box.width, height: r.height), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        case .mermaid:
            editor.map { e in MainActor.assumeIsolated { e.mermaidOverlay?.scheduleSync() } }
            let rect = CGRect(x: lineLeft, y: p.lineTop + MermaidRenderer.widgetPadding, width: box.width, height: MermaidRenderer.canvasHeight)
            if let img = box.mermaid {
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                theme.foreground.withAlphaComponent(theme.contrast * 0.24).setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
                path.lineWidth = 1; path.stroke()
            }
        case .table:
            guard let t = box.table, let ctx = NSGraphicsContext.current?.cgContext else { return }
            t.draw(at: CGPoint(x: lineLeft, y: p.lineTop + t.tableTop), theme: theme, in: ctx)
        case .horizontalRule:
            let y = p.lineTop + p.lineHeight / 2
            theme.foreground.withAlphaComponent(0.2).setFill()
            NSBezierPath(rect: CGRect(x: lineLeft + 6, y: y, width: containerWidth - editorGutter - 8, height: 1)).fill()
        default:
            break
        }
    }

    private var editorGutter: CGFloat { editor?.applier.gutter ?? 0 }
    private var containerWidth: CGFloat { textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX }
}

struct CharPos {
    var x: CGFloat
    var lineTop: CGFloat
    var lineHeight: CGFloat
    var baseline: CGFloat
    /// The line's text baseline as Chrome places it: floored half-leading
    /// around round(ascent) + round(descent).
    func cssBaseline(font: NSFont) -> CGFloat {
        let a = font.ascender.rounded(), d = (-font.descender).rounded()
        return lineTop + ((lineHeight - (a + d)) / 2).rounded(.down) + a
    }
    /// y at which to draw a string in `font` so its box is centred in the line (CSS).
    func textTop(font: NSFont) -> CGFloat {
        let contentH = font.ascender - font.descender
        return lineTop + (lineHeight - contentH) / 2
    }
}

extension CGFloat {
    func baselineTop(font: NSFont, lineOrigin: CharPos) -> CGFloat { lineOrigin.textTop(font: font) }
}

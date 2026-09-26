import Foundation

// Inline parsing: port of lezer's InlineContext, default inline parsers and
// delimiter resolution, plus GFM (Strikethrough, Autolink) and the Flo State
// inline extensions, in the configured order:
// EscapeMark, Math, Escape, Entity, InlineCode, HTMLTag, Emoji, Dash, Emphasis,
// Strikethrough, HardBreak, NestedLinkAsPlainText, Link, Image, Autolink,
// SpaceDestinationLinkEnd, LinkEnd

enum MDDelimType {
    case emphasisUnderscore, emphasisAsterisk, linkStart, imageStart, strikethrough, emoji

    var resolve: Int? {
        switch self {
        case .emphasisUnderscore, .emphasisAsterisk: return MDType.Emphasis
        case .strikethrough: return MDType.Strikethrough
        case .emoji: return MDType.Emoji
        default: return nil
        }
    }

    var mark: Int? {
        switch self {
        case .emphasisUnderscore, .emphasisAsterisk: return MDType.EmphasisMark
        case .strikethrough: return MDType.StrikethroughMark
        case .emoji: return MDType.EmojiMark
        default: return nil
        }
    }
}

let mdMarkOpen = 1, mdMarkClose = 2

final class MDDelim {
    let type: MDDelimType
    let from: Int
    let to: Int
    var side: Int
    init(_ type: MDDelimType, _ from: Int, _ to: Int, _ side: Int) {
        self.type = type
        self.from = from
        self.to = to
        self.side = side
    }
}

enum MDPart {
    case elt(MDElt)
    case delim(MDDelim)
}

final class MDInlineContext {
    var parts: [MDPart?] = []
    let text: MDText
    let offset: Int
    let end: Int

    init(_ text: MDText, _ offset: Int) {
        self.text = text
        self.offset = offset
        self.end = offset + text.count
    }

    @inline(__always) func char(_ pos: Int) -> Int {
        let i = pos - offset
        return (pos >= end || i < 0) ? -1 : Int(text[i])
    }

    @inline(__always) func append(_ e: MDElt) -> Int { parts.append(.elt(e)); return e.to }
    @inline(__always) func append(_ d: MDDelim) -> Int { parts.append(.delim(d)); return d.to }

    func addDelimiter(_ type: MDDelimType, _ from: Int, _ to: Int, _ open: Bool, _ close: Bool) -> Int {
        append(MDDelim(type, from, to, (open ? mdMarkOpen : 0) | (close ? mdMarkClose : 0)))
    }

    var hasOpenLink: Bool {
        var i = parts.count - 1
        while i >= 0 {
            if case .delim(let d)? = parts[i], d.type == .linkStart || d.type == .imageStart { return true }
            i -= 1
        }
        return false
    }

    func resolveMarkers(_ from: Int) -> [MDElt] {
        var i = from
        while i < parts.count {
            defer { i += 1 }
            guard case .delim(let close)? = parts[i], close.type.resolve != nil, close.side & mdMarkClose != 0 else { continue }
            let emp = close.type == .emphasisUnderscore || close.type == .emphasisAsterisk
            let closeSize = close.to - close.from
            var open: MDDelim? = nil
            var j = i - 1
            while j >= from {
                if case .delim(let part)? = parts[j], part.side & mdMarkOpen != 0, part.type == close.type,
                   !(emp && ((close.side & mdMarkOpen != 0) || (part.side & mdMarkClose != 0)) &&
                       (part.to - part.from + closeSize) % 3 == 0 && ((part.to - part.from) % 3 != 0 || closeSize % 3 != 0)) {
                    open = part
                    break
                }
                j -= 1
            }
            guard let op = open else { continue }

            var type = close.type.resolve!
            var content: [MDElt] = []
            var start = op.from, end = close.to
            if emp {
                let size = min(2, op.to - op.from, closeSize)
                start = op.to - size
                end = close.from + size
                type = size == 1 ? MDType.Emphasis : MDType.StrongEmphasis
            }
            if let m = op.type.mark { content.append(MDElt(m, start, op.to)) }
            var k = j + 1
            while k < i {
                if case .elt(let e)? = parts[k] { content.append(e) }
                parts[k] = nil
                k += 1
            }
            if let m = close.type.mark { content.append(MDElt(m, close.from, end)) }
            let element = MDElt(type, start, end, content)
            parts[j] = emp && op.from != start ? .delim(MDDelim(op.type, op.from, start, op.side)) : nil
            let keep: MDDelim? = emp && close.to != end ? MDDelim(close.type, end, close.to, close.side) : nil
            if let keep = keep {
                parts[i] = .delim(keep)
                parts.insert(.elt(element), at: i)
            } else {
                parts[i] = .elt(element)
            }
        }
        var result: [MDElt] = []
        var q = from
        while q < parts.count {
            if case .elt(let e)? = parts[q] { result.append(e) }
            q += 1
        }
        return result
    }

    func findOpeningDelimiter(_ type: MDDelimType) -> Int? {
        var i = parts.count - 1
        while i >= 0 {
            if case .delim(let d)? = parts[i], d.type == type, d.side & mdMarkOpen != 0 { return i }
            i -= 1
        }
        return nil
    }

    func takeContent(_ startIndex: Int) -> [MDElt] {
        let content = resolveMarkers(startIndex)
        parts.removeSubrange(startIndex...)
        return content
    }

    func getDelimiterAt(_ index: Int) -> MDDelim? {
        if case .delim(let d)? = parts[index] { return d }
        return nil
    }

    func skipSpace(_ from: Int) -> Int { mdSkipSpace(text, from - offset) + offset }
}

// Configured inline parser order:
// EscapeMark, Math, Escape, Entity, InlineCode, HTMLTag, Emoji, Dash, Emphasis, Strikethrough,
// HardBreak, NestedLinkAsPlainText, Link, Image, Autolink, SpaceDestinationLinkEnd, LinkEnd.
// Every parser bails out immediately unless the current character is its trigger, so we
// dispatch on the character and only call the parsers that could match, in that order.
func mdParseInline(_ text: MDText, _ offset: Int) -> [MDElt] {
    let cx = MDInlineContext(text, offset)
    var pos = offset
    while pos < cx.end {
        let next = cx.char(pos)
        var r = -1
        switch next {
        case 92: // '\\' — EscapeMark always matches (Escape/HardBreak are shadowed)
            r = inlineEscapeMark(cx, next, pos)
        case 36: r = inlineMath(cx, next, pos)
        case 38: r = inlineEntity(cx, next, pos)
        case 96: r = inlineInlineCode(cx, next, pos)
        case 60: r = inlineHTMLTag(cx, next, pos)
        case 58: r = inlineEmoji(cx, next, pos)
        case 45:
            r = inlineDash(cx, next, pos)
            if r < 0 { r = inlineAutolink(cx, next, pos) }
        case 42, 95: r = inlineEmphasis(cx, next, pos)
        case 126: r = inlineStrikethrough(cx, next, pos)
        case 32: r = inlineHardBreak(cx, next, pos)
        case 91:
            r = inlineNestedLinkAsPlainText(cx, next, pos)
            if r < 0 { r = inlineLink(cx, next, pos) }
        case 33: r = inlineImage(cx, next, pos)
        case 93:
            r = inlineSpaceDestinationLinkEnd(cx, next, pos)
            if r < 0 { r = inlineLinkEnd(cx, next, pos) }
        default:
            if jsWord(next) || next == 46 || next == 43 { r = inlineAutolink(cx, next, pos) }
        }
        pos = r >= 0 ? r : pos + 1
    }
    return cx.resolveMarkers(0)
}

// MARK: - Default inline parsers

private func inlineEntity(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    if next != 38 { return -1 }
    // /^(?:#\d+|#x[a-f\d]+|\w+);/i on slice(start + 1, start + 31)
    let limit = min(cx.end, start + 31)
    @inline(__always) func c(_ p: Int) -> Int { p < limit ? cx.char(p) : -1 }
    let s = start + 1
    var len = -1
    if c(s) == 35 {
        var p = s + 1
        while isAsciiDigit(c(p)) { p += 1 }
        if p > s + 1 && c(p) == 59 { len = p + 1 - s }
        if len < 0 && (c(s + 1) == 120 || c(s + 1) == 88) {
            p = s + 2
            while true {
                let d = asciiLower(c(p))
                if isAsciiDigit(d) || (d >= 97 && d <= 102) { p += 1 } else { break }
            }
            if p > s + 2 && c(p) == 59 { len = p + 1 - s }
        }
    } else {
        var p = s
        while jsWord(c(p)) { p += 1 }
        if p > s && c(p) == 59 { len = p + 1 - s }
    }
    return len > 0 ? cx.append(MDElt(MDType.Entity, start, start + 1 + len)) : -1
}

private func inlineInlineCode(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    if next != 96 || (start != 0 && cx.char(start - 1) == 96) { return -1 }
    var pos = start + 1
    while pos < cx.end && cx.char(pos) == 96 { pos += 1 }
    let size = pos - start
    var curSize = 0
    while pos < cx.end {
        if cx.char(pos) == 96 {
            curSize += 1
            if curSize == size && cx.char(pos + 1) != 96 {
                return cx.append(MDElt(MDType.InlineCode, start, pos + 1, [
                    MDElt(MDType.CodeMark, start, start + size),
                    MDElt(MDType.CodeMark, pos + 1 - size, pos + 1),
                ]))
            }
        } else {
            curSize = 0
        }
        pos += 1
    }
    return -1
}

private func isEmailLocalChar(_ c: Int) -> Bool {
    if isAsciiAlnum(c) { return true }
    switch c {
    case 46, 33, 35, 36, 37, 38, 39, 42, 43, 47, 61, 63, 94, 95, 96, 123, 124, 125, 126, 45: return true
    default: return false
    }
}

/// Returns the length of the HTMLTag/autolink match of the text after '<' (index `s` in `t`).
private enum HTMLTagMatch { case autolink(Int), comment(Int), procInst(Int), tag(Int) }

private func matchHTMLTag(_ t: MDText, _ s: Int) -> HTMLTagMatch? {
    let n = t.count
    // URL autolink: [a-z][-\w+.]+:[^\s>]+>
    if isAsciiAlpha(mdCh(t, s)) {
        var j = s + 1
        while j < n && (jsWord(Int(t[j])) || t[j] == 45 || t[j] == 43 || t[j] == 46) { j += 1 }
        if j > s + 1 && mdCh(t, j) == 58 {
            var k = j + 1
            while k < n && !jsSpace(Int(t[k])) && t[k] != 62 { k += 1 }
            if k > j + 1 && mdCh(t, k) == 62 { return .autolink(k + 1 - s) }
        }
    }
    // Email autolink
    do {
        var i = s
        while i < n && isEmailLocalChar(Int(t[i])) { i += 1 }
        if i > s && mdCh(t, i) == 64 {
            i += 1
            labels: while true {
                guard isAsciiAlnum(mdCh(t, i)) else { break labels }
                var r = i
                while r < n && (isAsciiAlnum(Int(t[r])) || t[r] == 45) { r += 1 }
                if r - i > 63 || !isAsciiAlnum(Int(t[r - 1])) { break labels }
                let c = mdCh(t, r)
                if c == 46 { i = r + 1; continue }
                if c == 62 { return .autolink(r + 1 - s) }
                break labels
            }
        }
    }
    // Comment: !--[^>](?:-[^-]|[^-])*?-->
    if mdStarts(t, s, "!--") && s + 3 < n && t[s + 3] != 62 {
        var p = s + 4
        while true {
            if mdStarts(t, p, "-->") { return .comment(p + 3 - s) }
            if p >= n { break }
            if t[p] == 45 {
                if p + 1 < n && t[p + 1] != 45 { p += 2 } else { break }
            } else {
                p += 1
            }
        }
    }
    // Processing instruction: \?[^]*?\?>
    if mdCh(t, s) == 63 {
        var q = s + 1
        while q + 1 < n {
            if t[q] == 63 && t[q + 1] == 62 { return .procInst(q + 2 - s) }
            q += 1
        }
    }
    // Tags
    let c0 = mdCh(t, s)
    if c0 == 33 {
        let c1 = mdCh(t, s + 1)
        if c1 >= 65 && c1 <= 90 {
            var q = s + 2
            while q < n && t[q] != 62 { q += 1 }
            if q < n { return .tag(q + 1 - s) }
        }
        if mdStarts(t, s, "![CDATA[") {
            var q = s + 8
            while q + 2 < n {
                if t[q] == 93 && t[q + 1] == 93 && t[q + 2] == 62 { return .tag(q + 3 - s) }
                q += 1
            }
        }
        return nil
    }
    if c0 == 47 {
        var p = jsSkipSpace(t, s + 1)
        guard isAsciiAlpha(mdCh(t, p)) else { return nil }
        p += 1
        while p < n && (jsWord(Int(t[p])) || t[p] == 45) { p += 1 }
        p = jsSkipSpace(t, p)
        return mdCh(t, p) == 62 ? .tag(p + 1 - s) : nil
    }
    let p = jsSkipSpace(t, s)
    if let e = mdMatchOpenTag(t, p, attrColon: true, allowSlash: true) { return .tag(e - s) }
    return nil
}

private func inlineHTMLTag(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    if next != 60 || start == cx.end - 1 { return -1 }
    let s = start + 1 - cx.offset
    guard let m = matchHTMLTag(cx.text, s) else { return -1 }
    switch m {
    case .autolink(let len):
        return cx.append(MDElt(MDType.Autolink, start, start + 1 + len, [
            MDElt(MDType.LinkMark, start, start + 1),
            MDElt(MDType.URL, start + 1, start + len),
            MDElt(MDType.LinkMark, start + len, start + 1 + len),
        ]))
    case .comment(let len): return cx.append(MDElt(MDType.Comment, start, start + 1 + len))
    case .procInst(let len): return cx.append(MDElt(MDType.ProcessingInstruction, start, start + 1 + len))
    case .tag(let len): return cx.append(MDElt(MDType.HTMLTag, start, start + 1 + len))
    }
}

@inline(__always) private func flank(_ before: Int, _ after: Int) -> (Bool, Bool, Bool, Bool) {
    // (pBefore, pAfter, sBefore, sAfter) with -1 meaning empty string
    (mdPunctuation(before), mdPunctuation(after), before < 0 || jsSpace(before), after < 0 || jsSpace(after))
}

private func inlineEmphasis(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    if next != 95 && next != 42 { return -1 }
    var pos = start + 1
    while cx.char(pos) == next { pos += 1 }
    let before = cx.char(start - 1), after = cx.char(pos)
    let (pBefore, pAfter, sBefore, sAfter) = flank(before, after)
    let leftFlanking = !sAfter && (!pAfter || sBefore || pBefore)
    let rightFlanking = !sBefore && (!pBefore || sAfter || pAfter)
    let canOpen = leftFlanking && (next == 42 || !rightFlanking || pBefore)
    let canClose = rightFlanking && (next == 42 || !leftFlanking || pAfter)
    return cx.append(MDDelim(next == 95 ? .emphasisUnderscore : .emphasisAsterisk, start, pos,
                             (canOpen ? mdMarkOpen : 0) | (canClose ? mdMarkClose : 0)))
}

private func inlineHardBreak(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    if next == 92 && cx.char(start + 1) == 10 {
        return cx.append(MDElt(MDType.HardBreak, start, start + 2))
    }
    if next == 32 {
        var pos = start + 1
        while cx.char(pos) == 32 { pos += 1 }
        if cx.char(pos) == 10 && pos >= start + 2 {
            return cx.append(MDElt(MDType.HardBreak, start, pos + 1))
        }
    }
    return -1
}

private func inlineLink(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    next == 91 ? cx.append(MDDelim(.linkStart, start, start + 1, mdMarkOpen)) : -1
}

private func inlineImage(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    next == 33 && cx.char(start + 1) == 91 ? cx.append(MDDelim(.imageStart, start, start + 2, mdMarkOpen)) : -1
}

private func inlineLinkEnd(_ cx: MDInlineContext, _ next: Int, _ start: Int) -> Int {
    if next != 93 { return -1 }
    var i = cx.parts.count - 1
    while i >= 0 {
        if case .delim(let part)? = cx.parts[i], part.type == .linkStart || part.type == .imageStart {
            let nc = cx.char(start + 1)
            if part.side == 0 || (cx.skipSpace(part.to) == start && !(nc == 40 || nc == 91)) {
                cx.parts[i] = nil
                return -1
            }
            let content = cx.takeContent(i)
            let link = mdFinishLink(cx, content, part.type == .linkStart ? MDType.Link : MDType.Image, part.from, start + 1)
            cx.parts.append(.elt(link))
            if part.type == .linkStart {
                for j in 0..<i {
                    if case .delim(let p)? = cx.parts[j], p.type == .linkStart { p.side = 0 }
                }
            }
            return link.to
        }
        i -= 1
    }
    return -1
}

func mdFinishLink(_ cx: MDInlineContext, _ contentIn: [MDElt], _ type: Int, _ start: Int, _ startPos: Int) -> MDElt {
    let text = cx.text
    let next = cx.char(startPos)
    var endPos = startPos
    var content = contentIn
    content.insert(MDElt(MDType.LinkMark, start, start + (type == MDType.Image ? 2 : 1)), at: 0)
    content.append(MDElt(MDType.LinkMark, startPos - 1, startPos))
    if next == 40 {
        var pos = cx.skipSpace(startPos + 1)
        let dest = mdParseURL(text, pos - cx.offset, cx.offset)
        var title: MDParsed = .null
        if let d = dest.elt {
            pos = cx.skipSpace(d.to)
            if pos != d.to {
                title = mdParseLinkTitle(text, pos - cx.offset, cx.offset)
                if let t = title.elt { pos = cx.skipSpace(t.to) }
            }
        }
        if cx.char(pos) == 41 {
            content.append(MDElt(MDType.LinkMark, startPos, startPos + 1))
            endPos = pos + 1
            if let d = dest.elt { content.append(d) }
            if let t = title.elt { content.append(t) }
            content.append(MDElt(MDType.LinkMark, pos, endPos))
        }
    } else if next == 91 {
        if let label = mdParseLinkLabel(text, startPos - cx.offset, cx.offset, false).elt {
            content.append(label)
            endPos = label.to
        }
    }
    return MDElt(type, start, endPos, content)
}

func mdParseURL(_ text: MDText, _ start: Int, _ offset: Int) -> MDParsed {
    let next = mdCh(text, start)
    if next == 60 {
        var pos = start + 1
        while pos < text.count {
            let ch = text[pos]
            if ch == 62 { return .elt(MDElt(MDType.URL, start + offset, pos + 1 + offset)) }
            if ch == 60 || ch == 10 { return .fail }
            pos += 1
        }
        return .null
    } else {
        var depth = 0, pos = start, escaped = false
        while pos < text.count {
            let ch = Int(text[pos])
            if mdSpace(ch) {
                break
            } else if escaped {
                escaped = false
            } else if ch == 40 {
                depth += 1
            } else if ch == 41 {
                if depth == 0 { break }
                depth -= 1
            } else if ch == 92 {
                escaped = true
            }
            pos += 1
        }
        return pos > start ? .elt(MDElt(MDType.URL, start + offset, pos + offset)) : pos == text.count ? .null : .fail
    }
}

func mdParseLinkTitle(_ text: MDText, _ start: Int, _ offset: Int) -> MDParsed {
    let next = mdCh(text, start)
    if next != 39 && next != 34 && next != 40 { return .fail }
    let end = next == 40 ? 41 : next
    var pos = start + 1, escaped = false
    while pos < text.count {
        let ch = Int(text[pos])
        if escaped { escaped = false } else if ch == end {
            return .elt(MDElt(MDType.LinkTitle, start + offset, pos + 1 + offset))
        } else if ch == 92 { escaped = true }
        pos += 1
    }
    return .null
}

func mdParseLinkLabel(_ text: MDText, _ start: Int, _ offset: Int, _ requireNonWSIn: Bool) -> MDParsed {
    var requireNonWS = requireNonWSIn
    var escaped = false
    var pos = start + 1
    let end = min(text.count, pos + 999)
    while pos < end {
        let ch = Int(text[pos])
        if escaped { escaped = false } else if ch == 93 {
            return requireNonWS ? .fail : .elt(MDElt(MDType.LinkLabel, start + offset, pos + 1 + offset))
        } else {
            if requireNonWS && !mdSpace(ch) { requireNonWS = false }
            if ch == 91 { return .fail } else if ch == 92 { escaped = true }
        }
        pos += 1
    }
    return .null
}

// MARK: - GFM inline extensions

private func inlineStrikethrough(_ cx: MDInlineContext, _ next: Int, _ pos: Int) -> Int {
    if next != 126 || cx.char(pos + 1) != 126 || cx.char(pos + 2) == 126 { return -1 }
    let before = cx.char(pos - 1), after = cx.char(pos + 2)
    let (pBefore, pAfter, sBefore, sAfter) = flank(before, after)
    return cx.addDelimiter(.strikethrough, pos, pos + 2,
                           !sAfter && (!pAfter || sBefore || pBefore),
                           !sBefore && (!pBefore || sAfter || pAfter))
}

@inline(__always) private func isWordDash(_ c: Int) -> Bool { jsWord(c) || c == 45 }

private func autolinkURLEnd(_ t: MDText, _ from: Int) -> Int {
    let n = t.count
    // /[\w-]+(\.[\w-]+)+(\/[^\s<]*)?/y
    var j = from
    while j < n && isWordDash(Int(t[j])) { j += 1 }
    if j == from { return -1 }
    var segStarts = [from]
    while j + 1 < n && t[j] == 46 && isWordDash(Int(t[j + 1])) {
        j += 1
        segStarts.append(j)
        while j < n && isWordDash(Int(t[j])) { j += 1 }
    }
    if segStarts.count < 2 { return -1 }
    let domainEnd = j
    if j < n && t[j] == 47 {
        j += 1
        while j < n && !jsSpace(Int(t[j])) && t[j] != 60 { j += 1 }
    }
    // lastTwoDomainWords must not contain '_'
    for k in segStarts[segStarts.count - 2]..<domainEnd where t[k] == 95 { return -1 }
    var end = j
    while true {
        let last = Int(t[end - 1])
        if last == 63 || last == 33 || last == 46 || last == 44 || last == 58 || last == 42 || last == 95 || last == 126 {
            end -= 1
        } else if last == 41 && countChar(t, from, end, 41) > countChar(t, from, end, 40) {
            end -= 1
        } else if last == 59, let amp = entityBeforeSemicolon(t, from, end) {
            end = amp
        } else {
            break
        }
    }
    return end
}

private func countChar(_ t: MDText, _ from: Int, _ to: Int, _ ch: UInt16) -> Int {
    var r = 0
    if to <= from { return 0 }
    for i in from..<to where t[i] == ch { r += 1 }
    return r
}

/// /&(?:#\d+|#x[a-f\d]+|\w+);$/ on t[from..<end] — returns the index of '&'.
private func entityBeforeSemicolon(_ t: MDText, _ from: Int, _ end: Int) -> Int? {
    var a = end - 2
    while a >= from && t[a] != 38 { a -= 1 }
    if a < from { return nil }
    let s = a + 1, e = end - 1 // content in [s, e)
    if s >= e { return nil }
    func all(_ from: Int, _ f: (Int) -> Bool) -> Bool {
        if from >= e { return false }
        for k in from..<e where !f(Int(t[k])) { return false }
        return true
    }
    if t[s] == 35 {
        if all(s + 1, isAsciiDigit) { return a }
        if s + 1 < e && t[s + 1] == 120 && all(s + 2, { isAsciiDigit($0) || ($0 >= 97 && $0 <= 102) }) { return a }
        return nil
    }
    return all(s, jsWord) ? a : nil
}

@inline(__always) private func isEmailChar(_ c: Int) -> Bool { jsWord(c) || c == 46 || c == 43 || c == 45 }

private func autolinkEmailEnd(_ t: MDText, _ from: Int) -> Int {
    let n = t.count
    // /[\w.+-]+@[\w-]+(\.[\w.-]+)+/y
    var i = from
    while i < n && isEmailChar(Int(t[i])) { i += 1 }
    if i == from || i >= n || t[i] != 64 { return -1 }
    i += 1
    var j = i
    while j < n && isWordDash(Int(t[j])) { j += 1 }
    if j == i { return -1 }
    func wdd(_ c: Int) -> Bool { jsWord(c) || c == 46 || c == 45 }
    if !(j + 1 < n && t[j] == 46 && wdd(Int(t[j + 1]))) { return -1 }
    j += 1
    while j < n && wdd(Int(t[j])) { j += 1 }
    let last = t[j - 1]
    return last == 95 || last == 45 ? -1 : j - (last == 46 ? 1 : 0)
}

private func inlineAutolink(_ cx: MDInlineContext, _ next: Int, _ absPos: Int) -> Int {
    let t = cx.text, n = t.count
    let pos = absPos - cx.offset
    if pos > 0 && jsWord(Int(t[pos - 1])) { return -1 }
    // /(www\.)|(https?:\/\/)|([\w.+-]{1,100}@)|(mailto:|xmpp:)/y
    var kind = 0, mlen = 0
    if mdStarts(t, pos, "www.") { kind = 1; mlen = 4 }
    else if mdStarts(t, pos, "http://") { kind = 2; mlen = 7 }
    else if mdStarts(t, pos, "https://") { kind = 2; mlen = 8 }
    else {
        var r = pos
        while r < n && isEmailChar(Int(t[r])) { r += 1 }
        if r > pos && r - pos <= 100 && r < n && t[r] == 64 { kind = 3; mlen = r + 1 - pos }
        else if mdStarts(t, pos, "mailto:") { kind = 4; mlen = 7 }
        else if mdStarts(t, pos, "xmpp:") { kind = 5; mlen = 5 }
    }
    if kind == 0 { return -1 }
    var end = -1
    if kind <= 2 {
        end = autolinkURLEnd(t, pos + mlen)
        if end > -1 && cx.hasOpenLink {
            // /([^\[\]]|\[[^\]]*\])*/
            var p = pos
            while p < end {
                if t[p] == 93 { break }
                if t[p] == 91 {
                    var q = p + 1
                    while q < end && t[q] != 93 { q += 1 }
                    if q < end { p = q + 1 } else { break }
                } else {
                    p += 1
                }
            }
            end = p
        }
    } else if kind == 3 {
        end = autolinkEmailEnd(t, pos)
    } else {
        end = autolinkEmailEnd(t, pos + mlen)
        if end > -1 && kind == 5 {
            // /\/[a-zA-Z\d@.]+/y
            if mdCh(t, end) == 47 {
                var q = end + 1
                while q < n && (isAsciiAlnum(Int(t[q])) || t[q] == 64 || t[q] == 46) { q += 1 }
                if q > end + 1 { end = q }
            }
        }
    }
    if end < 0 { return -1 }
    _ = cx.append(MDElt(MDType.URL, absPos, end + cx.offset))
    return end + cx.offset
}

// MARK: - Flo State inline extensions

/// escapeMarkdownSyntaxExtension: any backslash starts an Escape with an EscapeMark.
private func inlineEscapeMark(_ cx: MDInlineContext, _ next: Int, _ pos: Int) -> Int {
    if next != 92 { return -1 }
    return cx.append(MDElt(MDType.Escape, pos, pos + 2, [MDElt(MDType.EscapeMark, pos, pos + 1)]))
}

private func isEscapedDollar(_ cx: MDInlineContext, _ pos: Int) -> Bool {
    var backslashes = 0
    var p = pos - 1
    while p >= cx.offset {
        if cx.char(p) != 92 { break }
        backslashes += 1
        p -= 1
    }
    return backslashes % 2 == 1
}

@inline(__always) private func mathWS(_ c: Int) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

private func inlineMath(_ cx: MDInlineContext, _ next: Int, _ pos: Int) -> Int {
    if next != 36 { return -1 }
    if isEscapedDollar(cx, pos) { return -1 }
    let display = pos + 1 < cx.end && cx.char(pos + 1) == 36
    let contentFrom = display ? pos + 2 : pos + 1
    if !display {
        if contentFrom >= cx.end { return -1 }
        if mathWS(cx.char(contentFrom)) { return -1 }
    }
    var closePos = -1
    if display {
        var p = contentFrom
        while p < cx.end - 1 {
            if cx.char(p) == 36 && cx.char(p + 1) == 36 && !isEscapedDollar(cx, p) { closePos = p; break }
            p += 1
        }
    } else {
        var p = contentFrom
        while p < cx.end {
            defer { p += 1 }
            if cx.char(p) != 36 { continue }
            if isEscapedDollar(cx, p) { continue }
            if p > contentFrom && mathWS(cx.char(p - 1)) { continue }
            if p + 1 < cx.end && isAsciiDigit(cx.char(p + 1)) { continue }
            closePos = p
            break
        }
    }
    if closePos < 0 { return -1 }
    let contentTo = closePos
    let outerTo = display ? closePos + 2 : closePos + 1
    let openEnd = display ? pos + 2 : pos + 1
    return cx.append(MDElt(MDType.Math, pos, outerTo, [
        MDElt(MDType.MathMark, pos, openEnd),
        MDElt(MDType.MathFormula, contentFrom, contentTo),
        MDElt(MDType.MathMark, contentTo, outerTo),
    ]))
}

private func inlineEmoji(_ cx: MDInlineContext, _ next: Int, _ pos: Int) -> Int {
    if next != 58 { return -1 }
    var i = pos + 1
    while jsWord(cx.char(i)) { i += 1 }
    let open = i > pos + 1 && cx.char(i) == 58
    var j = pos - 1
    while j >= cx.offset && jsWord(cx.char(j)) { j -= 1 }
    let close = j < pos - 1 && j >= cx.offset && cx.char(j) == 58
    if !open && !close { return -1 }
    return cx.addDelimiter(.emoji, pos, pos + 1, open, close)
}

private func inlineDash(_ cx: MDInlineContext, _ next: Int, _ pos: Int) -> Int {
    if next != 45 || (pos > 1 && cx.char(pos - 1) == 45) { return -1 }
    var i = pos
    while i < cx.end && cx.char(i) == 45 { i += 1 }
    if i - pos > 3 { return -1 }
    return cx.append(MDElt(MDType.Dash, pos, i))
}

private func parseBracketedSegment(_ cx: MDInlineContext, _ start: Int) -> Int {
    if cx.char(start) != 91 { return -1 }
    var depth = 0
    var pos = start + 1
    while pos < cx.end {
        let next = cx.char(pos)
        if next == 92 { pos += 2; continue }
        if next == 91 { depth += 1; pos += 1; continue }
        if next == 93 {
            if depth == 0 { return pos + 1 }
            depth -= 1
        }
        pos += 1
    }
    return -1
}

private func parseParenthesizedSegment(_ cx: MDInlineContext, _ start: Int) -> Int {
    if cx.char(start) != 40 { return -1 }
    var depth = 1
    var pos = start + 1
    while pos < cx.end {
        let next = cx.char(pos)
        if next == 92 { pos += 2; continue }
        if next == 40 { depth += 1; pos += 1; continue }
        if next == 41 {
            depth -= 1
            if depth == 0 { return pos + 1 }
        }
        pos += 1
    }
    return -1
}

private func inlineNestedLinkAsPlainText(_ cx: MDInlineContext, _ next: Int, _ pos: Int) -> Int {
    if next != 91 || !cx.hasOpenLink { return -1 }
    let labelEnd = parseBracketedSegment(cx, pos)
    if labelEnd == -1 { return pos + 1 }
    let afterLabel = cx.char(labelEnd)
    if afterLabel == 40 {
        let destinationEnd = parseParenthesizedSegment(cx, labelEnd)
        return destinationEnd == -1 ? labelEnd : destinationEnd
    }
    if afterLabel == 91 {
        let referenceEnd = parseBracketedSegment(cx, labelEnd)
        return referenceEnd == -1 ? labelEnd : referenceEnd
    }
    return labelEnd
}

// MARK: spaceDestinationLinks

@inline(__always) private func isInlineSpace(_ c: Int) -> Bool { c == 32 || c == 9 }

private func trimInlineSpaceEnd(_ cx: MDInlineContext, _ from: Int, _ to: Int) -> Int {
    var end = to
    while end > from && isInlineSpace(cx.char(end - 1)) { end -= 1 }
    return end
}

private func sdIsEscaped(_ cx: MDInlineContext, _ pos: Int) -> Bool {
    var backslashes = 0
    var index = pos - 1
    while cx.char(index) == 92 { backslashes += 1; index -= 1 }
    return backslashes % 2 == 1
}

private func sdParseDestination(_ cx: MDInlineContext, _ openParen: Int) -> (Int, Int, Int)? {
    if cx.char(openParen) != 40 { return nil }
    let contentFrom = cx.skipSpace(openParen + 1)
    var depth = 0
    var escaped = false
    var pos = contentFrom
    while pos < cx.end {
        defer { pos += 1 }
        let char = cx.char(pos)
        if escaped { escaped = false; continue }
        if char == 92 { escaped = true; continue }
        if char == 10 { return nil }
        if char == 40 { depth += 1; continue }
        if char == 41 {
            if depth == 0 {
                return (contentFrom, trimInlineSpaceEnd(cx, contentFrom, pos), pos)
            }
            depth -= 1
        }
    }
    return nil
}

private func findOpeningQuote(_ cx: MDInlineContext, _ from: Int, _ to: Int, _ quote: Int) -> Int {
    var pos = to - 2
    while pos >= from {
        if cx.char(pos) == quote && !sdIsEscaped(cx, pos) { return pos }
        pos -= 1
    }
    return -1
}

private func findOpeningParenTitle(_ cx: MDInlineContext, _ from: Int, _ to: Int) -> Int {
    var depth = 0
    var pos = to - 1
    while pos >= from {
        defer { pos -= 1 }
        let char = cx.char(pos)
        if sdIsEscaped(cx, pos) { continue }
        if char == 41 { depth += 1; continue }
        if char == 40 {
            depth -= 1
            if depth == 0 { return pos }
        }
    }
    return -1
}

private func splitTrailingTitle(_ cx: MDInlineContext, _ contentFrom: Int, _ contentTo: Int) -> (Int, Int, Int?, Int?) {
    if contentTo <= contentFrom { return (contentFrom, contentTo, nil, nil) }
    let last = cx.char(contentTo - 1)
    if (last == 34 || last == 39) && !sdIsEscaped(cx, contentTo - 1) {
        let opening = findOpeningQuote(cx, contentFrom, contentTo, last)
        if opening > contentFrom && isInlineSpace(cx.char(opening - 1)) {
            return (contentFrom, trimInlineSpaceEnd(cx, contentFrom, opening - 1), opening, contentTo)
        }
    }
    if last == 41 && !sdIsEscaped(cx, contentTo - 1) {
        let opening = findOpeningParenTitle(cx, contentFrom, contentTo)
        if opening > contentFrom && isInlineSpace(cx.char(opening - 1)) {
            return (contentFrom, trimInlineSpaceEnd(cx, contentFrom, opening - 1), opening, contentTo)
        }
    }
    return (contentFrom, contentTo, nil, nil)
}

private func inlineSpaceDestinationLinkEnd(_ cx: MDInlineContext, _ next: Int, _ closeBracket: Int) -> Int {
    if next != 93 { return -1 }
    let linkOpening = cx.findOpeningDelimiter(.linkStart)
    let imageOpening = cx.findOpeningDelimiter(.imageStart)
    guard let index = [linkOpening, imageOpening].compactMap({ $0 }).max() else { return -1 }
    guard let delimiter = cx.getDelimiterAt(index) else { return -1 }
    let nodeType = delimiter.type == .imageStart ? MDType.Image : MDType.Link

    let openParen = closeBracket + 1
    if cx.char(openParen) != 40 { return -1 }
    guard let (contentFrom, contentTo, closeParen) = sdParseDestination(cx, openParen) else { return -1 }
    let (urlFrom, urlTo, titleFrom, titleTo) = splitTrailingTitle(cx, contentFrom, contentTo)
    var hasSpace = false
    var p = urlFrom
    while p < urlTo { if isInlineSpace(cx.char(p)) { hasSpace = true; break }; p += 1 }
    if !hasSpace { return -1 }

    var content = cx.takeContent(index)
    content.insert(MDElt(MDType.LinkMark, delimiter.from, delimiter.to), at: 0)
    content.append(MDElt(MDType.LinkMark, closeBracket, closeBracket + 1))
    content.append(MDElt(MDType.LinkMark, openParen, openParen + 1))
    content.append(MDElt(MDType.URL, urlFrom, urlTo))
    if let tf = titleFrom, let tt = titleTo { content.append(MDElt(MDType.LinkTitle, tf, tt)) }
    content.append(MDElt(MDType.LinkMark, closeParen, closeParen + 1))
    return cx.append(MDElt(nodeType, delimiter.from, closeParen + 1, content))
}

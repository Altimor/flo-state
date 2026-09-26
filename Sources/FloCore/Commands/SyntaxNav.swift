import Foundation

// Lezer-style navigation over FloCore's SyntaxTree, with Lezer's exact side
// semantics (resolveInner/childBefore/childAfter/nextSibling), so ported
// commands behave like their CodeMirror originals.

extension SyntaxNode {
    var cmIndexInParent: Int? { parent?.children.firstIndex { $0 === self } }
    var cmNextSibling: SyntaxNode? {
        guard let p = parent, let i = cmIndexInParent, i + 1 < p.children.count else { return nil }
        return p.children[i + 1]
    }
    var cmPrevSibling: SyntaxNode? {
        guard let p = parent, let i = cmIndexInParent, i > 0 else { return nil }
        return p.children[i - 1]
    }
    var cmFirstChild: SyntaxNode? { children.first }
    var cmLastChild: SyntaxNode? { children.last }

    /// Lezer `getChild(name, before?, after?)`.
    func cmGetChild(_ name: String, after: String? = nil) -> SyntaxNode? {
        var seenAfter = after == nil
        for c in children {
            if !seenAfter { if c.name == after { seenAfter = true }; continue }
            if c.name == name { return c }
        }
        return nil
    }

    /// Lezer `childBefore(pos)`: last child ending at or before pos... Lezer
    /// uses `enterChild(-1, pos, Side.Before)` = last child with from < pos.
    func cmChildBefore(_ pos: Int) -> SyntaxNode? {
        children.last { $0.from < pos }
    }
    /// Lezer `childAfter(pos)`: first child with to > pos.
    func cmChildAfter(_ pos: Int) -> SyntaxNode? {
        children.first { $0.to > pos }
    }
}

enum Lezer {
    /// Lezer `checkSide`.
    static func checkSide(_ side: Int, _ pos: Int, _ from: Int, _ to: Int) -> Bool {
        switch side {
        case -2: return from < pos
        case -1: return to >= pos && from < pos
        case 0: return from < pos && to > pos
        case 1: return from <= pos && to > pos
        case 2: return to > pos
        default: return true
        }
    }

    /// Lezer `tree.resolveInner(pos, side)`.
    static func resolveInner(_ tree: SyntaxTree, _ pos: Int, _ side: Int = 0) -> SyntaxNode {
        var cur = tree.root
        outer: while true {
            // Lezer scans children forward and enters the first match.
            for c in cur.children where checkSide(side, pos, c.from, c.to) {
                cur = c
                continue outer
            }
            return cur
        }
    }
}

extension EditorState {
    /// `markdownLanguage.isActiveAt(state, pos, side)`: false inside regions
    /// that the web app hands to a nested language (fenced code with a known
    /// @codemirror/language-data language, HTML blocks/tags/comments).
    func markdownActiveAt(_ pos: Int, _ side: Int = -1) -> Bool {
        guard markdown else { return false }
        var node: SyntaxNode? = tree.root
        while let n = node {
            let next = n.children.first { Lezer.checkSide(side, pos, $0.from, $0.to) }
            guard let c = next else { return true }
            switch c.name {
            case "FencedCode":
                if let info = c.cmGetChild("CodeInfo"), NestedLanguages.matches(sliceDoc(info.from, info.to)) {
                    for t in c.children where t.name == "CodeText" {
                        if (side > 0 ? t.from <= pos : t.from < pos) && (side < 0 ? t.to >= pos : t.to > pos) { return false }
                    }
                }
            case "HTMLBlock", "HTMLTag", "CommentBlock":
                return false
            default: break
            }
            node = c
        }
        return true
    }
}

enum NestedLanguages {
    // Names and aliases from @codemirror/language-data 6.5.2 (lowercased).
    // "markdown" is omitted on purpose: a nested markdown fence keeps the
    // markdown language data, so markdown commands stay active inside it.
    static let aliases: [[String]] = [["c"], ["c++", "cpp"], ["cql", "cassandra"], ["css"], ["go"], ["html", "xhtml"], ["java"], ["javascript", "ecmascript", "js", "node"], ["jinja"], ["json", "json5"], ["jsx"], ["less"], ["liquid"], ["mariadb sql"], ["ms sql"], ["mysql"], ["php"], ["plsql"], ["postgresql"], ["python"], ["rust"], ["sass"], ["scss"], ["sql"], ["sqlite"], ["tsx"], ["typescript", "ts"], ["webassembly"], ["xml", "rss", "wsdl", "xsd"], ["yaml", "yml"], ["apl"], ["pgp", "asciiarmor"], ["asn.1"], ["asterisk"], ["brainfuck"], ["cobol"], ["c#", "csharp", "cs"], ["clojure"], ["clojurescript"], ["closure stylesheets (gss)"], ["cmake"], ["coffeescript", "coffee", "coffee-script"], ["common lisp", "lisp"], ["cypher"], ["cython"], ["crystal"], ["d"], ["dart"], ["diff"], ["dockerfile"], ["dtd"], ["dylan"], ["ebnf"], ["ecl"], ["edn"], ["eiffel"], ["elm"], ["erlang"], ["esper"], ["factor"], ["fcl"], ["forth"], ["fortran"], ["f#", "fsharp"], ["gas"], ["gherkin"], ["groovy"], ["haskell"], ["haxe"], ["hxml"], ["http"], ["idl"], ["json-ld", "jsonld"], ["julia"], ["kotlin"], ["livescript", "ls"], ["lua"], ["mirc"], ["mathematica"], ["modelica"], ["mumps"], ["mbox"], ["nginx"], ["nsis"], ["ntriples"], ["objective-c", "objc"], ["objective-c++", "objc++"], ["ocaml"], ["octave"], ["oz"], ["pascal"], ["perl"], ["pig"], ["powershell"], ["properties files", "ini", "properties"], ["protobuf"], ["pug", "jade"], ["puppet"], ["q"], ["r", "rscript"], ["rpm changes"], ["rpm spec"], ["ruby", "jruby", "macruby", "rake", "rb", "rbx"], ["sas"], ["scala"], ["scheme"], ["shell", "bash", "sh", "zsh"], ["sieve"], ["smalltalk"], ["solr"], ["sml"], ["sparql", "sparul"], ["spreadsheet", "excel", "formula"], ["squirrel"], ["stylus"], ["swift"], ["stex"], ["latex", "tex"], ["systemverilog"], ["tcl"], ["textile"], ["tiddlywiki"], ["tiki wiki"], ["toml"], ["troff"], ["ttcn"], ["ttcn_cfg"], ["turtle"], ["web idl"], ["vb.net"], ["vbscript"], ["velocity"], ["verilog"], ["vhdl"], ["xquery"], ["yacas"], ["z80"], ["mscgen"], ["x\u{f9}"], ["msgenny"], ["vue"], ["angular template"]]

    /// `LanguageDescription.matchLanguageName(languages, info, true)` after
    /// lang-markdown strips everything from the first whitespace. Markdown
    /// itself also matches (fuzzy) but keeps markdown active, so it is
    /// checked first and reported as "not nested".
    static func matches(_ rawInfo: String) -> Bool {
        let info = String(rawInfo.prefix { !$0.isWhitespace }).lowercased()
        if info.isEmpty { return false }
        let all = aliases.prefix(14) + [["markdown"]] + aliases.dropFirst(14)
        for d in all where d.contains(info) { return d != ["markdown"] }
        let u = Array(info.utf16)
        func isW(_ i: Int) -> Bool {
            guard i >= 0 && i < u.count, let s = Unicode.Scalar(u[i]) else { return false }
            return s == "_" || (s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s)))
        }
        for d in all {
            for a in d {
                guard let r = info.range(of: a) else { continue }
                let found = info.utf16.distance(from: info.utf16.startIndex, to: r.lowerBound.samePosition(in: info.utf16)!)
                let alen = a.utf16.count
                if alen > 2 || (!isW(found - 1) && !isW(found + alen)) { return d != ["markdown"] }
            }
        }
        return false
    }
}

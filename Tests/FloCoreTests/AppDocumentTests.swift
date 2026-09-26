import XCTest
@testable import FloCore

/// Oracle comparisons against outputs captured from the web app's TypeScript.
final class AppOracleTests: XCTestCase {
    static let data: JSONValue = try! JSON.parse(AppOracleData.json)

    func cases(_ key: String) -> [JSONValue] { AppOracleTests.data[key]!.arrayValue! }

    func testFrontmatterAndTitles() {
        for c in cases("frontmatter") {
            let raw = c["raw"]!.stringValue!
            let d = Frontmatter.parseDocument(raw)
            XCTAssertEqual(d.frontmatter, c["fm"]!.stringValue, "fm for \(raw.debugDescription)")
            XCTAssertEqual(d.body, c["body"]!.stringValue!, "body for \(raw.debugDescription)")
            XCTAssertEqual(d.title, c["title"]!.stringValue!, "title for \(raw.debugDescription)")
            XCTAssertEqual(d.titleSource.rawValue, c["source"]!.stringValue!, "source for \(raw.debugDescription)")
        }
    }

    func testYamlEntriesParse() {
        for c in cases("yamlParse") {
            let y = c["y"]!.stringValue!
            let got = YamlEntries.parse(y).map { [$0.key, $0.value, $0.isComplex ? "C" : "S"] }
            let want = c["entries"]!.arrayValue!.map { e -> [String] in
                let a = e.arrayValue!
                return [a[0].stringValue!, a[1].stringValue!, a[2].boolValue! ? "C" : "S"]
            }
            XCTAssertEqual(got, want, "parse \(y.debugDescription)")
        }
    }

    func testYamlEntriesSerialize() {
        for c in cases("yamlSerialize") {
            let entries = c["entries"]!.arrayValue!.map { e -> YamlEntry in
                let a = e.arrayValue!
                return YamlEntry(id: "x", key: a[0].stringValue!, value: a[1].stringValue!, isComplex: a[2].boolValue!)
            }
            XCTAssertEqual(YamlEntries.serialize(entries), c["out"]!.stringValue!, "serialize \(entries.map { $0.key })")
        }
    }

    func testDocumentStats() {
        for c in cases("stats") {
            let text = c["c"]!.stringValue!
            let s = DocumentStatsCalculator.stats(text)
            let w = c["s"]!
            XCTAssertEqual(s, DocumentStats(words: Int(w["words"]!.intValue!), characters: Int(w["characters"]!.intValue!), paragraphs: Int(w["paragraphs"]!.intValue!)),
                           "stats for \(text.debugDescription)")
        }
    }

    func testSlugs() {
        for c in cases("slugs") {
            XCTAssertEqual(HeadingSlug.slugify(c["t"]!.stringValue!), c["s"]!.stringValue!, "slug for \(c["t"]!.stringValue!.debugDescription)")
        }
    }

    func testHeadings() {
        func conv(_ v: JSONValue) -> [DocumentHeading] {
            v.arrayValue!.map { h in
                DocumentHeading(level: Int(h["level"]!.intValue!), text: h["text"]!.stringValue!, line: Int(h["line"]!.intValue!),
                                pos: Int(h["pos"]!.intValue!), slug: h["slug"]!.stringValue!)
            }
        }
        for c in cases("headings") {
            let text = c["c"]!.stringValue!
            XCTAssertEqual(DocumentHeadings.parse(text, maxDepth: 6), conv(c["full"]!), "full \(text.debugDescription)")
            XCTAssertEqual(DocumentHeadings.forOutline(text), conv(c["rail"]!), "rail \(text.debugDescription)")
            XCTAssertEqual(DocumentHeadings.parse(text), conv(c["plain"]!), "plain \(text.debugDescription)")
        }
    }

    func testNormalizePath() {
        for c in cases("normalizePath") {
            XCTAssertEqual(LinkPaths.normalizePath(c["p"]!.stringValue!), c["r"]!.stringValue!, "normalize \(c["p"]!.stringValue!)")
        }
    }

    func testResolveLinkTarget() {
        let exists: Set<String> = ["/vault/docs/guide.md", "/vault/docs/foo/index.md", "/vault/docs/bar.md", "/vault/docs/bar/index.md",
                                   "/vault/docs/readme-only/README.md", "/vault/site/index.markdown", "/vault/docs/x.markdown"]
        for c in cases("links") {
            let href = c["href"]!.stringValue!
            let got = LinkPaths.resolveLinkTarget(href, currentFilePath: c["cur"]!.stringValue!, workspaceRoot: c["root"]!.stringValue,
                                                  fileExists: { exists.contains($0) })
            let want: LinkTarget?
            if let r = c["r"], !r.isNull {
                switch r["kind"]!.stringValue! {
                case "internal": want = .internalFile(path: r["path"]!.stringValue!, anchor: r["anchor"]?.stringValue)
                case "same-doc-anchor": want = .sameDocAnchor(r["anchor"]!.stringValue!)
                case "external-url": want = .externalURL(r["url"]!.stringValue!)
                default: want = .externalPath(r["path"]!.stringValue!)
                }
            } else { want = nil }
            XCTAssertEqual(got, want, "link \(href.debugDescription)")
        }
    }

    func testDestinationsAndMisc() {
        for c in cases("dest") {
            XCTAssertEqual(LinkPaths.normalizeMarkdownDestination(c["d"]!.stringValue!), c["n"]!.stringValue!)
        }
        for c in cases("fmtDest") {
            XCTAssertEqual(LinkPaths.formatMarkdownDestination(c["d"]!.stringValue!), c["f"]!.stringValue!)
        }
        let misc = AppOracleTests.data["misc"]!
        for e in misc["ext"]!.arrayValue! {
            let a = e.arrayValue!.map { $0.stringValue! }
            XCTAssertEqual(LinkPaths.getFileExtension(a[0]), a[1], "ext \(a[0])")
            XCTAssertEqual(LinkPaths.getFileStem(a[0]), a[2], "stem \(a[0])")
        }
        for e in misc["parent"]!.arrayValue! {
            let a = e.arrayValue!.map { $0.stringValue! }
            XCTAssertEqual(LinkPaths.getParentDir(a[0]), a[1])
        }
        for e in misc["image"]!.arrayValue! {
            let a = e.arrayValue!.map { $0.stringValue! }
            XCTAssertEqual(LinkPaths.resolveImagePath(a[0], markdownDir: a[1]), a[2])
        }
    }

    func testHTMLToMarkdown() {
        for c in cases("html") {
            let html = c["h"]!.stringValue!
            XCTAssertEqual(HTMLToMarkdown.convert(html), c["m"]!.stringValue!, "html \(html.debugDescription)")
            XCTAssertEqual(HTMLToMarkdown.isWorthConverting(html), c["w"]!.boolValue!, "worth \(html.debugDescription)")
        }
    }
}

final class AppFrontmatterTests: XCTestCase {
    // frontmatter.test.ts
    func testParseFrontmatter() {
        var r = Frontmatter.parse("---\ntitle: Hello\ndate: 2024-01-01\n---\n# Content")
        XCTAssertEqual(r.frontmatter, "title: Hello\ndate: 2024-01-01")
        XCTAssertEqual(r.body, "# Content")
        r = Frontmatter.parse("# Just a heading\n\nSome text")
        XCTAssertNil(r.frontmatter)
        r = Frontmatter.parse("---\ntitle: Test\n---\n\n# Content")
        XCTAssertEqual(r.body, "\n# Content")
        XCTAssertEqual(Frontmatter.parse("---\n\n---\nBody"), ParsedFile(frontmatter: "", body: "Body"))
        XCTAssertNil(Frontmatter.parse("Some text\n---\ntitle: Nope\n---\nMore text").frontmatter)
        XCTAssertEqual(Frontmatter.parse("---\n---\nBody"), ParsedFile(frontmatter: "", body: "Body"))
        XCTAssertEqual(Frontmatter.parse("---\n---"), ParsedFile(frontmatter: "", body: ""))
        XCTAssertEqual(Frontmatter.parse(""), ParsedFile(frontmatter: nil, body: ""))
    }

    func testSerialize() {
        XCTAssertEqual(Frontmatter.serialize("title: Hello", body: "# Content"), "---\ntitle: Hello\n---\n# Content")
        XCTAssertEqual(Frontmatter.serialize(nil, body: "# Content"), "# Content")
        XCTAssertEqual(Frontmatter.serialize("", body: "Body"), "---\n\n---\nBody")
        for original in ["---\ntitle: Test\ntags: [a, b]\n---\n\n# Hello\n\nWorld", "---\n\n---\nBody"] {
            let p = Frontmatter.parse(original)
            XCTAssertEqual(Frontmatter.serialize(p.frontmatter, body: p.body), original)
        }
    }

    func testParseDocument() {
        var d = Frontmatter.parseDocument("---\ntitle: Hello\ntags: [a]\n---\n\n# Hello #\n\nBody")
        XCTAssertEqual(d.title, "Hello")
        XCTAssertEqual(d.titleSource, .frontmatter)
        XCTAssertEqual(d.body, "\n# Hello #\n\nBody")
        d = Frontmatter.parseDocument("\n# Project Plan\n\nBody text.")
        XCTAssertEqual(d.title, "Project Plan")
        XCTAssertEqual(d.titleSource, .h1)
        d = Frontmatter.parseDocument("Body text.")
        XCTAssertEqual(d.title, "")
        XCTAssertEqual(d.titleSource, .none)
    }

    func testDisplayDate() {
        let utc = TimeZone(identifier: "UTC")!
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(Frontmatter.displayDate("date: 2024-01-05", locale: en, timeZone: utc), "January 5, 2024")
        XCTAssertEqual(Frontmatter.displayDate("updated: 2024-03-07T10:00:00Z", locale: en, timeZone: utc), "March 7, 2024")
        XCTAssertEqual(Frontmatter.displayDate("date: someday", locale: en, timeZone: utc), "someday", "unparseable strings pass through")
        XCTAssertEqual(Frontmatter.displayDate("date: 1700000000", locale: en, timeZone: utc), "November 14, 2023")
        XCTAssertEqual(Frontmatter.displayDate("date: 1700000000000", locale: en, timeZone: utc), "November 14, 2023")
        XCTAssertNil(Frontmatter.displayDate("title: x", locale: en, timeZone: utc))
        XCTAssertNil(Frontmatter.displayDate(nil, locale: en, timeZone: utc))
        XCTAssertNil(Frontmatter.displayDate("- a", locale: en, timeZone: utc))
        // Date-only strings are UTC midnight (JS Date.parse), shown in local time.
        XCTAssertEqual(Frontmatter.displayDate("date: 2024-01-05", locale: en, timeZone: TimeZone(identifier: "America/Los_Angeles")!), "January 4, 2024")
    }
}

final class AppYamlEntriesTests: XCTestCase {
    // yaml-entries.test.ts
    func testRoundTrip() {
        let entries = YamlEntries.parse("title: Test\nauthor: Jane\ndraft: false")
        let back = YamlEntries.parse(YamlEntries.serialize(entries))
        XCTAssertEqual(back.map { [$0.key, $0.value] }, entries.map { [$0.key, $0.value] })
    }

    func testIdsAreUnique() {
        let a = YamlEntries.parse("a: 1\nb: 2")
        XCTAssertNotEqual(a[0].id, a[1].id)
        XCTAssertTrue(a[0].id.hasPrefix("fm-"))
    }

    func testCoerceScalar() {
        XCTAssertEqual(YamlEntries.coerceScalar(""), .string(""))
        XCTAssertEqual(YamlEntries.coerceScalar("true"), .bool(true))
        XCTAssertEqual(YamlEntries.coerceScalar("null"), .null)
        XCTAssertEqual(YamlEntries.coerceScalar("42"), .number(42))
        XCTAssertEqual(YamlEntries.coerceScalar("0b101"), .number(5))
        XCTAssertEqual(YamlEntries.coerceScalar("   "), .string("   "))
        XCTAssertEqual(YamlEntries.coerceScalar("True"), .string("True"))
        XCTAssertEqual(YamlEntries.coerceScalar("12px"), .string("12px"))
    }
}

final class AppHeadingTests: XCTestCase {
    // heading-slug.test.ts
    func testSlugger() {
        let s = HeadingSlugger()
        XCTAssertEqual(s.slug("Title"), "title")
        XCTAssertEqual(s.slug("Title"), "title-2")
        XCTAssertEqual(s.slug("Title"), "title-3")
        let t = HeadingSlugger()
        XCTAssertEqual(t.slug("Title 2"), "title-2")
        XCTAssertEqual(t.slug("Title"), "title")
        XCTAssertEqual(t.slug("Title"), "title-3")
        let a = HeadingSlugger(), b = HeadingSlugger()
        XCTAssertEqual(a.slug("Heading"), "heading")
        XCTAssertEqual(b.slug("Heading"), "heading")
        XCTAssertEqual(a.slug("Heading"), "heading-2")
        XCTAssertEqual(b.slug("Heading"), "heading-2")
    }

    // document-headings.test.ts
    func testParse() {
        XCTAssertEqual(DocumentHeadings.parse(""), [])
        let h = DocumentHeadings.parse(["# Title", "Some body.", "## Section", "### Subsection", ""].joined(separator: "\n"))
        XCTAssertEqual(h.map { "\($0.level):\($0.text)" }, ["1:Title", "2:Section", "3:Subsection"])
        XCTAssertEqual(DocumentHeadings.parse("# A\n## B\n### C\n#### D", maxDepth: 2).map { $0.level }, [1, 2])
        let p = DocumentHeadings.parse("intro\n# Title\npara\n## Section")
        XCTAssertEqual(p.map { [$0.line, $0.pos] }, [[1, 6], [3, 19]])
        XCTAssertEqual(DocumentHeadings.parse("# Real\n```\n# Fake\n## Also fake\n```\n## Real too").map { $0.text }, ["Real", "Real too"])
        XCTAssertEqual(DocumentHeadings.parse("# Real\n~~~\n# Fake\n~~~\n## Done").map { $0.text }, ["Real", "Done"])
        XCTAssertEqual(DocumentHeadings.parse("#NotHeading\n# Heading").map { $0.text }, ["Heading"])
        XCTAssertEqual(DocumentHeadings.parse("## Title ##")[0].text, "Title")
        XCTAssertEqual(DocumentHeadings.parse("# "), [])
        XCTAssertEqual(DocumentHeadings.parse("# Hello, World!")[0].slug, "hello-world")
        XCTAssertEqual(DocumentHeadings.parse("# Café & Crème")[0].slug, "café-crème")
        XCTAssertEqual(DocumentHeadings.parse("# Setup\n## Setup\n### Setup").map { $0.slug }, ["setup", "setup-2", "setup-3"])
        XCTAssertEqual(DocumentHeadings.parse("# Setup\n#### Setup\n## Setup", maxDepth: 3, slugDepth: 6).map { "\($0.level):\($0.slug)" }, ["1:setup", "2:setup-3"])
    }

    func testSlugIndexAndLink() {
        let h = DocumentHeadings.parse("# A\n## B\n### A")
        let idx = DocumentHeadings.slugIndex(h)
        XCTAssertEqual(idx["a"]?.level, 1)
        XCTAssertEqual(idx["b"]?.level, 2)
        XCTAssertEqual(idx["a-2"]?.level, 3)
        XCTAssertEqual(DocumentHeadings.headingLink(h[1]), "[B](#b)")
    }

    func testPosIsUTF16() {
        let h = DocumentHeadings.parse("😀 intro\n# T")
        XCTAssertEqual(h[0].pos, 9)
    }
}

final class AppLinkPathTests: XCTestCase {
    // paths.test.ts (non-oracle parts)
    func testBasics() {
        XCTAssertEqual(LinkPaths.getFileExtension("/path/to/file.md"), "md")
        XCTAssertEqual(LinkPaths.getFileExtension("Makefile"), "")
        XCTAssertEqual(LinkPaths.getFileExtension("file.test.ts"), "ts")
        XCTAssertEqual(LinkPaths.getFileExtension(".gitignore"), "")
        XCTAssertEqual(LinkPaths.getFileStem("file.test.ts"), "file.test")
        XCTAssertEqual(LinkPaths.getFileName("C:\\Users\\test\\file.md"), "file.md")
        XCTAssertEqual(LinkPaths.getRelativePath("/home/user/docs/file.md", root: "/home/user"), "docs/file.md")
        XCTAssertEqual(LinkPaths.getRelativePath("/other/file.md", root: "/home/user"), "/other/file.md")
        XCTAssertEqual(LinkPaths.getRelativePath("/home/user/file.md", root: "/home/user/"), "file.md")
        XCTAssertEqual(LinkPaths.normalizeLocalMarkdownDestination("<Writer%20TODOs.md>"), "Writer TODOs.md")
        XCTAssertTrue(LinkPaths.isPlainTextPath("/a/b.CSV"))
        XCTAssertFalse(LinkPaths.isPlainTextPath("/a/b.md"))
    }

    func testResolveWithoutFileExists() {
        XCTAssertEqual(LinkPaths.resolveLinkTarget("./guide", currentFilePath: "/vault/docs/start.md", workspaceRoot: "/vault"), .externalPath("/vault/docs/guide"))
        XCTAssertEqual(LinkPaths.resolveLinkTarget("../../outside/doc", currentFilePath: "/vault/docs/start.md", workspaceRoot: "/vault", fileExists: { $0 == "/outside/doc.md" }),
                       .externalPath("/outside/doc"))
    }
}

final class AppWikiLinkTests: XCTestCase {
    func r(_ path: String, filename: String? = nil, rel: String? = nil) -> SearchResult {
        let name = filename ?? String(path.split(separator: "/").last!)
        return SearchResult(path: path, filename: name, relativePath: rel ?? name, score: 100)
    }

    func testNormalizeTarget() {
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("  Roadmap  "), "Roadmap")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("planning\\Roadmap"), "planning/Roadmap")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("Roadmap.md"), "Roadmap")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("Roadmap.markdown"), "Roadmap")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("Roadmap.MD"), "Roadmap")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("Roadmap.Markdown"), "Roadmap")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("  planning\\Roadmap.md  "), "planning/Roadmap")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("   "), "")
        XCTAssertEqual(WikiLinkResolver.normalizeTarget("//abs/x"), "abs/x")
    }

    func testParse() {
        var p = WikiLinkResolver.parse("No prior experience|I have no prior experience")
        XCTAssertEqual(p.path, "No prior experience")
        XCTAssertNil(p.fragment)
        XCTAssertEqual(p.alias, "I have no prior experience")
        XCTAssertEqual(p.displayText, "I have no prior experience")
        p = WikiLinkResolver.parse("Format your notes#^376b9d|second option")
        XCTAssertEqual(p.path, "Format your notes")
        XCTAssertEqual(p.fragment, "^376b9d")
        XCTAssertEqual(p.displayText, "second option")
        p = WikiLinkResolver.parse("#^0f681f|with great power comes great responsibility")
        XCTAssertEqual(p.path, "")
        XCTAssertEqual(p.fragment, "^0f681f")
        p = WikiLinkResolver.parse("Format your notes\\|Formatting")
        XCTAssertEqual(p.path, "Format your notes")
        XCTAssertEqual(p.alias, "Formatting")
        p = WikiLinkResolver.parse("Note#Heading")
        XCTAssertEqual(p.displayText, "Note")
        XCTAssertEqual(WikiLinkResolver.parse("#Heading").displayText, "#Heading")
        XCTAssertEqual(WikiLinkResolver.parse("x|").alias, nil)
        XCTAssertEqual(WikiLinkResolver.parse("x|").displayText, "x")
    }

    func testResolve() {
        var calls: [(String, Int)] = []
        func search(_ results: [SearchResult]) -> (String, Int) -> [SearchResult] { { q, l in calls.append((q, l)); return results } }
        XCTAssertEqual(WikiLinkResolver.resolve("Roadmap", workspaceRoot: "/vault", fuzzySearch: search([r("/vault/Roadmap.md")]), fileExists: { _ in false }),
                       .internalFile("/vault/Roadmap.md"))
        XCTAssertEqual(calls.last?.0, "Roadmap")
        XCTAssertEqual(calls.last?.1, 50)
        XCTAssertEqual(WikiLinkResolver.resolve("Roadmap", workspaceRoot: "/vault", fuzzySearch: search([r("/vault/planning/Roadmap.md"), r("/vault/teams/Roadmap.md")]), fileExists: { _ in false }), .unresolved)
        var probed: [String] = []
        calls = []
        XCTAssertEqual(WikiLinkResolver.resolve("planning/Roadmap", workspaceRoot: "/vault", fuzzySearch: search([]), fileExists: { probed.append($0); return true }),
                       .internalFile("/vault/planning/Roadmap.md"))
        XCTAssertEqual(probed, ["/vault/planning/Roadmap.md"])
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(WikiLinkResolver.resolve("Project Notes/My Note|Label With Spaces", workspaceRoot: "/vault", fuzzySearch: search([]), fileExists: { _ in true }),
                       .internalFile("/vault/Project Notes/My Note.md"))
        XCTAssertEqual(WikiLinkResolver.resolve("planning/Missing", workspaceRoot: "/vault", fuzzySearch: search([]), fileExists: { _ in false }), .unresolved)
        XCTAssertEqual(WikiLinkResolver.resolve("a/b", workspaceRoot: "/vault/", fuzzySearch: search([]), fileExists: { $0 == "/vault/a/b.markdown" }), .internalFile("/vault/a/b.markdown"))
        XCTAssertEqual(WikiLinkResolver.resolve("Notes.md", workspaceRoot: "/vault", fuzzySearch: search([r("/vault/Notes.md")]), fileExists: { _ in false }), .internalFile("/vault/Notes.md"))
        XCTAssertEqual(calls.last?.0, "Notes")
        XCTAssertEqual(WikiLinkResolver.resolve("Notes.markdown", workspaceRoot: "/vault", fuzzySearch: search([r("/vault/Notes.md")]), fileExists: { _ in false }), .internalFile("/vault/Notes.md"))
        XCTAssertEqual(WikiLinkResolver.resolve("  ", workspaceRoot: "/vault", fuzzySearch: search([]), fileExists: { _ in false }), .unresolved)
        XCTAssertEqual(WikiLinkResolver.resolve("roadmap", workspaceRoot: "/vault", fuzzySearch: search([r("/vault/Roadmap.md")]), fileExists: { _ in false }), .internalFile("/vault/Roadmap.md"))
        XCTAssertEqual(WikiLinkResolver.resolve("Missing", workspaceRoot: "/vault", fuzzySearch: search([r("/vault/SomeOther.md")]), fileExists: { _ in false }), .unresolved)
        XCTAssertEqual(WikiLinkResolver.resolve("No prior experience|I have no prior experience", workspaceRoot: "/vault",
                                         fuzzySearch: search([r("/vault/Adventurer/No prior experience.md", rel: "Adventurer/No prior experience.md")]), fileExists: { _ in false }),
                       .internalFile("/vault/Adventurer/No prior experience.md"))
        calls = []
        XCTAssertEqual(WikiLinkResolver.resolve("#^0f681f|with great power", workspaceRoot: "/vault", fuzzySearch: search([]), fileExists: { _ in false },
                                         currentFilePath: "/vault/Vault is just a local folder.md"), .internalFile("/vault/Vault is just a local folder.md"))
        XCTAssertTrue(calls.isEmpty)
    }

    func testCanonicalTarget() {
        let roadmap = r("/vault/Roadmap.md")
        XCTAssertEqual(WikiLinkResolver.canonicalTarget(roadmap, allFiles: [roadmap, r("/vault/Notes.md")]), "Roadmap")
        let p = r("/vault/planning/Roadmap.md", rel: "planning/Roadmap.md")
        XCTAssertEqual(WikiLinkResolver.canonicalTarget(p, allFiles: [p, r("/vault/teams/Roadmap.md", rel: "teams/Roadmap.md")]), "planning/Roadmap")
        let a = r("/vault/a/Notes.md", rel: "a/Notes.md")
        XCTAssertEqual(WikiLinkResolver.canonicalTarget(a, allFiles: [a, r("/vault/b/notes.md", rel: "b/notes.md")]), "a/Notes")
        let art = r("/vault/Art direction ideas.md")
        XCTAssertEqual(WikiLinkResolver.canonicalTarget(art, allFiles: [art]), "Art direction ideas")
    }

    func testImageEmbeds() {
        XCTAssertEqual(WikiLinkResolver.parseImageEmbedTarget("diagram.png"), "diagram.png")
        XCTAssertEqual(WikiLinkResolver.parseImageEmbedTarget("Photo.JPEG"), "Photo.JPEG")
        XCTAssertEqual(WikiLinkResolver.parseImageEmbedTarget("assets\\pic.png"), "assets/pic.png")
        XCTAssertEqual(WikiLinkResolver.parseImageEmbedTarget("/assets/pic.png"), "assets/pic.png")
        XCTAssertEqual(WikiLinkResolver.parseImageEmbedTarget("pic.png|400"), "pic.png")
        for bad in ["Some Note", "Some Note.md", "report.pdf", ".png", "dot.", ""] { XCTAssertNil(WikiLinkResolver.parseImageEmbedTarget(bad), bad) }
    }

    func testResolveImage() {
        var found = 0
        let noFind: (String, String) -> String? = { _, _ in found += 1; return nil }
        XCTAssertEqual(WikiLinkResolver.resolveImage("assets/pic.png", workspaceRoot: "/vault", currentFilePath: "/vault/notes/note.md", fileExists: { $0 == "/vault/assets/pic.png" }, findFileByName: noFind), "/vault/assets/pic.png")
        XCTAssertEqual(WikiLinkResolver.resolveImage("assets/pic.png", workspaceRoot: "/vault", currentFilePath: "/vault/notes/note.md", fileExists: { $0 == "/vault/notes/assets/pic.png" }, findFileByName: noFind), "/vault/notes/assets/pic.png")
        XCTAssertEqual(WikiLinkResolver.resolveImage("pic.png", workspaceRoot: "/vault", currentFilePath: "/vault/notes/note.md", fileExists: { $0 == "/vault/notes/pic.png" }, findFileByName: noFind), "/vault/notes/pic.png")
        XCTAssertEqual(found, 0)
        XCTAssertEqual(WikiLinkResolver.resolveImage("pic.png", workspaceRoot: "/vault", currentFilePath: "/vault/notes/note.md", fileExists: { _ in false },
                                              findFileByName: { $0 == "/vault" && $1 == "pic.png" ? "/vault/deep/attachments/pic.png" : nil }), "/vault/deep/attachments/pic.png")
        XCTAssertNil(WikiLinkResolver.resolveImage("assets/pic.png", workspaceRoot: "/vault", currentFilePath: nil, fileExists: { _ in false }, findFileByName: { _, _ in "/vault/wrong.png" }))
        XCTAssertEqual(WikiLinkResolver.resolveImage("pic.png", workspaceRoot: nil, currentFilePath: "/anywhere/note.md", fileExists: { $0 == "/anywhere/pic.png" }, findFileByName: noFind), "/anywhere/pic.png")
        XCTAssertEqual(found, 0)
    }
}

final class AppDailyNoteAndTimeTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let day = Date(timeIntervalSince1970: 1_758_758_400 + 3600) // 2025-09-25 01:00 UTC

    func testStamp() {
        XCTAssertEqual(DailyNote.todayStamp(day, timeZone: utc), "2025.09.25")
        XCTAssertEqual(DailyNote.todayStamp(day, timeZone: TimeZone(identifier: "America/Los_Angeles")!), "2025.09.24", "local calendar day")
    }

    func testEnsureTodayHeading() {
        XCTAssertNil(DailyNote.ensureTodayHeading("# Plain note\n", now: day, timeZone: utc), "only dated notebooks")
        let doc = "## 2025.09.24\nstuff"
        XCTAssertEqual(DailyNote.ensureTodayHeading(doc, now: day, timeZone: utc), DailyNote.Edit(at: doc.utf16.count, text: "\n\n## 2025.09.25\n\n", caret: nil))
        XCTAssertEqual(DailyNote.ensureTodayHeading("## 2025.09.24\n", now: day, timeZone: utc)?.text, "\n## 2025.09.25\n\n")
        XCTAssertEqual(DailyNote.ensureTodayHeading("## 2025.09.24\n\n", now: day, timeZone: utc)?.text, "## 2025.09.25\n\n")
        XCTAssertNil(DailyNote.ensureTodayHeading("## 2025.09.24\n## 2025.09.25  \n", now: day, timeZone: utc), "idempotent")
        XCTAssertNil(DailyNote.ensureTodayHeading("text ## 2025.09.24", now: day, timeZone: utc))
    }

    func testGoToToday() {
        XCTAssertEqual(DailyNote.goToToday("a\n## 2025.09.25\nb", now: day, timeZone: utc), .existing(caret: 15))
        let doc = "note"
        XCTAssertEqual(DailyNote.goToToday(doc, now: day, timeZone: utc), .inserted(DailyNote.Edit(at: 4, text: "\n\n## 2025.09.25\n\n", caret: 4 + 17)))
    }

    func testJumpToBottom() {
        XCTAssertFalse(DailyNote.shouldJumpToBottom(awayMs: 1e9, minutes: 0))
        XCTAssertFalse(DailyNote.shouldJumpToBottom(awayMs: 9 * 60_000, minutes: 10))
        XCTAssertTrue(DailyNote.shouldJumpToBottom(awayMs: 10 * 60_000, minutes: 10))
    }

    // relative-time.test.ts
    func testRelativeTime() {
        let now: UInt64 = 1_700_000_000
        XCTAssertNil(formatRelativeTime(0, nowSecs: now))
        XCTAssertEqual(formatRelativeTime(now, nowSecs: now), "just now")
        XCTAssertEqual(formatRelativeTime(now - 30, nowSecs: now), "just now")
        XCTAssertEqual(formatRelativeTime(now + 500, nowSecs: now), "just now")
        XCTAssertEqual(formatRelativeTime(now - 60, nowSecs: now), "1 min ago")
        XCTAssertEqual(formatRelativeTime(now - 120, nowSecs: now), "2 mins ago")
        XCTAssertEqual(formatRelativeTime(now - 3600, nowSecs: now), "1 hour ago")
        XCTAssertEqual(formatRelativeTime(now - 3 * 3600, nowSecs: now), "3 hours ago")
        XCTAssertEqual(formatRelativeTime(now - 86400, nowSecs: now), "1 day ago")
        XCTAssertEqual(formatRelativeTime(now - 5 * 86400, nowSecs: now), "5 days ago")
        XCTAssertEqual(formatRelativeTime(now - 14 * 86400, nowSecs: now), "2 weeks ago")
        XCTAssertEqual(formatRelativeTime(now - 45, nowSecs: now), "1 min ago")
        XCTAssertEqual(formatRelativeTime(now - 90, nowSecs: now), "2 mins ago", "Math.round rounds .5 up")
    }
}

final class AppJSONTests: XCTestCase {
    func testSerdePrettyFormat() throws {
        let v: JSONValue = .object([("a", .array([])), ("b", .object([])), ("c", .array([.int(1), .string("x/y\"")])), ("d", .null)])
        XCTAssertEqual(JSON.prettyString(v), "{\n  \"a\": [],\n  \"b\": {},\n  \"c\": [\n    1,\n    \"x/y\\\"\"\n  ],\n  \"d\": null\n}")
        XCTAssertEqual(try JSON.parse(JSON.prettyString(v)), v)
        XCTAssertEqual(try JSON.parse(#"{"u":"\u00e9\ud83d\ude00","n":-1.5e2}"#)["u"], .string("é😀"))
        XCTAssertThrowsError(try JSON.parse("{"))
        XCTAssertThrowsError(try JSON.parse("[1,]"))
    }
}

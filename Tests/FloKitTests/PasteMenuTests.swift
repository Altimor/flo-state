import XCTest
import AppKit
@testable import FloKit
import FloCore

@MainActor
final class PasteMenuTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flo-paste-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func replayer() -> KeyReplayer {
        let r = KeyReplayer()
        r.controller.documentPath = tmp.appendingPathComponent("note.md").path
        r.controller.workspaceRoot = tmp.path
        return r
    }

    static let png1px = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196,
                              137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 15, 4, 0, 9, 251, 3, 253, 227, 85, 242, 156, 0, 0, 0, 0, 73, 69,
                              78, 68, 174, 66, 96, 130])

    // MARK: paste parity (fixtures/paste-wk.json)

    func testPasteWebParity() throws {
        guard let cases = KitFixtures.json("paste-wk.json") as? [[String: Any]] else { throw XCTSkip("fixtures/paste-wk.json missing") }
        let r = replayer()
        let c = r.controller
        var frontmatter: String? = nil // the file's frontmatter across cases, like the web store
        c.features.frontmatterPaste = { fm in
            if frontmatter != nil { return false }
            frontmatter = fm
            return true
        }
        var ok = 0
        for cs in cases {
            let name = cs["name"] as! String
            r.load(cs["doc"] as! String, selection: .cursor(0))
            c.run { t in t.dispatch(TransactionSpec(selection: .single(cs["anchor"] as! Int, cs["head"] as! Int))); return true }
            var p = PastePayload(plain: cs["plain"] as? String, html: cs["html"] as? String)
            if let img = cs["image"] as? [String] {
                p.image = (Self.png1px, String(img[1].split(separator: "/")[1]), img[0])
            }
            c.features.paste(p)
            let res = cs["result"] as! [String: Any]
            var exp = res["doc"] as! String
            var got = c.state.doc.string
            // attachment names differ (mock backend vs Rust naming): normalise
            let re = try! NSRegularExpression(pattern: #"attachments/[^)]+\.(png|jpe?g|webp)"#)
            func norm(_ s: String) -> String { re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "attachments/IMG") }
            let hadImage = cs["image"] is [String]
            if hadImage {
                XCTAssertNotNil(got.range(of: #"attachments/\d{8}-\d{6}-[0-9a-f]{4}\.(png|jpg)"#, options: .regularExpression), "\(name): Rust naming \(got)")
                exp = norm(exp); got = norm(got)
                // intentional divergence from the web app: the image goes on its own line and the
                // caret moves below it (so it renders at once). Apply that rule to the expectation.
                let mdRE = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(attachments/IMG\)"#)
                if let m = mdRE.firstMatch(in: exp, range: NSRange(location: 0, length: (exp as NSString).length)) {
                    let e = exp as NSString
                    let before = e.substring(to: m.range.location), md = e.substring(with: m.range), after = e.substring(from: NSMaxRange(m.range))
                    let lead = before.isEmpty || before.hasSuffix("\n") ? "" : "\n"
                    exp = before + lead + md + "\n" + after
                }
            }
            XCTAssertEqual(got, exp, name)
            if !hadImage {
                XCTAssertEqual(c.state.selection.main.anchor, res["anchor"] as! Int, "\(name) anchor")
                XCTAssertEqual(c.state.selection.main.head, res["head"] as! Int, "\(name) head")
            } else {
                XCTAssertEqual(c.state.selection.main.head, c.state.doc.string.utf16.count - ((cs["doc"] as! String).utf16.count - (cs["head"] as! Int)), "\(name): caret on the line after the image")
            }
            XCTAssertEqual(r.viewText, c.text, name)
            if got == exp { ok += 1 }
        }
        XCTAssertEqual(frontmatter, "title: X")
        print("paste parity: \(ok)/\(cases.count)")
    }

    func testImagePasteWritesFileAndIsOneUndoStep() throws {
        let r = replayer()
        let c = r.controller
        r.load("ab", selection: .cursor(1))
        c.features.paste(PastePayload(image: (Self.png1px, "png", "image.png")))
        let doc = c.text
        let m = try XCTUnwrap(doc.range(of: #"!\[image\.png\]\(attachments/(\d{8}-\d{6}-[0-9a-f]{4}\.png)\)"#, options: .regularExpression))
        let rel = String(doc[m]).dropFirst("![image.png](".count).dropLast()
        let file = tmp.appendingPathComponent(String(rel))
        XCTAssertEqual(try Data(contentsOf: file), Self.png1px)
        XCTAssertTrue(doc.hasPrefix("a") && doc.hasSuffix("b"))
        // the image gets its own line and the caret moves below it, so it renders at once
        let lines = doc.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3); XCTAssertEqual(lines[0], "a"); XCTAssertEqual(lines[2], "b")
        XCTAssertTrue(lines[1].hasPrefix("![image.png](attachments/"))
        XCTAssertEqual(c.state.selection.main.head, (doc as NSString).length - 1, "caret at the start of the next line")
        _ = c.handleKey("Mod-z")
        XCTAssertEqual(c.text, "ab")
        // over 5 MB: ignored (and nothing else is pasted)
        let big = Data(count: 5 * 1024 * 1024 + 1)
        c.features.paste(PastePayload(plain: "text", image: (big, "png", "image.png")))
        XCTAssertEqual(c.text, "ab")
    }

    func testPasteboardReading() {
        let pb = NSPasteboard(name: NSPasteboard.Name("flo-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("plain", forType: .string)
        pb.setString("<b>plain</b>", forType: .html)
        pb.setData(Self.png1px, forType: .png)
        var p = PastePayload.read(pb)
        XCTAssertEqual(p.plain, "plain")
        XCTAssertEqual(p.html, "<b>plain</b>")
        XCTAssertNil(p.image, "web content wins over an image rendering of it")
        pb.clearContents()
        pb.setData(Self.png1px, forType: .png)
        p = PastePayload.read(pb)
        XCTAssertEqual(p.image?.name, "image.png")
        XCTAssertEqual(p.image?.format, "png")
        // a copied image file keeps its name
        let f = tmp.appendingPathComponent("My Photo.png")
        try? Self.png1px.write(to: f)
        pb.clearContents()
        pb.writeObjects([f as NSURL])
        p = PastePayload.read(pb)
        XCTAssertEqual(p.image?.name, "My Photo.png")
        // real paste through NSTextView.paste(_:) from a private pasteboard: rich HTML
        let r = replayer()
        r.load("", selection: .cursor(0))
        pb.clearContents()
        pb.setString("x and y", forType: .string)
        pb.setString("<i>x</i> and <b>y</b>", forType: .html)
        XCTAssertTrue(r.controller.features.paste(pb, plain: false))
        XCTAssertEqual(r.controller.text, "*x* and **y**")
        XCTAssertTrue(r.controller.features.paste(pb, plain: true))
        XCTAssertEqual(r.controller.text, "*x* and **y**x and y")
    }

    // MARK: context menu

    func flatten(_ m: NSMenu) -> [[String?]] {
        var out: [[String?]] = []
        for it in m.items {
            if it.isSeparatorItem { out.append(["Predefined", "Separator", nil, nil]); continue }
            if let sub = it.submenu { out += flatten(sub); continue }
            var acc: String? = nil
            if !it.keyEquivalent.isEmpty {
                var parts = ["CmdOrCtrl"]
                if it.keyEquivalentModifierMask.contains(.option) { parts.append("Alt") }
                if it.keyEquivalentModifierMask.contains(.shift) { parts.append("Shift") }
                parts.append(it.keyEquivalent == "\r" ? "Enter" : it.keyEquivalent.uppercased())
                acc = parts.joined(separator: "+")
            }
            out.append(["MenuItem", it.representedObject as? String, it.title, acc])
        }
        return out
    }

    /// Web ids → native command ids.
    static let idMap: [String: String] = [
        "fmt.bold": "format.bold", "fmt.italic": "format.italic", "fmt.strikethrough": "format.strikethrough", "fmt.code": "format.code",
        "fmt.link": "format.link", "fmt.clear": "clearInlineFormatting", "para.h1": "format.heading1", "para.h2": "format.heading2",
        "para.h3": "format.heading3", "para.h4": "format.heading4", "para.h5": "format.heading5", "para.h6": "format.heading6",
        "para.paragraph": "format.paragraph", "para.bullet": "format.bulletList", "para.numbered": "format.numberedList",
        "para.task": "format.taskList", "para.blockquote": "format.blockquote", "para.codeblock": "toggleFencedCodeBlock",
        "ins.link": "format.link", "ins.table": "insertTable", "ins.hr": "insertHorizontalRule", "ins.date": "insertToday", "ins.time": "insertNow",
    ]

    func testMenuWebParity() throws {
        guard let fx = KitFixtures.json("menu-wk.json") as? [String: Any] else { throw XCTSkip("fixtures/menu-wk.json missing") }
        let menus = fx["menus"] as! [String: [String: Any]]
        let r = replayer()
        let c = r.controller
        for (label, m) in menus {
            r.load(m["doc"] as! String, selection: .cursor(0))
            let href = c.features.menuLinkHref(at: m["pos"] as! Int)
            let menu = c.features.buildMenu(linkHref: href)
            // web: children are created before their submenu; compare the items in order
            let web = (m["items"] as! [[Any]]).filter { ($0[0] as! String) == "MenuItem" || ($0[0] as! String) == "Predefined" }
                .map { e -> [String?] in [e[0] as? String, (e[1] as? String).map { Self.idMap[$0] ?? $0 }, e[2] as? String, e[3] as? String] }
            XCTAssertEqual(flatten(menu).map { $0.map { $0 ?? "-" } }, web.map { $0.map { $0 ?? "-" } }, label)
            XCTAssertEqual(menu.items.compactMap { $0.submenu?.title }, ["Format", "Paragraph", "Insert"])
        }
        r.load("plain text", selection: .cursor(0))
        XCTAssertEqual(c.features.menuLinkHref(at: 1), nil)
        // actions
        var ok = 0
        let actions = fx["actions"] as! [[String: Any]]
        let pb = NSPasteboard(name: NSPasteboard.Name("flo-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        for a in actions {
            r.load(a["doc"] as! String, selection: .cursor(0))
            c.run { t in t.dispatch(TransactionSpec(selection: .single(a["anchor"] as! Int, a["head"] as! Int))); return true }
            let before = a["before"] as! [String: Any]
            XCTAssertEqual(c.state.selection.main.head, before["head"] as! Int)
            let id = a["item"] as! String
            c.features.performMenuAction(Self.idMap[id] ?? id, pasteboard: pb)
            let after = a["after"] as! [String: Any]
            // Intentional divergence: bullet / numbered list keep the caret instead of selecting the lines
            // (typing then replaced the list marker along with the text).
            let keepsCaret = id == "para.bullet" || id == "para.numbered"
            let same = c.text == after["doc"] as! String && (keepsCaret || (c.state.selection.main.anchor == after["anchor"] as! Int
                && c.state.selection.main.head == after["head"] as! Int))
            XCTAssertTrue(same, "\(id) on \((a["doc"] as! String).debugDescription): got \(c.text.debugDescription) \(c.state.selection.main) exp \(after)")
            if same { ok += 1 }
            XCTAssertEqual(r.viewText, c.text)
        }
        print("menu action parity: \(ok)/\(actions.count)")
    }

    func testMenuClipboardAndLinks() {
        let r = replayer()
        let c = r.controller
        let pb = NSPasteboard(name: NSPasteboard.Name("flo-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        r.load("hello world", selection: .cursor(0))
        c.run { t in t.dispatch(TransactionSpec(selection: .single(0, 5))); return true }
        c.features.performMenuAction("copy", pasteboard: pb)
        XCTAssertEqual(pb.string(forType: .string), "hello")
        c.features.performMenuAction("cut", pasteboard: pb)
        XCTAssertEqual(c.text, " world")
        c.run { t in t.dispatch(TransactionSpec(selection: .cursor(6))); return true }
        c.features.performMenuAction("paste", pasteboard: pb)
        XCTAssertEqual(c.text, " worldhello")
        pb.clearContents(); pb.setString("<b>x</b>", forType: .html); pb.setString("x", forType: .string)
        c.features.performMenuAction("paste-plain", pasteboard: pb)
        XCTAssertEqual(c.text, " worldhellox", "menu paste is plain text only")
        // links
        r.load("see [site](<a b.md>) and https://e.com/x", selection: .cursor(0))
        XCTAssertEqual(c.features.menuLinkHref(at: 6), "a b.md")
        XCTAssertEqual(c.features.menuLinkHref(at: 30), "https://e.com/x")
        var opened: [EditorController.LinkClick] = []
        c.onLinkClick = { opened.append($0) }
        c.features.performMenuAction("open-link", linkHref: "a b.md", pasteboard: pb)
        XCTAssertEqual(opened, [.href("a b.md")])
        c.features.performMenuAction("copy-link", linkHref: "a b.md", pasteboard: pb)
        XCTAssertEqual(pb.string(forType: .string), "a b.md")
        // NSMenu built for a right-click on the link carries the link items, wired to the target
        let menu = c.features.buildMenu(linkHref: "a b.md")
        let open = menu.items.first { $0.title == "Open link" }!
        _ = (open.target as? NSObject)?.perform(open.action, with: open)
        XCTAssertEqual(opened.count, 2)
        // right-click event → menu(for:)
        let p = c.textView.firstRect(forCharacterRange: NSRange(location: 6, length: 1), actualRange: nil)
        let wp = r.window.convertFromScreen(p)
        let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: wp.midX, y: wp.midY), modifierFlags: [], timestamp: 0,
                                    windowNumber: r.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let m2 = c.textView.menu(for: ev)!
        XCTAssertTrue(m2.items.contains { $0.title == "Copy link" })
        XCTAssertEqual(m2.items.first?.title, "Cut")
    }

    func testPointerOverLink() {
        let r = replayer()
        let c = r.controller
        let doc = "see [site](https://x.com) and [[Note]] plain\n\nother line"
        r.load(doc, selection: .cursor(doc.utf16.count))
        c.onLinkClick = { _ in }
        func ev(_ pos: Int) -> NSEvent {
            let rect = c.textView.firstRect(forCharacterRange: NSRange(location: pos, length: 1), actualRange: nil)
            let w = r.window.convertFromScreen(rect)
            return NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: w.midX, y: w.midY), modifierFlags: [], timestamp: 0,
                                      windowNumber: r.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        let ns = doc as NSString
        XCTAssertTrue(c.features.pointerOverLink(ev(ns.range(of: "site").location + 1)))
        XCTAssertTrue(c.features.pointerOverLink(ev(ns.range(of: "[[Note").location + 1)))
        XCTAssertFalse(c.features.pointerOverLink(ev(ns.range(of: "plain").location + 2)))
        c.onLinkClick = nil
        XCTAssertFalse(c.features.pointerOverLink(ev(ns.range(of: "site").location + 1)), "no navigation hook: no hand")
    }

    func testReloadClosesCompletionAndRecountsFind() {
        let r = replayer()
        let c = r.controller
        r.load("aa aa", selection: .cursor(0))
        _ = c.handleKey("Mod-f")
        c.features.findOverlay!.setQuery("aa")
        XCTAssertEqual(c.features.findOverlay!.counterText, "1/2")
        c.load("aa aa aa", selection: .cursor(0))
        XCTAssertEqual(c.features.findOverlay!.counterText, "1/3")
    }
}

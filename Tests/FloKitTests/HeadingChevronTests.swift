import XCTest
@testable import FloKit
@testable import FloCore

/// Issue #13: the heading fold chevron sat on the last `#` of a revealed `###`.
@MainActor
final class HeadingChevronTests: XCTestCase {
    func make(_ theme: EditorTheme, doc: String, caret: Int) -> (EditorController, NSWindow) {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let c = EditorController(theme: theme)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        w.contentView = content
        c.scrollView.frame = content.bounds
        content.addSubview(c.scrollView)
        c.layoutColumn()
        c.load(doc, selection: .cursor(caret))
        c.textView.textLayoutManager?.ensureLayout(for: c.textView.textLayoutManager!.documentRange)
        return (c, w)
    }

    func fragment(_ c: EditorController, line: Int) -> FloLayoutFragment {
        let tlm = c.textView.textLayoutManager!, tcm = tlm.textContentManager!
        let loc = tcm.location(tcm.documentRange.location, offsetBy: c.state.doc.line(line).from)!
        return tlm.textLayoutFragment(for: loc) as! FloLayoutFragment
    }

    func check(_ theme: EditorTheme, file: StaticString = #filePath, line: UInt = #line) {
        let doc = "### Plain QEMU/KVM VM for the laptop\n\nbody\n\n### Second heading\n\nmore\n"
        let (c, _) = make(theme, doc: doc, caret: 5)   // caret on line 1: its # marks are revealed
        let o = c.textView.textContainerOrigin
        // revealed: the chevron ends left of the # marks
        let f1 = fragment(c, line: 1)
        let origin1 = CGPoint(x: o.x + f1.layoutFragmentFrame.minX, y: o.y + f1.layoutFragmentFrame.minY)
        let hashes = try! XCTUnwrap(f1.headingHashLeft(origin: origin1, theme: c.theme), "hash marks revealed on the caret line", file: file, line: line)
        let r1 = try! XCTUnwrap(c.chevronRect(line: 1), file: file, line: line)
        XCTAssertLessThanOrEqual(r1.maxX, hashes - 1, "chevron clear of the revealed ###", file: file, line: line)
        // hidden: clear of the heading text
        let line5 = c.state.doc.line(5)
        let r5 = try! XCTUnwrap(c.chevronRect(line: 5), file: file, line: line)
        let f5 = fragment(c, line: 5)
        let origin5 = CGPoint(x: o.x + f5.layoutFragmentFrame.minX, y: o.y + f5.layoutFragmentFrame.minY)
        XCTAssertNil(f5.headingHashLeft(origin: origin5, theme: c.theme), file: file, line: line)
        let textX = f5.charOrigin(4, origin: origin5)!.x
        XCTAssertLessThanOrEqual(r5.maxX, textX, file: file, line: line)
        _ = line5
    }

    func testChevronClearOfHashes() { check(EditorTheme()) }
    func testChevronClearOfHashesMonospaceFont() { check(EditorTheme(fontFamilies: ["Menlo"])) }
}

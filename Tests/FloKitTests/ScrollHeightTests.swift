import XCTest
import AppKit
@testable import FloKit
import FloCore
import FloTestSupport

@MainActor
final class ScrollHeightTests: XCTestCase {
    /// The document view must be as tall as the laid-out text (+ insets), so the
    /// scroller reflects the real position.
    func testDocumentHeightMatchesLayout() throws {
        let text = SyntheticNotebook.journal()
        let r = KeyReplayer()
        r.load(text, selection: .cursor(0))
        let tv = r.controller.textView
        let tlm = tv.textLayoutManager!
        func contentBottom() -> CGFloat {
            var maxY: CGFloat = 0
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { f in
                maxY = f.layoutFragmentFrame.maxY; return false
            }
            return maxY + tv.textContainerOrigin.y
        }
        r.window.displayIfNeeded()
        XCTAssertEqual(tv.frame.height, contentBottom() + tv.bottomPadding, accuracy: 60, "after load")
        // scroll to the end and type
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        r.press("t:hello")
        r.window.displayIfNeeded()
        XCTAssertEqual(tv.frame.height, contentBottom() + tv.bottomPadding, accuracy: 60, "after typing at end")
        // scroll through the document top to bottom
        let clip = r.controller.scrollView.contentView
        for y in stride(from: 0, to: tv.frame.height, by: 800) {
            clip.scroll(to: NSPoint(x: 0, y: y)); r.window.displayIfNeeded()
        }
        XCTAssertEqual(tv.frame.height, contentBottom() + tv.bottomPadding, accuracy: 60, "after scrolling")
    }
}

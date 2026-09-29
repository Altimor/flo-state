import AppKit
import XCTest
@testable import FloCore
@testable import FloKit

/// The app's context menu replaces NSTextView's, so it carries the spelling items itself.
@MainActor
final class SpellingMenuTests: XCTestCase {
    var window: NSWindow!
    override func tearDown() { window?.close(); window = nil }

    func testMisspelledWordOffersGuessesAndLearnSpelling() throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let c = EditorController(theme: EditorTheme())
        c.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(c.scrollView)
        c.layoutColumn()
        let text = "We recieve the parcel today\n"
        c.load(text, selection: .cursor(0))
        let tv = c.textView
        let bad = (text as NSString).range(of: "recieve").location + 2
        let items = try XCTUnwrap(tv.spellingItems(forCharacterAt: bad))
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("receive"), "\(titles)")
        XCTAssertTrue(titles.contains(L("Learn Spelling")))
        XCTAssertTrue(titles.contains(L("Ignore Spelling")))
        XCTAssertNil(tv.spellingItems(forCharacterAt: (text as NSString).range(of: "parcel").location), "correct word")
        tv.checksSpelling = false
        XCTAssertNil(tv.spellingItems(forCharacterAt: bad), "spell checking off")
    }
}

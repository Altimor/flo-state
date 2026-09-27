import XCTest
@testable import FloCore

/// Live bug: a pasted screenshot's alt text ("CleanShot … PM@2x.png") contains an
/// email-shaped autolink, which the planner took as the image path, so the image never showed.
final class ImageAltAutolinkTests: XCTestCase {
    func src(_ md: String) -> String? {
        let plan = RenderPlanner.plan(EditorState(doc: Text(md), selection: .cursor(0)))
        for w in plan.widgets { if case let .image(s, _, _, _) = w.kind { return s } }
        return nil
    }
    func testAltWithEmailShapedTextKeepsDestination() {
        XCTAssertEqual(src("x\n![CleanShot 2026-09-26 at 7.45.52 PM@2x.png](attachments/20260927-024621-f646.png)\n"),
                       "attachments/20260927-024621-f646.png")
        XCTAssertEqual(src("x\n![x@2x.png](a.png)\n"), "a.png")
        XCTAssertEqual(src("x\n![plain](a.png \"title x@y.com\")\n"), "a.png")
    }
}

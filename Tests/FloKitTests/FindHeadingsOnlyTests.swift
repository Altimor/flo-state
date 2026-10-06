import XCTest
import FloCore
@testable import FloKit

final class FindHeadingsOnlyTests: XCTestCase {
    let doc = Text("# Alpha notes\nalpha in the body\nBeta section\n===\nbeta in the body\n- gamma item\n---\n## Gamma\n")

    func matches(_ q: String, headingsOnly: Bool) -> Int {
        var fq = FindQuery(search: q)
        fq.headingsOnly = headingsOnly
        return fq.matchAll(doc)?.count ?? -1
    }

    func testOnlyHeadingLinesMatch() {
        XCTAssertEqual(matches("alpha", headingsOnly: false), 2)
        XCTAssertEqual(matches("alpha", headingsOnly: true), 1)   // ATX
        XCTAssertEqual(matches("beta", headingsOnly: true), 1)    // setext (===)
        XCTAssertEqual(matches("gamma", headingsOnly: true), 1)   // the list item over --- isn't a heading
    }

    func testCountAndOverviewFollowTheToggle() {
        let st = EditorState(doc: doc)
        XCTAssertEqual(FindCount.matchInfo(st, "body", headingsOnly: true)?.total, 0)
        XCTAssertEqual(FindCount.matchInfo(st, "body", headingsOnly: false)?.total, 2)
        XCTAssertEqual(FindCount.collect(st, "gamma", headingsOnly: true)?.ranges.count, 1)
    }
}

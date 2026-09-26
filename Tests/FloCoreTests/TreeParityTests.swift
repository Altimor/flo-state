import XCTest
@testable import FloCore

/// Every syntax tree must match the real Flo State (Lezer + GFM + custom
/// extensions) node for node: same names, same UTF-16 ranges, same nesting.
final class TreeParityTests: XCTestCase {
    func testTreesMatchOracle() {
        let cases = Fixtures.json("trees.json") as! [[String: Any]]
        var failures: [String] = []
        var checked = 0
        for c in cases {
            guard (c["complete"] as? Bool) == true else { continue }
            let name = c["name"] as! String
            let doc = c["doc"] as! String
            let expected = (c["tree"] as! [[Any]]).map { ($0[0] as! String, $0[1] as! Int, $0[2] as! Int, $0[3] as! Int) }
            let got = FloMarkdown.parse(doc).dump()
            checked += 1
            if got.count != expected.count || zip(got, expected).contains(where: { $0 != $1 }) {
                let idx = zip(got, expected).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? min(got.count, expected.count)
                let e = idx < expected.count ? "\(expected[idx])" : "<end>"
                let g = idx < got.count ? "\(got[idx])" : "<end>"
                failures.append("\(name): node #\(idx) expected \(e) got \(g)")
            }
        }
        let report = failures.prefix(40).joined(separator: "\n")
        print("TREE PARITY: \(checked - failures.count)/\(checked) match")
        XCTAssert(failures.isEmpty, "\(failures.count)/\(checked) trees differ:\n\(report)")
    }
}

import Foundation

enum Fixtures {
    static let dir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    static func json(_ name: String) -> Any {
        let data = try! Data(contentsOf: dir.appendingPathComponent(name))
        return try! JSONSerialization.jsonObject(with: data)
    }
}

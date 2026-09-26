import Foundation

/// Public access to FloCore resource directories for FloKit (KaTeX, mermaid).
public enum FloResourcesProxy {
    public static func url(_ subdirectory: String) -> URL? {
        let b = FloResources.bundle
        for base in [b.resourceURL, b.bundleURL, b.bundleURL.appendingPathComponent("Contents/Resources")].compactMap({ $0 }) {
            let u = base.appendingPathComponent("Resources").appendingPathComponent(subdirectory)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

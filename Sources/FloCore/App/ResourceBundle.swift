import Foundation

/// FloCore's resource bundle. In a signed .app the SwiftPM bundle lives in
/// Contents/Resources (codesign forbids extra items at the bundle root, where
/// `Bundle.module` looks first); elsewhere fall back to `Bundle.module`.
enum FloResources {
    static let bundle: Bundle = {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("FloStateNative_FloCore.bundle"),
           let b = Bundle(url: res) { return b }
        return Bundle.module
    }()
}

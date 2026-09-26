// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FloStateNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FloStateNative", targets: ["FloStateNative"]),
        .library(name: "FloCore", targets: ["FloCore"]),
        .library(name: "FloKit", targets: ["FloKit"]),
    ],
    targets: [
        .target(name: "FloCore", resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "FloKit", dependencies: ["FloCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FloStateNative", dependencies: ["FloKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Shared test helpers (synthetic documents), no dependencies.
        .target(name: "FloTestSupport", path: "Tests/FloTestSupport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FloCoreTests", dependencies: ["FloCore", "FloTestSupport"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FloKitTests", dependencies: ["FloKit", "FloTestSupport"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FloStateNativeTests", dependencies: ["FloStateNative", "FloTestSupport"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

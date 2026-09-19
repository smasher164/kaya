// swift-tools-version: 6.0
// tools/check-pins.py; docs/measurements/swift-executor-2026-09-18.md
import PackageDescription

let package = Package(
    name: "Kaya",
    platforms: [.macOS(.v13), .iOS(.v16)],
    // Static: the guests link the archive beside libkaya, so the
    // product has to BE an archive rather than a module alone.
    products: [.library(name: "Kaya", type: .static, targets: ["Kaya"])],
    targets: [
        .systemLibrary(name: "CKaya", path: "bindings/swift/CKaya"),
        .target(name: "Kaya", dependencies: ["CKaya"],
                path: "bindings/swift", exclude: ["CKaya"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)

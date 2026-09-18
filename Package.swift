// swift-tools-version: 6.0
// The Swift binding as a module, in Swift 6 language mode. The SwiftUI
// interpreter is NOT in this package: it stays on the bridging header
// in Swift 5 mode until the app-thread executor exists
// (docs/async-dialogs-plan.md §2.1); tools/check-pins.py holds both
// halves.
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

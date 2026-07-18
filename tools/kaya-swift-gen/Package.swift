// swift-tools-version: 5.10
// The Swift arm of the generator family is an SPM package for the
// TOOL only — guests stay bare swiftc (SPM-for-guests is deferred to
// packaging). SPM itself runs outside the nix DEVELOPER_DIR, the same
// escape hatch swift-typecheck.sh documents: nix's apple-sdk has no
// SPM on darwin. swift-syntax is pinned by Package.resolved.
import PackageDescription

let package = Package(
    name: "kaya-swift-gen",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.0")
    ],
    targets: [
        .executableTarget(
            name: "kaya-swift-gen",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources"
        )
    ]
)

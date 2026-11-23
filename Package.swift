// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarbageCollector",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (scanner, tree, treemap, safety rules) — testable without UI.
        .target(name: "ScanCore"),
        .executableTarget(name: "GarbageCollector", dependencies: ["ScanCore"]),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),
    ]
)

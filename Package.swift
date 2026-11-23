// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarbageCollector",
    platforms: [.macOS(.v14)],
    targets: [
        // Lógica pura (scanner, árvore, treemap, regras de segurança) — testável sem UI.
        .target(name: "ScanCore"),
        .executableTarget(name: "GarbageCollector", dependencies: ["ScanCore"]),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),
    ]
)

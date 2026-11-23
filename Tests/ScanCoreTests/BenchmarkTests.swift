import Darwin
import Foundation
import Testing
import ScanCore

/// Measurement on a real directory (read-only). Disabled by default; to run it:
///
///     GC_BENCH_PATH=~/Library swift test -c release -Xswiftc -enable-testing --filter benchmark
@Suite struct BenchmarkTests {
    private static let path = ProcessInfo.processInfo.environment["GC_BENCH_PATH"]

    @Test(.enabled(if: BenchmarkTests.path != nil))
    func benchmarkRealDirectory() throws {
        let path = (try #require(Self.path) as NSString).expandingTildeInPath
        let result = try Scanner.scan(path: path)

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let root = result.root
        print("""
        [bench] \(path)
        [bench] total=\(root.size / (1 << 20)) MiB files=\(root.fileCount) directories=\(result.directoryCount) \
        issues=\(result.issueCount)
        [bench] time=\(String(format: "%.2f", result.duration))s peak memory=\(usage.ru_maxrss / (1 << 20)) MiB
        """)
        for child in root.children.prefix(8) {
            print("[bench]   \(child.size / (1 << 20)) MiB  \(child.isAggregate ? "(small files)" : child.name)")
        }
        #expect(root.size > 0)
    }
}

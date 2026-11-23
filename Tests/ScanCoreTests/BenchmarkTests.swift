import Darwin
import Foundation
import Testing
import ScanCore

/// Medição em uma pasta real (somente leitura). Desligado por padrão; para rodar:
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
        [bench] total=\(root.size / (1 << 20)) MiB arquivos=\(root.fileCount) pastas=\(result.directoryCount) \
        problemas=\(result.issueCount)
        [bench] tempo=\(String(format: "%.2f", result.duration))s pico de memória=\(usage.ru_maxrss / (1 << 20)) MiB
        """)
        for child in root.children.prefix(8) {
            print("[bench]   \(child.size / (1 << 20)) MiB  \(child.isAggregate ? "(arquivos pequenos)" : child.name)")
        }
        #expect(root.size > 0)
    }
}

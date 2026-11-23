import Darwin
import Foundation
import Testing
@testable import ScanCore

private let mb = Fixture.megabyte
private let options = ScanOptions(smallFileThreshold: 256 * 1024, workerCount: 4)

private func child(_ node: FileNode, _ name: String) -> FileNode? {
    node.children.first { $0.name == name && !$0.isAggregate }
}

@Suite struct ScannerTests {
    @Test func totalsMatchDu() throws {
        let fx = try Fixture()
        try fx.writeFile("a/big.bin", bytes: 3 * mb)
        try fx.writeFile("a/nested/deep/medium.bin", bytes: mb)
        try fx.writeFile("b/other.bin", bytes: 2 * mb)
        for index in 0..<40 { try fx.writeFile("b/small/\(index).txt", bytes: 3000 + index * 100) }

        let result = try Scanner.scan(path: fx.root, options: options)

        #expect(result.root.size == (try fx.duBytes()))
        #expect(child(result.root, "a")?.size == (try fx.duBytes("a")))
        #expect(child(result.root, "b")?.size == (try fx.duBytes("b")))
        #expect(result.root.fileCount == 43)
        #expect(result.issueCount == 0)
    }

    @Test func childrenAreSortedBySizeAndLinkedToParent() throws {
        let fx = try Fixture()
        try fx.writeFile("small/x.bin", bytes: mb)
        try fx.writeFile("large/x.bin", bytes: 4 * mb)
        try fx.writeFile("medium/x.bin", bytes: 2 * mb)

        let root = try Scanner.scan(path: fx.root, options: options).root

        #expect(root.children.map(\.name) == ["large", "medium", "small"])
        let large = try #require(child(root, "large"))
        let file = try #require(child(large, "x.bin"))
        #expect(file.kind == .file)
        #expect(file.path == fx.path("large/x.bin"))
        #expect(file.ancestry.map(\.displayName) == [(fx.root as NSString).lastPathComponent, "large", "x.bin"])
    }

    @Test func smallFilesAreAggregatedPerDirectory() throws {
        let fx = try Fixture()
        try fx.writeFile("big.bin", bytes: mb)
        for index in 0..<10 { try fx.writeFile("s\(index).txt", bytes: 5000) }

        let root = try Scanner.scan(path: fx.root, options: options).root

        let bucket = try #require(root.children.first { $0.kind == .smallFiles })
        #expect(bucket.fileCount == 10)
        #expect(bucket.size == 10 * 8192) // 5000 bytes take up 2 blocks of 4 KiB
        #expect(root.children.count == 2)
        #expect(bucket.path == fx.root)
    }

    @Test func sparseFilesCountAllocatedNotLogicalSize() throws {
        let fx = try Fixture()
        try fx.writeSparseFile("sparse.img", logicalBytes: 500 * mb)
        try fx.writeFile("real.bin", bytes: mb)

        let root = try Scanner.scan(path: fx.root, options: options).root

        #expect(root.size < 2 * Int64(mb))
        #expect(root.size == (try fx.duBytes()))
        #expect(child(root, "sparse.img") == nil) // ~0 allocated: falls into the aggregate
    }

    @Test func hardlinksAreCountedOnce() throws {
        let fx = try Fixture()
        try fx.writeFile("one/data.bin", bytes: 2 * mb)
        try fx.makeDirectory("two")
        #expect(link(fx.path("one/data.bin"), fx.path("two/link.bin")) == 0)

        let root = try Scanner.scan(path: fx.root, options: options).root

        #expect(root.size == (try fx.duBytes()))
        #expect(root.size < 3 * Int64(mb))
        #expect(root.fileCount == 2)
    }

    @Test func symlinksAreNotFollowed() throws {
        let fx = try Fixture()
        let outside = try Fixture()
        try outside.writeFile("huge.bin", bytes: 4 * mb)
        try fx.writeFile("mine.bin", bytes: mb)
        #expect(symlink(outside.root, fx.path("escape")) == 0)
        #expect(symlink(fx.root, fx.path("loop")) == 0)

        let root = try Scanner.scan(path: fx.root, options: options).root

        #expect(root.size < 2 * Int64(mb))
        #expect(root.size == (try fx.duBytes()))
        #expect(!root.children.contains { $0.kind == .directory })
    }

    @Test func unreadableDirectoryIsReportedNotFatal() throws {
        let fx = try Fixture()
        try fx.writeFile("ok/data.bin", bytes: mb)
        try fx.writeFile("locked/secret.bin", bytes: mb)
        #expect(chmod(fx.path("locked"), 0o000) == 0)

        let result = try Scanner.scan(path: fx.root, options: options)

        let locked = try #require(child(result.root, "locked"))
        #expect(locked.issue == .permissionDenied)
        #expect(locked.children.isEmpty)
        #expect(result.issueCount == 1)
        #expect(result.issues.first?.path == fx.path("locked"))
        #expect(child(result.root, "ok")?.issue == nil)
    }

    @Test func rejectsMissingPathsAndFiles() throws {
        let fx = try Fixture()
        try fx.writeFile("file.bin", bytes: 10)

        #expect(throws: ScanError.notFound(fx.path("nope"))) {
            try Scanner.scan(path: fx.path("nope"))
        }
        #expect(throws: ScanError.notADirectory(fx.path("file.bin"))) {
            try Scanner.scan(path: fx.path("file.bin"))
        }
    }

    @Test func unreadableRootThrows() throws {
        let fx = try Fixture()
        try fx.makeDirectory("locked")
        #expect(chmod(fx.path("locked"), 0o000) == 0)

        #expect(throws: ScanError.cannotRead(fx.path("locked"))) {
            try Scanner.scan(path: fx.path("locked"))
        }
    }

    @Test func cancellationStopsTheScan() throws {
        let fx = try Fixture()
        try fx.writeFile("a/b/c.bin", bytes: 10)
        let progress = ScanProgress()
        progress.cancel()

        #expect(throws: ScanError.cancelled) {
            try Scanner.scan(path: fx.root, options: options, progress: progress)
        }
    }

    @Test func progressCountsEverything() throws {
        let fx = try Fixture()
        try fx.writeFile("a/one.bin", bytes: mb)
        try fx.writeFile("a/b/two.bin", bytes: 100)
        let progress = ScanProgress()

        let result = try Scanner.scan(path: fx.root, options: options, progress: progress)

        let snapshot = progress.snapshot()
        #expect(snapshot.files == 2)
        #expect(snapshot.directories == 3)
        #expect(result.directoryCount == 3)
        #expect(snapshot.bytes == result.root.size)
    }

    @Test func emptyDirectory() throws {
        let fx = try Fixture()
        let root = try Scanner.scan(path: fx.root, options: options).root
        #expect(root.children.isEmpty)
        #expect(root.fileCount == 0)
        #expect(root.size == (try fx.duBytes()))
    }

    /// Many directories with few threads and vice versa: exercises the work queue.
    @Test(arguments: [1, 2, 16]) func wideTreeWithDifferentWorkerCounts(workers: Int) throws {
        let fx = try Fixture()
        for a in 0..<12 {
            for b in 0..<12 { try fx.writeFile("d\(a)/e\(b)/f.txt", bytes: 100) }
        }
        let result = try Scanner.scan(
            path: fx.root,
            options: ScanOptions(smallFileThreshold: 256 * 1024, workerCount: workers)
        )
        #expect(result.root.fileCount == 144)
        #expect(result.directoryCount == 1 + 12 + 144)
        #expect(result.root.size == (try fx.duBytes()))
    }
}

@Suite struct TreeEditorTests {
    @Test func removeDiscountsAllAncestors() throws {
        let fx = try Fixture()
        try fx.writeFile("a/b/big.bin", bytes: 3 * mb)
        try fx.writeFile("a/keep.bin", bytes: mb)
        try fx.writeFile("z/other.bin", bytes: 2 * mb)
        let root = try Scanner.scan(path: fx.root, options: options).root
        let a = try #require(child(root, "a"))
        let b = try #require(child(a, "b"))
        let before = (root: root.size, a: a.size, files: root.fileCount)
        #expect(root.children.first === a)

        TreeEditor.remove(b)

        #expect(child(a, "b") == nil)
        #expect(a.size == before.a - b.size)
        #expect(root.size == before.root - b.size)
        #expect(root.fileCount == before.files - 1)
        #expect(b.parent == nil)
        // "a" shrank and is now smaller than "z": the sibling order is recomputed.
        #expect(root.children.map(\.name) == ["z", "a"])
    }

    @Test func expandSmallFilesListsThemWithoutChangingTotals() throws {
        let fx = try Fixture()
        try fx.writeFile("big.bin", bytes: mb)
        for index in 1...6 { try fx.writeFile("s\(index).txt", bytes: index * 10_000) }
        let root = try Scanner.scan(path: fx.root, options: options).root
        let total = root.size

        #expect(TreeEditor.expandSmallFiles(in: root, limit: 4))

        #expect(root.size == total)
        #expect(root.children.filter { $0.kind == .file }.map(\.name) == ["big.bin", "s6.txt", "s5.txt", "s4.txt", "s3.txt"])
        let remainder = try #require(root.children.first { $0.kind == .remainder })
        #expect(remainder.fileCount == 2)
        #expect(root.children.reduce(Int64(0)) { $0 + $1.size } + 0 <= total)
        #expect(!root.children.contains { $0.kind == .smallFiles })
        #expect(!TreeEditor.expandSmallFiles(in: root)) // nothing left to expand
        #expect(child(root, "s6.txt")?.path == fx.path("s6.txt"))
    }

    @Test func expandWithRoomForEverythingLeavesNoRemainder() throws {
        let fx = try Fixture()
        for index in 1...3 { try fx.writeFile("s\(index).txt", bytes: 1000) }
        let root = try Scanner.scan(path: fx.root, options: options).root

        #expect(TreeEditor.expandSmallFiles(in: root))

        #expect(root.children.count == 3)
        #expect(root.children.allSatisfy { $0.kind == .file })
    }

    @Test func largestFilesAcrossTheTree() throws {
        let fx = try Fixture()
        try fx.writeFile("a/five.bin", bytes: 5 * mb)
        try fx.writeFile("a/b/c/three.bin", bytes: 3 * mb)
        try fx.writeFile("d/four.bin", bytes: 4 * mb)
        try fx.writeFile("d/one.bin", bytes: mb)
        try fx.writeFile("tiny.txt", bytes: 10)
        let root = try Scanner.scan(path: fx.root, options: options).root

        #expect(TreeEditor.largestFiles(under: root, limit: 3).map(\.name) == ["five.bin", "four.bin", "three.bin"])
        #expect(TreeEditor.largestFiles(under: root, limit: 50).count == 4)
        #expect(TreeEditor.largestFiles(under: root, limit: 1).map(\.name) == ["five.bin"])
    }
}

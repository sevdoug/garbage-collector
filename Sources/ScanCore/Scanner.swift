import Darwin
import Foundation
import os

public struct ScanOptions: Sendable {
    /// Files smaller than this do not become individual nodes: they are summed into one aggregate per directory.
    /// This is what keeps memory under control on disks with millions of files.
    public var smallFileThreshold: Int64
    public var workerCount: Int
    /// How many issues (unreadable directories etc.) to keep with their path; the total is always counted.
    public var maxRecordedIssues: Int

    public init(
        smallFileThreshold: Int64 = 1 << 20,
        // Measured: above ~4–6 threads the kernel becomes the bottleneck and the time stops dropping.
        workerCount: Int = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount)),
        maxRecordedIssues: Int = 2000
    ) {
        self.smallFileThreshold = smallFileThreshold
        self.workerCount = max(1, workerCount)
        self.maxRecordedIssues = maxRecordedIssues
    }
}

/// Progress counters, safe to read from any thread while the scan runs.
public final class ScanProgress: Sendable {
    public struct Snapshot: Sendable {
        public var files = 0
        public var directories = 0
        public var bytes: Int64 = 0
        public var currentPath = ""

        public init() {}
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func snapshot() -> Snapshot { state.withLock { $0 } }
    public func cancel() { cancelled.withLock { $0 = true } }
    public var isCancelled: Bool { cancelled.withLock { $0 } }

    func recordDirectory(path: String, files: Int, bytes: Int64) {
        state.withLock {
            $0.directories += 1
            $0.files += files
            $0.bytes += bytes
            $0.currentPath = path
        }
    }
}

public struct ScanIssue: Sendable, Identifiable {
    public let path: String
    public let kind: FileNode.Issue
    public var id: String { path }
}

public struct ScanResult: Sendable {
    public let root: FileNode
    /// Sample of the issues found (capped by `ScanOptions.maxRecordedIssues`).
    public let issues: [ScanIssue]
    public let issueCount: Int
    public let directoryCount: Int
    public let duration: TimeInterval
}

public enum ScanError: Error, Equatable {
    case notFound(String)
    case notADirectory(String)
    case cannotRead(String)
    case cancelled
}

public enum Scanner {
    /// Walks `path` and returns the tree with aggregated sizes. Blocks until done:
    /// call it off the main thread.
    ///
    /// Counting rules (the same as `du`):
    /// - size allocated on disk, not the logical size;
    /// - hardlinks count only once (the first path found gets the size);
    /// - symbolic links are never followed;
    /// - does not cross into other volumes or list directories that exist only in the cloud.
    public static func scan(
        path: String,
        options: ScanOptions = ScanOptions(),
        progress: ScanProgress = ScanProgress()
    ) throws -> ScanResult {
        let started = Date()

        guard let resolved = realpath(path, nil) else { throw ScanError.notFound(path) }
        let rootPath = String(cString: resolved)
        free(resolved)

        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw ScanError.notFound(rootPath) }
        guard DirectoryReader.fileType(st) == S_IFDIR else { throw ScanError.notADirectory(rootPath) }

        let root = FileNode(name: rootPath, kind: .directory, size: DirectoryReader.allocatedSize(st))
        let session = Session(rootDevice: st.st_dev, options: options, progress: progress)
        session.queue.finish(pushing: [Work(node: root, path: rootPath)], startedOne: false)

        let group = DispatchGroup()
        for index in 0..<options.workerCount {
            group.enter()
            let thread = Thread {
                session.runWorker()
                group.leave()
            }
            thread.name = "scan-worker-\(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()

        if progress.isCancelled { throw ScanError.cancelled }
        if root.issue != nil { throw ScanError.cannotRead(rootPath) }

        let directoryCount = aggregate(root)
        let (issues, issueCount) = session.collectedIssues()
        return ScanResult(
            root: root,
            issues: issues,
            issueCount: issueCount,
            directoryCount: directoryCount,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Sums sizes and counts bottom-up and sorts the children. Returns the total number of directories.
    private static func aggregate(_ root: FileNode) -> Int {
        // Breadth-first order: every parent appears before its children; walking it in reverse,
        // each directory finds its children already totaled. No recursion (trees can be deep).
        var directories: [FileNode] = [root]
        var index = 0
        while index < directories.count {
            for child in directories[index].children where child.kind == .directory {
                directories.append(child)
            }
            index += 1
        }
        for directory in directories.reversed() {
            var size = directory.size // starts with the directory's own blocks
            var count = 0
            for child in directory.children {
                size += child.size
                count += child.fileCount
            }
            directory.size = size
            directory.fileCount = count
            FileNode.sortBySize(&directory.children)
        }
        return directories.count
    }
}

// MARK: - Scan session

private struct Work {
    let node: FileNode
    let path: String
}

private struct FileID: Hashable {
    let device: dev_t
    let inode: ino_t
}

/// Shared stack of pending directories. The scan ends when the stack is empty
/// and no thread is in the middle of a directory (which could still push subdirectories).
private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [Work] = []
    private var active = 0
    private var stopped = false

    func pop() -> Work? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stopped { return nil }
            if let work = stack.popLast() {
                active += 1
                return work
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    func finish(pushing items: [Work], startedOne: Bool = true) {
        condition.lock()
        stack.append(contentsOf: items)
        if startedOne { active -= 1 }
        if !items.isEmpty || active == 0 { condition.broadcast() }
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class Session: @unchecked Sendable {
    let queue = WorkQueue()
    private let rootDevice: dev_t
    private let options: ScanOptions
    private let progress: ScanProgress
    private let seenHardlinks = OSAllocatedUnfairLock(initialState: Set<FileID>())
    private let issues = OSAllocatedUnfairLock(initialState: (list: [ScanIssue](), count: 0))

    init(rootDevice: dev_t, options: ScanOptions, progress: ScanProgress) {
        self.rootDevice = rootDevice
        self.options = options
        self.progress = progress
    }

    func collectedIssues() -> ([ScanIssue], Int) {
        issues.withLock { ($0.list, $0.count) }
    }

    func runWorker() {
        // Extra safeguard: on this thread, never trigger the download of items that exist only in the cloud.
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
        while let work = queue.pop() {
            if progress.isCancelled {
                queue.stop()
                return
            }
            queue.finish(pushing: process(work))
        }
    }

    private func mark(_ node: FileNode, _ kind: FileNode.Issue, path: String) {
        node.issue = kind
        let limit = options.maxRecordedIssues
        issues.withLock {
            $0.count += 1
            if $0.list.count < limit { $0.list.append(ScanIssue(path: path, kind: kind)) }
        }
    }

    /// Reads a directory, creates the child nodes, and returns the subdirectories to traverse.
    private func process(_ work: Work) -> [Work] {
        let prefix = work.path.hasSuffix("/") ? work.path : work.path + "/"
        let threshold = options.smallFileThreshold
        var children: [FileNode] = []
        var subdirectories: [Work] = []
        var smallCount = 0
        var smallBytes: Int64 = 0
        var fileCount = 0
        var fileBytes: Int64 = 0

        do {
            try DirectoryReader.forEachEntry(atPath: work.path) { cname, st in
                let type = DirectoryReader.fileType(st)

                if type == S_IFDIR {
                    let name = String(cString: cname)
                    let child = FileNode(name: name, kind: .directory, size: 0)
                    child.parent = work.node
                    children.append(child)
                    let childPath = prefix + name
                    if st.st_dev != rootDevice {
                        // Mount point: the contents belong to another volume.
                        mark(child, .otherVolume, path: childPath)
                    } else if DirectoryReader.isDataless(st) {
                        mark(child, .cloudOnly, path: childPath)
                    } else {
                        child.size = DirectoryReader.allocatedSize(st)
                        subdirectories.append(Work(node: child, path: childPath))
                    }
                    return
                }

                var size = DirectoryReader.allocatedSize(st)
                if st.st_nlink > 1 {
                    let id = FileID(device: st.st_dev, inode: st.st_ino)
                    let firstSighting = seenHardlinks.withLock { $0.insert(id).inserted }
                    if !firstSighting { size = 0 }
                }
                fileCount += 1
                fileBytes += size

                if size >= threshold {
                    let kind: FileNode.Kind = type == S_IFREG ? .file : (type == S_IFLNK ? .symlink : .other)
                    let child = FileNode(name: String(cString: cname), kind: kind, size: size, fileCount: 1)
                    child.parent = work.node
                    children.append(child)
                } else {
                    smallCount += 1
                    smallBytes += size
                }
            }
        } catch {
            mark(work.node, error == .permissionDenied ? .permissionDenied : .unreadable, path: work.path)
            progress.recordDirectory(path: work.path, files: 0, bytes: 0)
            return []
        }

        if smallCount > 0 {
            let bucket = FileNode(name: "", kind: .smallFiles, size: smallBytes, fileCount: smallCount)
            bucket.parent = work.node
            children.append(bucket)
        }
        work.node.children = children
        progress.recordDirectory(path: work.path, files: fileCount, bytes: fileBytes + work.node.size)
        return subdirectories
    }
}

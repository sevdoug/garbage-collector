import Foundation

/// An item in the scanned tree: a directory, a large file, or an aggregate of small files.
///
/// Concurrency model: during the scan, each node is written by a single worker thread
/// (the one processing the directory that owns it). Once `Scanner.scan` returns, the tree may only
/// be read or modified from a single context (in the app, the MainActor). Hence the
/// `@unchecked Sendable`: exclusion is guaranteed by the usage protocol, not by locks.
public final class FileNode: @unchecked Sendable, Identifiable {
    public enum Kind: UInt8, Sendable {
        case directory
        case file
        case symlink
        case other
        /// Aggregate of the files below the size threshold; can be expanded on demand.
        case smallFiles
        /// What is left of an aggregate after it was expanded (cannot be expanded again).
        case remainder
    }

    /// Reason why a directory was not traversed.
    public enum Issue: UInt8, Sendable {
        case permissionDenied
        case unreadable
        case otherVolume
        case cloudOnly
    }

    /// Item name. At the root, it is the absolute path of the scanned directory.
    public let name: String
    public let kind: Kind
    /// `weak` on purpose: a node held by the UI after being removed from the tree degrades to a
    /// relative path (which the Trash guard rejects) instead of crashing the app.
    public internal(set) weak var parent: FileNode?
    /// Bytes allocated on disk, including all descendants.
    public internal(set) var size: Int64
    /// Children sorted from largest to smallest.
    public internal(set) var children: [FileNode] = []
    /// Number of files in the subtree (1 for a file, N for aggregates).
    public internal(set) var fileCount: Int
    public internal(set) var issue: Issue?

    init(name: String, kind: Kind, size: Int64, fileCount: Int = 0) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
    }

    public var isDirectory: Bool { kind == .directory }
    public var isAggregate: Bool { kind == .smallFiles || kind == .remainder }

    /// Absolute path. Aggregates do not exist on disk, so they point to the directory that contains them.
    public var path: String {
        var parts: [String] = []
        var node = self
        if node.isAggregate, let parent = node.parent { node = parent }
        while let parent = node.parent {
            parts.append(node.name)
            node = parent
        }
        var result = node.name
        for part in parts.reversed() {
            if !result.hasSuffix("/") { result += "/" }
            result += part
        }
        return result
    }

    /// Display name (at the root, the last path component).
    public var displayName: String {
        guard parent == nil else { return name }
        if name == "/" { return "/" }
        return (name as NSString).lastPathComponent
    }

    /// Chain from the root down to this node, inclusive.
    public var ancestry: [FileNode] {
        var chain: [FileNode] = [self]
        var node = self
        while let parent = node.parent {
            chain.append(parent)
            node = parent
        }
        return chain.reversed()
    }

    public func isDescendant(of other: FileNode) -> Bool {
        var node = self
        while let parent = node.parent {
            if parent === other { return true }
            node = parent
        }
        return false
    }

    static func sortBySize(_ nodes: inout [FileNode]) {
        nodes.sort { a, b in
            if a.size != b.size { return a.size > b.size }
            // Aggregates last among ties, so the list stays stable and predictable.
            if a.isAggregate != b.isAggregate { return !a.isAggregate }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

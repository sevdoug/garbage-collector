import Darwin
import Foundation

/// Changes to the tree after the scan. Always call from the same context that reads the tree.
public enum TreeEditor {
    /// Removes the node from the tree and subtracts its size and count from every ancestor,
    /// without needing to scan again.
    public static func remove(_ node: FileNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var ancestor: FileNode? = parent
        while let current = ancestor {
            current.size = max(0, current.size - node.size)
            current.fileCount = max(0, current.fileCount - node.fileCount)
            ancestor = current.parent
        }
        // The siblings are still sorted; only the ancestors changed size among their own siblings.
        ancestor = parent
        while let current = ancestor, let grandparent = current.parent {
            FileNode.sortBySize(&grandparent.children)
            ancestor = grandparent
        }
        node.parent = nil
    }

    /// Replaces the small-files aggregate of `directory` with its `limit` largest files, read from
    /// disk now. Whatever does not fit stays aggregated. Returns `false` if there was nothing to
    /// expand or if the directory could not be read.
    ///
    /// The directory total does not change: the remaining aggregate absorbs the difference. With hardlinks
    /// (counted only once in the scan) the sum of the children can slightly exceed the directory total.
    @discardableResult
    public static func expandSmallFiles(in directory: FileNode, limit: Int = 1000) -> Bool {
        guard let bucket = directory.children.first(where: { $0.kind == .smallFiles }) else { return false }
        let known = Set(directory.children.lazy.filter { !$0.isAggregate }.map(\.name))

        var found: [FileNode] = []
        do {
            try DirectoryReader.forEachEntry(atPath: directory.path) { cname, st in
                let type = DirectoryReader.fileType(st)
                guard type != S_IFDIR else { return }
                let name = String(cString: cname)
                guard !known.contains(name) else { return }
                let kind: FileNode.Kind = type == S_IFREG ? .file : (type == S_IFLNK ? .symlink : .other)
                found.append(FileNode(name: name, kind: kind, size: DirectoryReader.allocatedSize(st), fileCount: 1))
            }
        } catch {
            return false
        }

        FileNode.sortBySize(&found)
        let shown = Array(found.prefix(limit))
        let shownBytes = shown.reduce(Int64(0)) { $0 + $1.size }
        let leftoverCount = max(0, max(bucket.fileCount, found.count) - shown.count)
        let leftoverBytes = max(0, bucket.size - shownBytes)

        directory.children.removeAll { $0 === bucket }
        bucket.parent = nil
        for node in shown { node.parent = directory }
        directory.children.append(contentsOf: shown)
        if found.count > shown.count, leftoverCount > 0 {
            let remainder = FileNode(name: "", kind: .remainder, size: leftoverBytes, fileCount: leftoverCount)
            remainder.parent = directory
            directory.children.append(remainder)
        }
        FileNode.sortBySize(&directory.children)
        return true
    }

    /// The `limit` largest files in the subtree, from largest to smallest.
    public static func largestFiles(under root: FileNode, limit: Int = 200) -> [FileNode] {
        var result: [FileNode] = []
        var smallestKept: Int64 = 0
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            for child in node.children {
                if child.kind == .directory {
                    // Children are sorted: if the whole directory is smaller than the cutoff, nothing in it qualifies.
                    if result.count < limit || child.size > smallestKept { stack.append(child) }
                } else if !child.isAggregate, result.count < limit || child.size > smallestKept {
                    result.append(child)
                    if result.count >= limit * 2 {
                        FileNode.sortBySize(&result)
                        result.removeSubrange(limit...)
                        smallestKept = result.last?.size ?? 0
                    }
                }
            }
        }
        FileNode.sortBySize(&result)
        return Array(result.prefix(limit))
    }
}

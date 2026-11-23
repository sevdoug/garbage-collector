import Darwin
import Foundation

/// Alterações na árvore depois do scan. Chame sempre do mesmo contexto que lê a árvore.
public enum TreeEditor {
    /// Tira o nó da árvore e desconta tamanho e contagem de todos os ancestrais,
    /// sem precisar escanear de novo.
    public static func remove(_ node: FileNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var ancestor: FileNode? = parent
        while let current = ancestor {
            current.size = max(0, current.size - node.size)
            current.fileCount = max(0, current.fileCount - node.fileCount)
            ancestor = current.parent
        }
        // Os irmãos continuam ordenados; só os ancestrais mudaram de tamanho entre os irmãos deles.
        ancestor = parent
        while let current = ancestor, let grandparent = current.parent {
            FileNode.sortBySize(&grandparent.children)
            ancestor = grandparent
        }
        node.parent = nil
    }

    /// Troca o agregado de arquivos pequenos de `directory` pelos `limit` maiores, lidos do disco
    /// agora. O que não couber continua agregado. Devolve `false` se não havia o que detalhar
    /// ou se a pasta não pôde ser lida.
    ///
    /// O total da pasta não muda: o agregado restante absorve a diferença. Com hardlinks
    /// (contados uma vez só no scan) a soma dos filhos pode passar um pouco do total da pasta.
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

    /// Os `limit` maiores arquivos da subárvore, do maior para o menor.
    public static func largestFiles(under root: FileNode, limit: Int = 200) -> [FileNode] {
        var result: [FileNode] = []
        var smallestKept: Int64 = 0
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            for child in node.children {
                if child.kind == .directory {
                    // Filhos estão ordenados: se a pasta inteira é menor que o corte, nada nela entra.
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

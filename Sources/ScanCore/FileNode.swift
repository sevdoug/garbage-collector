import Foundation

/// Um item da árvore escaneada: pasta, arquivo grande ou um agregado de arquivos pequenos.
///
/// Modelo de concorrência: durante o scan, cada nó é escrito por uma única thread de trabalho
/// (a que processa a pasta dona dele). Depois que `Scanner.scan` retorna, a árvore só pode ser
/// lida ou alterada a partir de um único contexto (no app, o MainActor). Por isso o
/// `@unchecked Sendable`: a exclusão é garantida pelo protocolo de uso, não por locks.
public final class FileNode: @unchecked Sendable, Identifiable {
    public enum Kind: UInt8, Sendable {
        case directory
        case file
        case symlink
        case other
        /// Agregado dos arquivos abaixo do limite de tamanho; pode ser detalhado sob demanda.
        case smallFiles
        /// O que sobrou de um agregado depois de detalhado (não pode ser detalhado de novo).
        case remainder
    }

    /// Motivo pelo qual uma pasta não foi percorrida.
    public enum Issue: UInt8, Sendable {
        case permissionDenied
        case unreadable
        case otherVolume
        case cloudOnly
    }

    /// Nome do item. Na raiz, é o caminho absoluto da pasta escaneada.
    public let name: String
    public let kind: Kind
    /// `weak` de propósito: um nó guardado pela UI depois de removido da árvore degrada para um
    /// caminho relativo (que a trava da Lixeira recusa) em vez de derrubar o app.
    public internal(set) weak var parent: FileNode?
    /// Bytes alocados em disco, incluindo todos os descendentes.
    public internal(set) var size: Int64
    /// Filhos ordenados do maior para o menor.
    public internal(set) var children: [FileNode] = []
    /// Quantidade de arquivos na subárvore (1 para arquivo, N para agregados).
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

    /// Caminho absoluto. Agregados não existem no disco, então apontam para a pasta que os contém.
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

    /// Nome para exibição (na raiz, o último componente do caminho).
    public var displayName: String {
        guard parent == nil else { return name }
        if name == "/" { return "/" }
        return (name as NSString).lastPathComponent
    }

    /// Cadeia da raiz até este nó, inclusive.
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
            // Agregados por último entre empates, para a lista ficar estável e previsível.
            if a.isAggregate != b.isAggregate { return !a.isAggregate }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

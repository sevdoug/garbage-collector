import AppKit
import Observation
import ScanCore

/// Estado do app. A árvore (`FileNode`) não é observável: toda alteração nela incrementa
/// `revision`, e as views que mostram a árvore leem `revision` para se redesenhar.
@MainActor
@Observable
final class AppModel {
    enum Phase { case start, scanning, browsing }
    enum Tab: Hashable { case folders, largest }

    struct TrashRequest: Identifiable {
        let id = UUID()
        let nodes: [FileNode]
        /// Itens da seleção que a trava de segurança recusou, com o motivo.
        let blocked: [(name: String, reason: String)]
        var totalBytes: Int64 { nodes.reduce(0) { $0 + $1.size } }
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var phase: Phase = .start
    private(set) var result: ScanResult?
    private(set) var current: FileNode?
    private(set) var revision = 0
    private(set) var progress = ScanProgress.Snapshot()
    private(set) var scanStartedAt = Date()
    private(set) var scanningPath = ""
    private(set) var volume: VolumeInfo?
    private(set) var trashedBytes: Int64 = 0
    private(set) var trashedCount = 0
    private(set) var isTrashing = false
    /// Item que a lista deve rolar até mostrar (seleção vinda do treemap ou de "Maiores arquivos").
    private(set) var scrollTarget: FileNode.ID?

    var tab: Tab = .folders
    var selection: Set<FileNode.ID> = []
    var largestSelection: Set<FileNode.ID> = []
    var pendingTrash: TrashRequest?
    var notice: Notice?
    var showIssues = false

    @ObservationIgnored private var activeProgress: ScanProgress?
    @ObservationIgnored private var largestCache: (revision: Int, files: [FileNode])?

    init() {
        volume = VolumeInfo.forPath(NSHomeDirectory())
    }

    // MARK: - Dados derivados

    var root: FileNode? { result?.root }

    var rootLabel: String {
        guard let root else { return "" }
        if root.name == VolumePaths.dataVolume { return volume?.name ?? "Macintosh HD" }
        return root.displayName
    }

    func label(for node: FileNode) -> String {
        node.parent == nil ? rootLabel : node.name
    }

    /// Caminho como o usuário conhece (sem o prefixo do volume de dados).
    func displayPath(_ node: FileNode) -> String {
        VolumePaths.userFacing(node.path)
    }

    var largestFiles: [FileNode] {
        guard let root else { return [] }
        if let cache = largestCache, cache.revision == revision { return cache.files }
        let files = TreeEditor.largestFiles(under: root, limit: 200)
        largestCache = (revision, files)
        return files
    }

    /// Nós selecionados na aba visível.
    var selectedNodes: [FileNode] {
        switch tab {
        case .folders: (current?.children ?? []).filter { selection.contains($0.id) }
        case .largest: largestFiles.filter { largestSelection.contains($0.id) }
        }
    }

    // MARK: - Scan

    func scanHome() { startScan(path: NSHomeDirectory()) }

    func scanWholeDisk() {
        let data = VolumePaths.dataVolume
        startScan(path: FileManager.default.fileExists(atPath: data) ? data : "/")
    }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Escanear"
        panel.message = "Escolha a pasta a analisar"
        if panel.runModal() == .OK, let url = panel.url { startScan(path: url.path) }
    }

    /// Escaneia a mesma raiz de novo e volta para a pasta em que você estava (se ainda existir).
    func rescan() {
        guard let root else { return }
        let trail = (current?.ancestry ?? []).dropFirst().map(\.name)
        startScan(path: root.name, returningTo: trail)
    }

    func startScan(path: String, returningTo trail: [String] = []) {
        activeProgress?.cancel()
        let progress = ScanProgress()
        activeProgress = progress
        self.progress = ScanProgress.Snapshot()
        scanningPath = VolumePaths.userFacing(path)
        scanStartedAt = Date()
        phase = .scanning

        Task {
            let poller = Task {
                while !Task.isCancelled {
                    self.progress = progress.snapshot()
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Scanner.scan(path: path, progress: progress)
                }.value
                // Um scan mais novo pode ter começado enquanto este terminava.
                guard activeProgress === progress else { return }
                finishScan(result, returningTo: trail)
            } catch {
                guard activeProgress === progress else { return }
                activeProgress = nil
                phase = result == nil ? .start : .browsing
                if let message = Self.describe(error, path: path) {
                    notice = Notice(title: "Não foi possível escanear", message: message)
                }
            }
        }
    }

    func cancelScan() {
        activeProgress?.cancel()
    }

    private func finishScan(_ result: ScanResult, returningTo trail: [String]) {
        activeProgress = nil
        self.result = result
        // Desce pela trilha de nomes até onde ela ainda existir na árvore nova.
        var landing = result.root
        for name in trail {
            guard let next = landing.children.first(where: { $0.name == name && canOpen($0) }) else { break }
            landing = next
        }
        current = landing
        selection = []
        largestSelection = []
        largestCache = nil
        scrollTarget = nil
        tab = .folders
        volume = VolumeInfo.forPath(result.root.name)
        revision += 1
        phase = .browsing
    }

    private static func describe(_ error: Error, path: String) -> String? {
        switch error as? ScanError {
        case .cancelled: nil
        case .notFound: "A pasta \(path) não existe mais."
        case .notADirectory: "\(path) não é uma pasta."
        case .cannotRead: "Sem permissão para ler \(path). Veja se o app tem Acesso Total ao Disco nos Ajustes do Sistema."
        case nil: error.localizedDescription
        }
    }

    // MARK: - Navegação

    func canOpen(_ node: FileNode) -> Bool {
        node.isDirectory && node.issue == nil
    }

    func open(_ node: FileNode) {
        guard canOpen(node) else { return }
        current = node
        selection = []
        scrollTarget = nil
        tab = .folders
    }

    func goUp() {
        guard let child = current, let parent = child.parent else { return }
        current = parent
        selection = [child.id]
        scrollTarget = child.id
    }

    var canGoUp: Bool { tab == .folders && current?.parent != nil }

    /// Seleciona um filho da pasta atual (clique no treemap).
    func select(_ node: FileNode, extending: Bool) {
        if extending {
            if selection.contains(node.id) { selection.remove(node.id) } else { selection.insert(node.id) }
        } else {
            selection = [node.id]
        }
        scrollTarget = node.id
    }

    /// Abre a pasta que contém `node` e deixa ele selecionado.
    func showInFolder(_ node: FileNode) {
        guard let parent = node.parent else { return }
        current = parent
        selection = [node.id]
        scrollTarget = node.id
        tab = .folders
    }

    func expandSmallFiles() {
        guard let current else { return }
        if TreeEditor.expandSmallFiles(in: current) {
            revision += 1
        } else {
            notice = Notice(title: "Não foi possível detalhar", message: "A pasta não pôde ser lida agora.")
        }
    }

    // MARK: - Lixeira

    func requestTrashOfSelection() {
        requestTrash(selectedNodes)
    }

    func requestTrash(_ nodes: [FileNode]) {
        var allowed: [FileNode] = []
        var blocked: [(name: String, reason: String)] = []
        for node in nodes where !node.isAggregate {
            switch TrashGuard.evaluate(path: node.path) {
            case .allowed: allowed.append(node)
            case .denied(let reason): blocked.append((label(for: node), reason))
            }
        }
        if allowed.isEmpty {
            if !blocked.isEmpty {
                notice = Notice(
                    title: "Esses itens são protegidos",
                    message: blocked.map { "• \($0.name): \($0.reason)" }.joined(separator: "\n")
                )
            }
            return
        }
        pendingTrash = TrashRequest(nodes: allowed, blocked: blocked)
    }

    func performTrash(_ request: TrashRequest) async {
        guard !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }

        let outcomes = await Trasher.trash(paths: request.nodes.map(\.path))
        var failures: [String] = []
        var vanished = 0
        for (node, outcome) in zip(request.nodes, outcomes) {
            switch outcome {
            case .trashed:
                trashedBytes += node.size
                trashedCount += 1
                TreeEditor.remove(node)
            case .missing:
                vanished += 1
                TreeEditor.remove(node)
            case .failed(let message):
                failures.append("• \(node.name): \(message)")
            }
        }
        selection = []
        largestSelection = []
        revision += 1

        if !failures.isEmpty {
            notice = Notice(title: "Alguns itens não foram movidos", message: failures.joined(separator: "\n"))
        } else if vanished > 0 {
            notice = Notice(
                title: "Itens já removidos",
                message: "\(Format.items(vanished)) já não existia no disco e saiu da lista."
            )
        }
    }
}

import AppKit
import Observation
import ScanCore

/// App state. The tree (`FileNode`) is not observable: every change to it bumps `revision`,
/// and the views that show the tree read `revision` so they redraw.
@MainActor
@Observable
final class AppModel {
    enum Phase { case start, scanning, browsing }
    enum Tab: Hashable { case folders, largest }

    struct TrashRequest: Identifiable {
        let id = UUID()
        let nodes: [FileNode]
        /// Items of the selection the safety guard refused, with the reason.
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
    /// Item the list should scroll into view (selection coming from the treemap or "Largest Files").
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

    // MARK: - Derived data

    var root: FileNode? { result?.root }

    var rootLabel: String {
        guard let root else { return "" }
        if root.name == VolumePaths.dataVolume { return volume?.name ?? "Macintosh HD" }
        return root.displayName
    }

    func label(for node: FileNode) -> String {
        node.parent == nil ? rootLabel : node.name
    }

    /// Path as the user knows it (without the data-volume prefix).
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

    /// Nodes selected in the visible tab.
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
        panel.prompt = String(localized: "Scan")
        panel.message = String(localized: "Choose the folder to analyze")
        if panel.runModal() == .OK, let url = panel.url { startScan(path: url.path) }
    }

    /// Scans the same root again and returns to the folder you were in (if it still exists).
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
                // A newer scan may have started while this one was finishing.
                guard activeProgress === progress else { return }
                finishScan(result, returningTo: trail)
            } catch {
                guard activeProgress === progress else { return }
                activeProgress = nil
                phase = result == nil ? .start : .browsing
                if let message = Self.describe(error, path: path) {
                    notice = Notice(title: String(localized: "Could not scan"), message: message)
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
        // Walks down the trail of names as far as it still exists in the new tree.
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
        case .notFound: String(localized: "The folder \(path) no longer exists.")
        case .notADirectory: String(localized: "\(path) is not a folder.")
        case .cannotRead: String(localized: "No permission to read \(path). Check whether the app has Full Disk Access in System Settings.")
        case nil: error.localizedDescription
        }
    }

    // MARK: - Navigation

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

    /// Selects a child of the current folder (click on the treemap).
    func select(_ node: FileNode, extending: Bool) {
        if extending {
            if selection.contains(node.id) { selection.remove(node.id) } else { selection.insert(node.id) }
        } else {
            selection = [node.id]
        }
        scrollTarget = node.id
    }

    /// Opens the folder that contains `node` and leaves it selected.
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
            notice = Notice(title: String(localized: "Could not expand"), message: String(localized: "The folder could not be read right now."))
        }
    }

    // MARK: - Trash

    func requestTrashOfSelection() {
        requestTrash(selectedNodes)
    }

    func requestTrash(_ nodes: [FileNode]) {
        var allowed: [FileNode] = []
        var blocked: [(name: String, reason: String)] = []
        for node in nodes where !node.isAggregate {
            switch TrashGuard.evaluate(path: node.path) {
            case .allowed: allowed.append(node)
            case .denied(let reason): blocked.append((label(for: node), reason.message))
            }
        }
        if allowed.isEmpty {
            if !blocked.isEmpty {
                notice = Notice(
                    title: String(localized: "These items are protected"),
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
            notice = Notice(title: String(localized: "Some items were not moved"), message: failures.joined(separator: "\n"))
        } else if vanished > 0 {
            notice = Notice(
                title: String(localized: "Items already removed"),
                message: String(localized: "Already gone from disk and removed from the list: \(Format.items(vanished)).")
            )
        }
    }
}

import ScanCore
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            switch model.tab {
            case .folders:
                BreadcrumbBar()
                Divider()
                HSplitView {
                    ItemListView().frame(minWidth: 430, idealWidth: 560)
                    TreemapPanel().frame(minWidth: 300, idealWidth: 600)
                }
            case .largest:
                LargestFilesView()
            }
            Divider()
            StatusBar()
        }
        .navigationTitle(model.rootLabel)
        .navigationSubtitle(model.root.map { String(localized: "\(Format.bytes($0.size)) in \(Format.files($0.fileCount))") } ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.goUp() } label: { Label("Enclosing Folder", systemImage: "chevron.up") }
                    .disabled(!model.canGoUp)
                    .help("Enclosing folder (⌘↑)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    Text("Folders").tag(AppModel.Tab.folders)
                    Text("Largest Files").tag(AppModel.Tab.largest)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Home Folder") { model.scanHome() }
                    Button("Whole Disk") { model.scanWholeDisk() }
                    Button("Choose Folder…") { model.chooseFolderAndScan() }
                } label: {
                    Label("Scan Somewhere Else", systemImage: "scope")
                }
                .help("Scan somewhere else")
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Rescan (⌘R)")
            }
        }
        .alert(
            trashTitle,
            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
            presenting: model.pendingTrash
        ) { request in
            Button("Move to Trash", role: .destructive) {
                Task { await model.performTrash(request) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(trashMessage(request))
        }
        .sheet(isPresented: $model.showIssues) { IssuesSheet() }
    }

    private var trashTitle: String {
        guard let request = model.pendingTrash else { return "" }
        if request.nodes.count == 1 { return String(localized: "Move “\(request.nodes[0].name)” to the Trash?") }
        return String(localized: "Move \(Format.items(request.nodes.count)) to the Trash?")
    }

    private func trashMessage(_ request: AppModel.TrashRequest) -> String {
        var lines = [String(localized: "This frees about \(Format.bytes(request.totalBytes)) once the Trash is emptied.")]
        if request.nodes.count > 1 {
            let names = request.nodes.prefix(6).map { "• \($0.name)" }
            lines.append(names.joined(separator: "\n") + (request.nodes.count > 6 ? "\n• …" : ""))
        }
        if !request.blocked.isEmpty {
            lines.append(String(localized: "Protected, staying where they are: \(request.blocked.map(\.name).joined(separator: ", "))."))
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Path from the scan root to the current folder; every segment is clickable.
struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array((model.current?.ancestry ?? []).enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(model.label(for: node)) { model.open(node) }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .fontWeight(node === model.current ? .semibold : .regular)
                            .foregroundStyle(node === model.current ? .primary : .secondary)
                            .contentShape(Rectangle())
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            Spacer(minLength: 0)
            if let current = model.current {
                Text(verbatim: "\(Format.bytes(current.size)) · \(Format.files(current.fileCount))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                Button { SystemLinks.revealInFinder(current.path) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Show this folder in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        let selected = model.selectedNodes
        let bytes = selected.reduce(Int64(0)) { $0 + $1.size }
        HStack(spacing: 14) {
            if let result = model.result, result.issueCount > 0 {
                Button { model.showIssues = true } label: {
                    Label(Self.unreadable(result.issueCount), systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("Folders that could not be read are left out of the totals")
            }
            if model.trashedCount > 0 {
                HStack(spacing: 6) {
                    Text(String(localized: "In the Trash this session: \(Format.bytes(model.trashedBytes))"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Open Trash") { SystemLinks.openTrash() }
                        .buttonStyle(.link)
                        .help("The space is only freed when you empty the Trash")
                }
            }
            Spacer()
            if model.isTrashing {
                ProgressView().controlSize(.small)
            }
            Text(selected.isEmpty ? String(localized: "Nothing selected") : "\(Format.items(selected.count)) · \(Format.bytes(bytes))")
                .foregroundStyle(selected.isEmpty ? .tertiary : .primary)
                .monospacedDigit()
            Button {
                model.requestTrashOfSelection()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(selected.isEmpty || model.isTrashing)
            .help("Move the selection to the Trash (⌘⌫)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private static func unreadable(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 unreadable folder")
            : String(localized: "\(Format.count(count)) unreadable folders")
    }
}

struct IssuesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let issues = model.result?.issues ?? []
        let total = model.result?.issueCount ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text("Folders left out of the totals").font(.title3.weight(.semibold))
            Text("macOS protects some folders (Mail, Photos, other apps' data…). For the scan to see everything, give Garbage Collector Full Disk Access and scan again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(issues) { issue in
                HStack {
                    Text(VolumePaths.userFacing(issue.path))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(Self.describe(issue.kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered)
            if total > issues.count {
                Text(String(localized: "Showing \(Format.count(issues.count)) of \(Format.count(total))."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Privacy Settings…") { SystemLinks.openFullDiskAccessSettings() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
    }

    static func describe(_ kind: FileNode.Issue) -> String {
        switch kind {
        case .permissionDenied: String(localized: "no permission")
        case .unreadable: String(localized: "read error")
        case .otherVolume: String(localized: "other volume")
        case .cloudOnly: String(localized: "cloud only")
        }
    }
}

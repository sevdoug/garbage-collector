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
        .navigationSubtitle(model.root.map { "\(Format.bytes($0.size)) em \(Format.files($0.fileCount))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.goUp() } label: { Label("Pasta acima", systemImage: "chevron.up") }
                    .disabled(!model.canGoUp)
                    .help("Pasta acima (⌘↑)")
            }
            ToolbarItem(placement: .principal) {
                Picker("Visão", selection: $model.tab) {
                    Text("Pastas").tag(AppModel.Tab.folders)
                    Text("Maiores arquivos").tag(AppModel.Tab.largest)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Pasta pessoal") { model.scanHome() }
                    Button("Disco inteiro") { model.scanWholeDisk() }
                    Button("Escolher pasta…") { model.chooseFolderAndScan() }
                } label: {
                    Label("Escanear outro lugar", systemImage: "scope")
                }
                .help("Escanear outro lugar")
                Button { model.rescan() } label: { Label("Escanear de novo", systemImage: "arrow.clockwise") }
                    .help("Escanear de novo (⌘R)")
            }
        }
        .alert(
            trashTitle,
            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
            presenting: model.pendingTrash
        ) { request in
            Button("Mover para a Lixeira", role: .destructive) {
                Task { await model.performTrash(request) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { request in
            Text(trashMessage(request))
        }
        .sheet(isPresented: $model.showIssues) { IssuesSheet() }
    }

    private var trashTitle: String {
        guard let request = model.pendingTrash else { return "" }
        if request.nodes.count == 1 { return "Mover “\(request.nodes[0].name)” para a Lixeira?" }
        return "Mover \(Format.items(request.nodes.count)) para a Lixeira?"
    }

    private func trashMessage(_ request: AppModel.TrashRequest) -> String {
        var lines = ["Isso libera cerca de \(Format.bytes(request.totalBytes)) quando a Lixeira for esvaziada."]
        if request.nodes.count > 1 {
            let names = request.nodes.prefix(6).map { "• \($0.name)" }
            lines.append(names.joined(separator: "\n") + (request.nodes.count > 6 ? "\n• …" : ""))
        }
        if !request.blocked.isEmpty {
            lines.append("Protegidos, ficam onde estão: " + request.blocked.map(\.name).joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Caminho da raiz do scan até a pasta atual; cada trecho é clicável.
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
                Text("\(Format.bytes(current.size)) · \(Format.files(current.fileCount))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                Button { SystemLinks.revealInFinder(current.path) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Mostrar esta pasta no Finder")
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
                    Label("\(Format.count(result.issueCount)) \(result.issueCount == 1 ? "pasta não lida" : "pastas não lidas")", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("Pastas que não puderam ser lidas não entram na conta")
            }
            if model.trashedCount > 0 {
                HStack(spacing: 6) {
                    Text("Na Lixeira nesta sessão: \(Format.bytes(model.trashedBytes))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Abrir Lixeira") { SystemLinks.openTrash() }
                        .buttonStyle(.link)
                        .help("O espaço só é liberado quando você esvazia a Lixeira")
                }
            }
            Spacer()
            if model.isTrashing {
                ProgressView().controlSize(.small)
            }
            Text(selected.isEmpty ? "Nada selecionado" : "\(Format.items(selected.count)) · \(Format.bytes(bytes))")
                .foregroundStyle(selected.isEmpty ? .tertiary : .primary)
                .monospacedDigit()
            Button {
                model.requestTrashOfSelection()
            } label: {
                Label("Mover para a Lixeira", systemImage: "trash")
            }
            .disabled(selected.isEmpty || model.isTrashing)
            .help("Mover a seleção para a Lixeira (⌘⌫)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

struct IssuesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let issues = model.result?.issues ?? []
        let total = model.result?.issueCount ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text("Pastas que não entraram na conta").font(.title3.weight(.semibold))
            Text("O macOS protege algumas pastas (Mail, Fotos, dados de outros apps…). Para o scan enxergar tudo, dê Acesso Total ao Disco ao Garbage Collector e escaneie de novo.")
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
                Text("Mostrando \(Format.count(issues.count)) de \(Format.count(total)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Abrir Ajustes de Privacidade…") { SystemLinks.openFullDiskAccessSettings() }
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
    }

    static func describe(_ kind: FileNode.Issue) -> String {
        switch kind {
        case .permissionDenied: "sem permissão"
        case .unreadable: "erro de leitura"
        case .otherVolume: "outro volume"
        case .cloudOnly: "só na nuvem"
        }
    }
}

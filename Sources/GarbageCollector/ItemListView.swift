import ScanCore
import SwiftUI

/// Conteúdo da pasta atual, do maior para o menor.
struct ItemListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let _ = model.revision
        let items = model.current?.children ?? []
        let parentSize = model.current?.size ?? 0

        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, node in
                    ItemRow(
                        node: node,
                        share: parentSize > 0 ? Double(node.size) / Double(parentSize) : 0,
                        color: node.isAggregate ? Palette.aggregate : Palette.swatch(index)
                    )
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: FileNode.ID.self) { ids in
                contextMenu(for: items.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                if let node = items.first(where: { ids.contains($0.id) }) { activate(node) }
            }
            .onChange(of: model.scrollTarget) { _, target in
                if let target { proxy.scrollTo(target, anchor: .center) }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Pasta vazia", systemImage: "folder", description: Text("Nada ocupando espaço aqui."))
                }
            }
        }
    }

    /// Duplo clique / Return: entra na pasta, detalha o agregado ou mostra o arquivo no Finder.
    private func activate(_ node: FileNode) {
        if model.canOpen(node) {
            model.open(node)
        } else if node.kind == .smallFiles {
            model.expandSmallFiles()
        } else if !node.isAggregate {
            SystemLinks.revealInFinder(node.path)
        }
    }

    @ViewBuilder
    private func contextMenu(for nodes: [FileNode]) -> some View {
        if let node = nodes.first, nodes.count == 1 {
            if model.canOpen(node) {
                Button("Abrir") { model.open(node) }
            }
            if node.kind == .smallFiles {
                Button("Detalhar arquivos pequenos") { model.expandSmallFiles() }
            }
            Button("Mostrar no Finder") { SystemLinks.revealInFinder(node.path) }
            Button("Copiar caminho") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.displayPath(node), forType: .string)
            }
        }
        let trashable = nodes.filter { !$0.isAggregate }
        if !trashable.isEmpty {
            Divider()
            Button("Mover para a Lixeira", role: .destructive) { model.requestTrash(trashable) }
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let share: Double
    let color: Color
    /// Quando preenchido, aparece abaixo do nome (usado em "Maiores arquivos" para mostrar a pasta).
    var location: String?

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 18)
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(node.isAggregate ? .secondary : .primary)
                        .italic(node.isAggregate)
                    if let badge { Badge(text: badge) }
                    if node.kind == .smallFiles {
                        Button("Detalhar") { model.expandSmallFiles() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                if let location {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if node.isDirectory, node.issue == nil {
                Text(Format.files(node.fileCount))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            ShareBar(share: share, color: color).frame(width: 84, height: 6)
            Text(Format.bytes(node.size))
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)
            Text(Format.share(share))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(model.canOpen(node) ? 1 : 0)
        }
        .padding(.vertical, 2)
        .help(node.isAggregate ? "Arquivos pequenos somados para o scan ficar leve" : model.displayPath(node))
    }

    private var title: String {
        switch node.kind {
        case .smallFiles: "\(Format.files(node.fileCount)) menores que 1 MB"
        case .remainder: "\(Format.files(node.fileCount)) ainda menores"
        default: node.name
        }
    }

    private var badge: String? {
        node.issue.map(IssuesSheet.describe)
    }

    @ViewBuilder
    private var icon: some View {
        if node.isAggregate {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        } else {
            Image(nsImage: IconCache.icon(for: node)).resizable().interpolation(.high)
        }
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .fixedSize()
    }
}

/// Barra proporcional à fatia que o item ocupa da pasta atual.
private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: share > 0 ? max(2, proxy.size.width * min(share, 1)) : 0)
            }
        }
    }
}

/// Os maiores arquivos de toda a árvore, independente da pasta.
struct LargestFilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let _ = model.revision
        let files = model.largestFiles
        let largest = files.first?.size ?? 0

        List(selection: $model.largestSelection) {
            ForEach(files) { node in
                ItemRow(
                    node: node,
                    share: largest > 0 ? Double(node.size) / Double(largest) : 0,
                    color: .accentColor,
                    location: node.parent.map { model.displayPath($0) }
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            let nodes = files.filter { ids.contains($0.id) }
            if let node = nodes.first, nodes.count == 1 {
                Button("Mostrar na pasta") { model.showInFolder(node) }
                Button("Mostrar no Finder") { SystemLinks.revealInFinder(node.path) }
                Divider()
            }
            if !nodes.isEmpty {
                Button("Mover para a Lixeira", role: .destructive) { model.requestTrash(nodes) }
            }
        } primaryAction: { ids in
            if let node = files.first(where: { ids.contains($0.id) }) { model.showInFolder(node) }
        }
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("Nenhum arquivo grande", systemImage: "doc", description: Text("Não há arquivos acima de 1 MB aqui."))
            }
        }
    }
}

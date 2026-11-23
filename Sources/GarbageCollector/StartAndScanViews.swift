import ScanCore
import SwiftUI

/// Barra de ocupação do volume: usado × livre.
struct VolumeBar: View {
    let volume: VolumeInfo

    private var usedFraction: Double {
        volume.total > 0 ? Double(volume.used) / Double(volume.total) : 0
    }

    private var tint: Color {
        usedFraction > 0.9 ? .red : (usedFraction > 0.75 ? .orange : .accentColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.name).font(.headline)
                Spacer()
                Text("\(Format.bytes(volume.available)) livres de \(Format.bytes(volume.total))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint).frame(width: max(6, proxy.size.width * usedFraction))
                }
            }
            .frame(height: 8)
            Text("\(Format.share(usedFraction)) ocupado")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Garbage Collector").font(.largeTitle.weight(.semibold))
                Text("Veja o que está ocupando o disco e mande o que não presta para a Lixeira.")
                    .foregroundStyle(.secondary)
            }
            if let volume = model.volume {
                VolumeBar(volume: volume).frame(maxWidth: 520)
            }
            HStack(spacing: 14) {
                ScanChoice(
                    symbol: "house",
                    title: "Pasta pessoal",
                    detail: "Downloads, caches, projetos… onde o lixo costuma estar.",
                    action: model.scanHome
                )
                ScanChoice(
                    symbol: "internaldrive",
                    title: "Disco inteiro",
                    detail: "Tudo, inclusive apps e pastas do sistema. Mais demorado.",
                    action: model.scanWholeDisk
                )
                ScanChoice(
                    symbol: "folder.badge.gearshape",
                    title: "Escolher pasta…",
                    detail: "Analisa só a pasta que você indicar.",
                    action: model.chooseFolderAndScan
                )
            }
            Text("Nada é apagado sem você confirmar, e tudo vai para a Lixeira — dá para desfazer.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanChoice: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 26)
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 200, height: 150, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: hovering ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Text("Escaneando \(model.scanningPath)")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView().progressViewStyle(.linear).frame(maxWidth: 420)
            HStack(spacing: 28) {
                Metric(value: Format.bytes(model.progress.bytes), label: "encontrados")
                Metric(value: Format.count(model.progress.files), label: "arquivos")
                Metric(value: Format.count(model.progress.directories), label: "pastas")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Metric(value: elapsed(until: context.date), label: "tempo")
                }
            }
            Text(VolumePaths.userFacing(model.progress.currentPath))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
            Button("Cancelar", role: .cancel) { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func elapsed(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(model.scanStartedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 90)
    }
}

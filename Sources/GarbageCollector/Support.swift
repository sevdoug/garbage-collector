import AppKit
import ScanCore
import SwiftUI
import UniformTypeIdentifiers

enum Format {
    /// Tamanho no mesmo padrão do Finder (unidades decimais).
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func files(_ value: Int) -> String {
        value == 1 ? "1 arquivo" : "\(count(value)) arquivos"
    }

    static func items(_ value: Int) -> String {
        value == 1 ? "1 item" : "\(count(value)) itens"
    }

    static func share(_ value: Double) -> String {
        if value <= 0 { return "0%" }
        if value < 0.01 { return "<1%" }
        return min(value, 1).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Cores compartilhadas entre a lista e o treemap: o item N da pasta atual tem a mesma cor nos dois.
enum Palette {
    private static let hues: [Double] = [0.59, 0.47, 0.36, 0.14, 0.07, 0.98, 0.80, 0.68]

    private static func hue(_ index: Int) -> Double { hues[index % hues.count] }

    static func swatch(_ index: Int) -> Color {
        Color(hue: hue(index), saturation: 0.62, brightness: 0.82)
    }

    /// Moldura de uma pasta no treemap (mais escura; o conteúdo fica por cima, mais claro).
    static func frame(_ index: Int, depth: Int) -> Color {
        Color(hue: hue(index), saturation: 0.60, brightness: max(0.34, 0.56 - Double(depth) * 0.07))
    }

    /// Folha do treemap. `variant` alterna levemente o tom entre vizinhos.
    static func leaf(_ index: Int, variant: Int) -> Color {
        Color(hue: hue(index), saturation: 0.50 - Double(variant % 3) * 0.07, brightness: 0.80 + Double(variant % 3) * 0.05)
    }

    static let aggregate = Color(white: 0.55)
}

/// Ícones por tipo (extensão), sem tocar no arquivo: rápido e não dispara pedidos de permissão.
@MainActor
enum IconCache {
    private static var byExtension: [String: NSImage] = [:]
    private static let folder = NSWorkspace.shared.icon(for: .folder)
    private static let generic = NSWorkspace.shared.icon(for: .data)

    static func icon(for node: FileNode) -> NSImage {
        let ext = (node.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return node.isDirectory ? folder : generic }
        let key = (node.isDirectory ? "d:" : "f:") + ext
        if let cached = byExtension[key] { return cached }

        let image: NSImage
        if node.isDirectory {
            // Pasta com ponto no nome (ex.: "com.spotify.client") continua sendo pasta;
            // só pacotes de verdade (.app, .framework, .photoslibrary…) ganham ícone próprio.
            let package = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
                .first { $0.conforms(to: .package) || $0.conforms(to: .bundle) }
            image = package.map { NSWorkspace.shared.icon(for: $0) } ?? folder
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        byExtension[key] = image
        return image
    }
}

struct VolumeInfo: Equatable {
    let name: String
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }

    static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return VolumeInfo(name: values.volumeName ?? "Disco", total: Int64(total), available: available)
    }
}

enum Trasher {
    enum Outcome: Sendable {
        case trashed
        /// O item já não existia no disco (apagado por fora desde o scan).
        case missing
        case failed(String)
    }

    /// Move cada caminho para a Lixeira. Um resultado por caminho, na mesma ordem.
    ///
    /// Usa `NSWorkspace.recycle`, que move "do mesmo jeito que o Finder" (é o caminho que
    /// preserva o "Colocar de Volta" da Lixeira), em vez de `FileManager.trashItem`.
    @MainActor
    static func trash(paths: [String]) async -> [Outcome] {
        let existing = paths.filter(exists)
        var movedPaths: Set<String> = []
        var failure: String?
        if !existing.isEmpty {
            let urls = existing.map { URL(fileURLWithPath: $0) }
            (movedPaths, failure) = await withCheckedContinuation { continuation in
                NSWorkspace.shared.recycle(urls) { moved, error in
                    continuation.resume(returning: (Set(moved.keys.map(\.path)), error?.localizedDescription))
                }
            }
        }
        return paths.map { path in
            guard existing.contains(path) else { return .missing }
            // A fonte da verdade é o disco: se o item saiu do lugar, foi movido.
            if movedPaths.contains(path) || !exists(path) { return .trashed }
            return .failed(failure ?? "Não foi possível mover para a Lixeira.")
        }
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}

enum SystemLinks {
    @MainActor static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor static func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    @MainActor static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

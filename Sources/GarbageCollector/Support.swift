import AppKit
import ScanCore
import SwiftUI
import UniformTypeIdentifiers

enum Format {
    /// Size in the same style as Finder (decimal units).
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func files(_ value: Int) -> String {
        value == 1 ? String(localized: "1 file") : String(localized: "\(count(value)) files")
    }

    static func items(_ value: Int) -> String {
        value == 1 ? String(localized: "1 item") : String(localized: "\(count(value)) items")
    }

    static func share(_ value: Double) -> String {
        if value <= 0 { return "0%" }
        if value < 0.01 { return "<1%" }
        return min(value, 1).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Colors shared by the list and the treemap: item N of the current folder has the same color in both.
enum Palette {
    private static let hues: [Double] = [0.59, 0.47, 0.36, 0.14, 0.07, 0.98, 0.80, 0.68]

    private static func hue(_ index: Int) -> Double { hues[index % hues.count] }

    static func swatch(_ index: Int) -> Color {
        Color(hue: hue(index), saturation: 0.62, brightness: 0.82)
    }

    /// Frame of a folder in the treemap (darker; its contents sit on top, lighter).
    static func frame(_ index: Int, depth: Int) -> Color {
        Color(hue: hue(index), saturation: 0.60, brightness: max(0.34, 0.56 - Double(depth) * 0.07))
    }

    /// Treemap leaf. `variant` slightly shifts the tone between neighbors.
    static func leaf(_ index: Int, variant: Int) -> Color {
        Color(hue: hue(index), saturation: 0.50 - Double(variant % 3) * 0.07, brightness: 0.80 + Double(variant % 3) * 0.05)
    }

    static let aggregate = Color(white: 0.55)
}

/// Icons by type (extension), without touching the file: fast, and triggers no permission prompts.
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
            // A folder with a dot in its name (e.g. "com.spotify.client") is still a folder;
            // only real packages (.app, .framework, .photoslibrary…) get their own icon.
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
        return VolumeInfo(name: values.volumeName ?? String(localized: "Disk"), total: Int64(total), available: available)
    }
}

enum Trasher {
    enum Outcome: Sendable {
        case trashed
        /// The item was already gone from disk (deleted elsewhere since the scan).
        case missing
        case failed(String)
    }

    /// Moves each path to the Trash. One outcome per path, in the same order.
    ///
    /// Uses `NSWorkspace.recycle`, which moves items "the same way Finder does" (the route
    /// that keeps the Trash's "Put Back"), instead of `FileManager.trashItem`.
    @MainActor
    static func trash(paths: [String]) async -> [Outcome] {
        let existing = paths.filter(exists)
        // Re-validate against the disk now: the path may point somewhere else since the scan.
        // A tiny window remains between this check and `recycle`, which takes paths rather
        // than file descriptors.
        var refused: [String: String] = [:]
        for path in existing {
            if case .denied(let reason) = TrashGuard.evaluateOnDisk(path: path) { refused[path] = reason.message }
        }
        let allowed = existing.filter { refused[$0] == nil }
        var movedPaths: Set<String> = []
        var failure: String?
        if !allowed.isEmpty {
            let urls = allowed.map { URL(fileURLWithPath: $0) }
            (movedPaths, failure) = await withCheckedContinuation { continuation in
                NSWorkspace.shared.recycle(urls) { moved, error in
                    continuation.resume(returning: (Set(moved.keys.map(\.path)), error?.localizedDescription))
                }
            }
        }
        return paths.map { path in
            guard existing.contains(path) else { return .missing }
            if let reason = refused[path] { return .failed(reason) }
            // The disk is the source of truth: if the item left its place, it was moved.
            if movedPaths.contains(path) || !exists(path) { return .trashed }
            return .failed(failure ?? String(localized: "Could not move to the Trash."))
        }
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}

extension TrashGuard.DenialReason {
    /// Why the app refused to trash an item, in the user's language.
    var message: String {
        switch self {
        case .invalidPath: String(localized: "Invalid path.")
        case .topLevelFolder: String(localized: "It is a top-level folder of the disk.")
        case .homeOrAncestor: String(localized: "It is your home folder (or contains it).")
        case .userHome: String(localized: "It is a user's home folder.")
        case .volumeRoot: String(localized: "It is the root of a volume.")
        case .systemFolder: String(localized: "It is a system folder.")
        case .systemLibraryFolder: String(localized: "It is a structural folder of the system Library. Open it and pick what is inside.")
        case .alreadyInTrash: String(localized: "It is already in the Trash.")
        case .standardHomeFolder: String(localized: "It is a standard folder of your home folder. Open it and pick what is inside.")
        case .userLibraryFolder: String(localized: "It is a structural folder of your Library. Open it and pick what is inside.")
        case .parentMissing: String(localized: "The folder that held this item no longer exists. Scan again.")
        case .pathChanged: String(localized: "The path changed since the scan (a folder became a link to somewhere else). Scan again.")
        }
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

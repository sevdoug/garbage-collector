import Foundation

/// Safety guard: decides whether the app may send a path to the Trash.
/// The idea is to block the "structural" folders of the system and of the user — their
/// contents stay allowed, the folder itself does not.
public enum TrashGuard {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(DenialReason)
    }

    /// Why a path was refused. The app turns each case into a message for the user.
    public enum DenialReason: Equatable, Sendable {
        case invalidPath
        case topLevelFolder
        case homeOrAncestor
        case userHome
        case volumeRoot
        case systemFolder
        case systemLibraryFolder
        case alreadyInTrash
        case standardHomeFolder
        case userLibraryFolder
        /// On-disk check: the folder that held the item is gone.
        case parentMissing
        /// On-disk check: the path now resolves somewhere else (a folder became a symlink).
        case pathChanged
    }

    private static let systemPrefixes = [
        "/System", "/bin", "/sbin", "/dev",
        "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/usr/standalone",
        "/private/etc", "/private/var/db", "/private/var/root", "/Library/Apple",
    ]

    private static let exactDenied: Set<String> = [
        "/usr/local", "/private/var", "/private/tmp", "/private/var/tmp",
        "/private/var/folders", "/opt/homebrew",
    ]

    private static let homeFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
        "Pictures", "Public", "Applications", ".Trash",
    ]

    public static func evaluate(path rawPath: String, home rawHome: String = NSHomeDirectory()) -> Verdict {
        let path = normalize(rawPath)
        let home = normalize(rawHome)
        guard path.hasPrefix("/") else { return .denied(.invalidPath) }

        let components = path.split(separator: "/")
        if components.count <= 1 {
            return .denied(.topLevelFolder)
        }
        if path == home || home.hasPrefix(path + "/") {
            return .denied(.homeOrAncestor)
        }
        if components[0] == "Users", components.count == 2 {
            return .denied(.userHome)
        }
        if components[0] == "Volumes", components.count == 2 {
            return .denied(.volumeRoot)
        }
        if exactDenied.contains(path) || systemPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .denied(.systemFolder)
        }
        if components[0] == "Library", components.count == 2 {
            return .denied(.systemLibraryFolder)
        }

        if path.hasPrefix(home + "/") {
            let relative = path.dropFirst(home.count + 1).split(separator: "/")
            if relative.first == ".Trash" {
                return .denied(.alreadyInTrash)
            }
            if relative.count == 1, homeFolders.contains(String(relative[0])) {
                return .denied(.standardHomeFolder)
            }
            if relative.count == 2, relative[0] == "Library" {
                return .denied(.userLibraryFolder)
            }
        }
        return .allowed
    }

    /// Check made right before moving, against the disk. The tree is a snapshot of the scan: if
    /// a folder in the path has since become a symlink, the item that would be moved is a
    /// different one — possibly somewhere `evaluate` would refuse. Here the path only passes if
    /// the folder holding the item is still the same place, and the rules run on the real path.
    ///
    /// The last component is deliberately not resolved: trashing a symlink moves the link,
    /// not its target.
    public static func evaluateOnDisk(path: String, home: String = NSHomeDirectory()) -> Verdict {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard path.hasPrefix("/"), !name.isEmpty, let resolved = realpath(parent, nil) else {
            return .denied(.parentMissing)
        }
        let realParent = String(cString: resolved)
        free(resolved)
        guard VolumePaths.userFacing(realParent) == VolumePaths.userFacing(parent) else {
            return .denied(.pathChanged)
        }
        return evaluate(path: realParent.hasSuffix("/") ? realParent + name : realParent + "/" + name, home: home)
    }

    static func normalize(_ path: String) -> String { VolumePaths.userFacing(path) }
}

public enum VolumePaths {
    /// Where macOS mounts the data volume. Scanning from here covers the whole disk without
    /// counting anything twice (the `/` root is another, read-only volume with firmlinks to here).
    public static let dataVolume = "/System/Volumes/Data"

    /// Strips trailing slashes, `.`/`..` and the data-volume prefix
    /// (`/System/Volumes/Data/Users/x` is the same place as `/Users/x`).
    ///
    /// Deliberately not `standardizingPath`: it turns `/private/tmp` into `/tmp`, and the
    /// result must not depend on what exists on disk.
    public static func userFacing(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(component)
            }
        }
        let standardized = "/" + parts.joined(separator: "/")
        if standardized == dataVolume { return "/" }
        if standardized.hasPrefix(dataVolume + "/") { return String(standardized.dropFirst(dataVolume.count)) }
        return standardized
    }
}

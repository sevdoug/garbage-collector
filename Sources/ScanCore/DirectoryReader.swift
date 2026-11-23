import Darwin

/// Low-level directory read: `readdir` + `fstatat`, without following symbolic links.
enum DirectoryReader {
    enum Failure: Error {
        case permissionDenied
        case unreadable
    }

    /// Bytes actually allocated on disk (`st_blocks`), not the logical size.
    /// Sparse files (e.g. Docker.raw) and cloud-only files have a misleading logical size.
    @inline(__always)
    static func allocatedSize(_ st: stat) -> Int64 {
        Int64(st.st_blocks) * 512
    }

    @inline(__always)
    static func fileType(_ st: stat) -> mode_t {
        st.st_mode & S_IFMT
    }

    /// Directory whose contents have not been downloaded yet (iCloud/CloudStorage). Listing it would force the download.
    @inline(__always)
    static func isDataless(_ st: stat) -> Bool {
        st.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Calls `body` for each entry (except `.` and `..`) with the C name and the `lstat` result.
    /// Entries that vanish between the `readdir` and the `fstatat` are skipped.
    static func forEachEntry(
        atPath path: String,
        _ body: (_ name: UnsafePointer<CChar>, _ st: stat) -> Void
    ) throws(Failure) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw (errno == EACCES || errno == EPERM) ? Failure.permissionDenied : Failure.unreadable
        }
        guard let dir = fdopendir(fd) else {
            close(fd)
            throw .unreadable
        }
        defer { closedir(dir) }

        let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
        while let entry = readdir(dir) {
            let name = UnsafeRawPointer(entry).advanced(by: nameOffset)
                .assumingMemoryBound(to: CChar.self)
            // Skip "." and ".."
            if name[0] == 46, name[1] == 0 || (name[1] == 46 && name[2] == 0) { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            body(name, st)
        }
    }
}

import Darwin

/// Leitura de baixo nível de uma pasta: `readdir` + `fstatat`, sem seguir links simbólicos.
enum DirectoryReader {
    enum Failure: Error {
        case permissionDenied
        case unreadable
    }

    /// Bytes realmente alocados em disco (`st_blocks`), não o tamanho lógico.
    /// Arquivos esparsos (ex.: Docker.raw) e arquivos só na nuvem mentem no tamanho lógico.
    @inline(__always)
    static func allocatedSize(_ st: stat) -> Int64 {
        Int64(st.st_blocks) * 512
    }

    @inline(__always)
    static func fileType(_ st: stat) -> mode_t {
        st.st_mode & S_IFMT
    }

    /// Pasta cujo conteúdo ainda não foi baixado (iCloud/CloudStorage). Listá-la forçaria o download.
    @inline(__always)
    static func isDataless(_ st: stat) -> Bool {
        st.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Chama `body` para cada entrada (exceto `.` e `..`) com o nome C e o resultado do `lstat`.
    /// Entradas que somem entre o `readdir` e o `fstatat` são ignoradas.
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
            // Pula "." e ".."
            if name[0] == 46, name[1] == 0 || (name[1] == 46 && name[2] == 0) { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            body(name, st)
        }
    }
}

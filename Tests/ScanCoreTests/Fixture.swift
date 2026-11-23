import Darwin
import Foundation

/// Pasta temporária com casos difíceis para o scanner. Tudo é criado dentro de um diretório
/// temporário exclusivo e apagado no `deinit`.
final class Fixture {
    let root: String
    static let megabyte = 1 << 20

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath: /var/folders/... é um symlink para /private/var/folders/...
        root = String(cString: realpath(base.path, nil))
    }

    deinit {
        // Devolve a permissão de pastas bloqueadas pelos testes antes de apagar.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let item as String in enumerator { chmod(root + "/" + item, 0o755) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// Arquivo com dados de verdade (não compressíveis nem esparsos), para o tamanho alocado ser previsível.
    func writeFile(_ relative: String, bytes: Int) throws {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            arc4random_buf(buffer.baseAddress, buffer.count)
        }
        try makeDirectory((relative as NSString).deletingLastPathComponent)
        try data.write(to: URL(fileURLWithPath: path(relative)))
    }

    /// Arquivo esparso: tamanho lógico grande, quase nada alocado.
    func writeSparseFile(_ relative: String, logicalBytes: Int) throws {
        let fd = open(path(relative), O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(logicalBytes)) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Tamanho segundo o `du -sk` (KiB alocados, hardlinks contados uma vez), em bytes.
    func duBytes(_ relative: String = "") throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", relative.isEmpty ? root : path(relative)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let kilobytes = Int64(output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") ?? -1
        return kilobytes * 1024
    }
}

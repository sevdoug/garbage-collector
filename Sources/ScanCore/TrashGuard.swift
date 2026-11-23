import Foundation

/// Trava de segurança: decide se um caminho pode ser enviado para a Lixeira pelo app.
/// A ideia é bloquear as pastas "estruturais" do sistema e do usuário — o conteúdo delas
/// continua liberado, a pasta em si não.
public enum TrashGuard {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(reason: String)
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
        guard path.hasPrefix("/") else { return .denied(reason: "Caminho inválido.") }

        let components = path.split(separator: "/")
        if components.count <= 1 {
            return .denied(reason: "É uma pasta de primeiro nível do disco.")
        }
        if path == home || home.hasPrefix(path + "/") {
            return .denied(reason: "É a sua pasta pessoal (ou contém ela).")
        }
        if components[0] == "Users", components.count == 2 {
            return .denied(reason: "É a pasta pessoal de um usuário.")
        }
        if components[0] == "Volumes", components.count == 2 {
            return .denied(reason: "É a raiz de um volume.")
        }
        if exactDenied.contains(path) || systemPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .denied(reason: "É uma pasta do sistema.")
        }
        if components[0] == "Library", components.count == 2 {
            return .denied(reason: "É uma pasta estrutural da Biblioteca do sistema. Entre nela e escolha o conteúdo.")
        }

        if path.hasPrefix(home + "/") {
            let relative = path.dropFirst(home.count + 1).split(separator: "/")
            if relative.first == ".Trash" {
                return .denied(reason: "Já está na Lixeira.")
            }
            if relative.count == 1, homeFolders.contains(String(relative[0])) {
                return .denied(reason: "É uma pasta padrão da sua pasta pessoal. Entre nela e escolha o conteúdo.")
            }
            if relative.count == 2, relative[0] == "Library" {
                return .denied(reason: "É uma pasta estrutural da sua Biblioteca. Entre nela e escolha o conteúdo.")
            }
        }
        return .allowed
    }

    static func normalize(_ path: String) -> String { VolumePaths.userFacing(path) }
}

public enum VolumePaths {
    /// Onde o macOS monta o volume de dados. Escanear a partir daqui cobre o disco inteiro
    /// sem contar nada em dobro (a raiz `/` é outro volume, só de leitura, com atalhos para cá).
    public static let dataVolume = "/System/Volumes/Data"

    /// Remove barras finais, `.`/`..` e o prefixo do volume de dados
    /// (`/System/Volumes/Data/Users/x` é o mesmo lugar que `/Users/x`).
    ///
    /// Não usa `standardizingPath` de propósito: ele troca `/private/tmp` por `/tmp` e não
    /// queremos que o resultado dependa do que existe no disco.
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

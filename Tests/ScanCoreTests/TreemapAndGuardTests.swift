import Testing
@testable import ScanCore

@Suite struct TreemapTests {
    private let canvas = TreemapRect(x: 10, y: 20, width: 600, height: 400)

    @Test func areasAreProportionalAndFillTheCanvas() {
        let weights: [Double] = [500, 300, 120, 50, 20, 9, 1]
        let rects = Treemap.squarify(weights: weights, in: canvas)
        let total = weights.reduce(0, +)

        #expect(rects.count == weights.count)
        for (weight, rect) in zip(weights, rects) {
            #expect(abs(rect.area - weight / total * canvas.area) < 1e-6)
            #expect(rect.x >= canvas.x - 1e-9 && rect.y >= canvas.y - 1e-9)
            #expect(rect.x + rect.width <= canvas.x + canvas.width + 1e-6)
            #expect(rect.y + rect.height <= canvas.y + canvas.height + 1e-6)
        }
        #expect(abs(rects.reduce(0) { $0 + $1.area } - canvas.area) < 1e-6)
    }

    @Test func rectanglesDoNotOverlap() {
        let rects = Treemap.squarify(weights: [40, 30, 20, 15, 10, 8, 5, 3, 2, 1], in: canvas)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i], b = rects[j]
                let overlapX = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapY = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                #expect(overlapX <= 1e-6 || overlapY <= 1e-6, "retângulos \(i) e \(j) se sobrepõem")
            }
        }
    }

    @Test func equalWeightsStayCloseToSquares() {
        let rects = Treemap.squarify(weights: [Double](repeating: 1, count: 24), in: canvas)
        for rect in rects {
            let ratio = max(rect.width / rect.height, rect.height / rect.width)
            #expect(ratio < 2.5)
        }
    }

    @Test func degenerateInputs() {
        #expect(Treemap.squarify(weights: [], in: canvas).isEmpty)
        #expect(Treemap.squarify(weights: [0, 0], in: canvas).allSatisfy { $0.area == 0 })
        #expect(Treemap.squarify(weights: [5], in: canvas) == [canvas])
        #expect(Treemap.squarify(weights: [3, 1], in: TreemapRect(x: 0, y: 0, width: 0, height: 10)).allSatisfy { $0.area == 0 })

        let withZero = Treemap.squarify(weights: [10, 5, 0], in: canvas)
        #expect(withZero[2].area == 0)
        #expect(abs(withZero[0].area + withZero[1].area - canvas.area) < 1e-6)
    }
}

@Suite struct TrashGuardTests {
    private let home = "/Users/ana"

    private func isDenied(_ path: String) -> Bool {
        TrashGuard.evaluate(path: path, home: home) != .allowed
    }

    @Test(arguments: [
        "/", "/Users", "/Users/ana", "/Users/ana/", "/Users/bia", "/Applications", "/Library",
        "/System/Library/Fonts", "/usr/bin/zip", "/usr/local", "/opt/homebrew", "/private/var/db/foo",
        "/Volumes/Backup", "/Library/Caches", "/private/var/folders", "/private/tmp",
        "/Users/ana/Documents", "/Users/ana/Library", "/Users/ana/Library/Caches",
        "/Users/ana/Library/Application Support", "/Users/ana/.Trash/old.zip",
        "/System/Volumes/Data", "/System/Volumes/Data/Users/ana", "/System/Volumes/Data/Users/ana/Downloads",
        "/Users/ana/Documents/..", "/Users/ana/Downloads/../Library", "relative/path", "",
    ])
    func deniesStructuralPaths(path: String) {
        #expect(isDenied(path))
    }

    @Test(arguments: [
        "/Users/ana/Downloads/filme.mkv", "/Users/ana/Library/Caches/com.app",
        "/Users/ana/Library/Developer/Xcode/DerivedData", "/Users/ana/projetos/app/node_modules",
        "/Users/ana/.npm", "/Applications/Jogo.app", "/Library/Caches/com.app",
        "/usr/local/Cellar/foo", "/opt/homebrew/Cellar/foo", "/Volumes/Backup/antigo",
        "/private/tmp/lixo", "/private/var/folders/ab/cd/T/lixo",
        "/System/Volumes/Data/Users/ana/Downloads/filme.mkv", "/Users/Shared/instalador.dmg",
    ])
    func allowsOrdinaryContent(path: String) {
        #expect(!isDenied(path))
    }

    @Test func normalization() {
        #expect(TrashGuard.normalize("/a/b/../c/./d/") == "/a/c/d")
        #expect(TrashGuard.normalize("/System/Volumes/Data/Users/x") == "/Users/x")
        #expect(TrashGuard.normalize("/System/Volumes/Data") == "/")
        #expect(TrashGuard.normalize("/private/tmp/x") == "/private/tmp/x")
    }
}

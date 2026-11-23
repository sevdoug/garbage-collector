/// Retângulo independente de framework de UI.
public struct TreemapRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    public func insetBy(_ d: Double) -> TreemapRect {
        TreemapRect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }
}

public enum Treemap {
    /// Treemap "squarified" (Bruls, Huizing, van Wijk): divide `rect` em áreas proporcionais
    /// aos pesos, mantendo os retângulos o mais próximos possível de quadrados.
    ///
    /// `weights` deve vir em ordem decrescente. O resultado tem um retângulo por peso, na mesma
    /// ordem; pesos não positivos recebem um retângulo de área zero.
    public static func squarify(weights: [Double], in rect: TreemapRect) -> [TreemapRect] {
        var result = [TreemapRect](repeating: TreemapRect(x: rect.x, y: rect.y, width: 0, height: 0), count: weights.count)
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let scale = rect.area / total
        let areas = weights.map { max(0, $0) * scale }
        var free = rect
        var rowStart = 0

        while rowStart < areas.count, areas[rowStart] > 0 {
            let side = min(free.width, free.height)
            guard side > 0 else { break }

            // Cresce a fileira enquanto a pior proporção não piorar.
            var rowEnd = rowStart + 1
            var rowSum = areas[rowStart]
            var worst = worstRatio(sum: rowSum, largest: areas[rowStart], smallest: areas[rowStart], side: side)
            while rowEnd < areas.count, areas[rowEnd] > 0 {
                let candidateSum = rowSum + areas[rowEnd]
                let candidate = worstRatio(sum: candidateSum, largest: areas[rowStart], smallest: areas[rowEnd], side: side)
                if candidate > worst { break }
                worst = candidate
                rowSum = candidateSum
                rowEnd += 1
            }

            // A fileira ocupa uma faixa ao longo do lado menor do espaço livre.
            let thickness = rowSum / side
            var offset = 0.0
            for index in rowStart..<rowEnd {
                let length = areas[index] / thickness
                if free.width >= free.height {
                    result[index] = TreemapRect(x: free.x, y: free.y + offset, width: thickness, height: length)
                } else {
                    result[index] = TreemapRect(x: free.x + offset, y: free.y, width: length, height: thickness)
                }
                offset += length
            }
            if free.width >= free.height {
                free.x += thickness
                free.width = max(0, free.width - thickness)
            } else {
                free.y += thickness
                free.height = max(0, free.height - thickness)
            }
            rowStart = rowEnd
        }
        return result
    }

    private static func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }
}

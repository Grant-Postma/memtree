import CoreGraphics

/// Squarified treemap (Bruls, Huizing, van Wijk): rows are grown along the
/// short side while that keeps tiles closer to square.
///
/// Split in two so a live map can hold still: `partition` makes the discrete
/// choices (which tiles share a row, and which way each row runs) and
/// `place` turns a partition into rects. For a fixed partition the rects move
/// continuously with the values, so reusing one keeps tiles from jumping when
/// a fresh layout would move a row break.
enum Treemap {
    struct Row: Equatable {
        let count: Int
        /// The row is a column against the left edge (the space left was
        /// wider than tall); otherwise a strip along the top.
        let column: Bool
    }

    /// Rects for `values` inside `rect`, in the same order. Values are
    /// expected largest first; zero or negative values get an empty rect.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        place(values, in: rect, rows: partition(values, in: rect))
    }

    /// The rows a squarified layout makes, over the positive values only.
    static func partition(_ values: [Double], in rect: CGRect) -> [Row] {
        let positive = values.filter { $0 > 0 }
        let total = positive.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }

        let scale = Double(rect.width * rect.height) / total
        var rows: [Row] = []
        var remaining = rect
        var start = 0
        while start < positive.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var rowSum = positive[start] * scale
            var rowMin = rowSum, rowMax = rowSum
            var best = worst(sum: rowSum, min: rowMin, max: rowMax, side: side)
            while end < positive.count {
                let area = positive[end] * scale
                let candidate = worst(sum: rowSum + area, min: Swift.min(rowMin, area),
                                      max: Swift.max(rowMax, area), side: side)
                if candidate > best { break }
                rowSum += area
                rowMin = Swift.min(rowMin, area)
                rowMax = Swift.max(rowMax, area)
                best = candidate
                end += 1
            }
            let column = remaining.width >= remaining.height
            rows.append(Row(count: end - start, column: column))
            if column {
                let width = CGFloat(rowSum / Double(remaining.height))
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                let height = CGFloat(rowSum / Double(remaining.width))
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(remaining.height - height, 0))
            }
            start = end
        }
        return rows
    }

    /// Rects for `values` laid out in `rows`. Zero values get an empty rect
    /// and are not counted by the rows.
    static func place(_ values: [Double], in rect: CGRect, rows: [Row]) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: values.count)
        let indices = values.indices.filter { values[$0] > 0 }
        let total = indices.reduce(0) { $0 + values[$1] }
        guard total > 0, rect.width > 0, rect.height > 0,
              rows.reduce(0, { $0 + $1.count }) == indices.count else { return rects }

        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var start = 0
        for row in rows {
            let end = start + row.count
            let rowSum = indices[start..<end].reduce(0) { $0 + values[$1] * scale }
            // The last row takes whatever is left, so rounding never leaves a gap.
            let isLast = end == indices.count
            if row.column {
                let width = isLast ? remaining.width : CGFloat(rowSum / Double(max(remaining.height, 0.001)))
                var y = remaining.minY
                for (offset, index) in indices[start..<end].enumerated() {
                    let height = offset == row.count - 1 ? remaining.maxY - y
                        : CGFloat(values[index] * scale / Double(max(width, 0.001)))
                    rects[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                let height = isLast ? remaining.height : CGFloat(rowSum / Double(max(remaining.width, 0.001)))
                var x = remaining.minX
                for (offset, index) in indices[start..<end].enumerated() {
                    let width = offset == row.count - 1 ? remaining.maxX - x
                        : CGFloat(values[index] * scale / Double(max(height, 0.001)))
                    rects[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(remaining.height - height, 0))
            }
            start = end
        }
        return rects
    }

    /// The most elongated tile, as long side over short side.
    static func worstAspect(_ rects: [CGRect]) -> Double {
        rects.reduce(1) { worst, rect in
            guard rect.width > 0.5, rect.height > 0.5 else { return worst }
            return Swift.max(worst, Double(Swift.max(rect.width / rect.height, rect.height / rect.width)))
        }
    }

    /// The worst aspect ratio in a row of areas laid along `side`.
    private static func worst(sum: Double, min: Double, max: Double, side: Double) -> Double {
        let side2 = side * side, sum2 = sum * sum
        return Swift.max(side2 * max / sum2, sum2 / (side2 * min))
    }
}

/// Keeps a treemap's rows from one frame to the next while they still make
/// reasonable tiles, so a live map glides instead of reshuffling.
struct StickyLayout {
    private var keys: [Int] = []
    private var rows: [Treemap.Row] = []

    /// Rects for `values`, identified by `keys` in the same order.
    mutating func layout(keys: [Int], values: [Double], in rect: CGRect) -> [CGRect] {
        let fresh = Treemap.partition(values, in: rect)
        if keys == self.keys, !rows.isEmpty {
            let kept = Treemap.place(values, in: rect, rows: rows)
            let keptWorst = Treemap.worstAspect(kept)
            // Only give up the old rows once they are clearly worse than new
            // ones would be; a row break that moves is a jump on screen.
            if keptWorst < 3 || keptWorst <= Treemap.worstAspect(Treemap.place(values, in: rect, rows: fresh)) * 1.5 {
                if kept.contains(where: { $0.width > 0 }) || values.allSatisfy({ $0 <= 0 }) { return kept }
            }
        }
        self.keys = keys
        rows = fresh
        return Treemap.place(values, in: rect, rows: fresh)
    }
}

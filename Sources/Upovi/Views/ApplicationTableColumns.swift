import SwiftUI

/// Column resizing keeps adjacent columns inside their bounds without changing total width.
struct ApplicationTableColumns: Equatable {
    private(set) var widths: [CGFloat] = [280, 110, 110, 120]
    private static let minimums: [CGFloat] = [200, 80, 80, 100]
    private static let maximums: [CGFloat] = [.infinity, 160, 160, 180]
    var totalWidth: CGFloat { widths.reduce(0, +) }

    func fitted(to available: CGFloat) -> Self {
        var result = self
        let target = max(Self.minimums.reduce(0, +), available)
        if target >= totalWidth {
            result.widths[0] += target - totalWidth
        } else {
            var remaining = totalWidth - target
            for index in widths.indices {
                let reduction = min(remaining, result.widths[index] - Self.minimums[index])
                result.widths[index] -= reduction
                remaining -= reduction
            }
        }
        return result
    }

    func resizingBoundary(_ index: Int, by translation: CGFloat) -> Self {
        guard (0..<3).contains(index) else { return self }
        var result = self
        let lower = max(Self.minimums[index] - widths[index], widths[index + 1] - Self.maximums[index + 1])
        let upper = min(Self.maximums[index] - widths[index], widths[index + 1] - Self.minimums[index + 1])
        let change = min(upper, max(lower, translation))
        result.widths[index] += change
        result.widths[index + 1] -= change
        return result
    }
}

import CoreGraphics

/// Keeps overlay labels from landing on top of each other. Labels are placed in
/// order of importance; each one keeps its preferred spot when free, otherwise
/// it is nudged vertically to the nearest position that is still clear.
struct LabelPlacer {
    /// Labels are never nudged outside this area — otherwise dodging a
    /// collision near an edge would push a label off the image entirely.
    private let bounds: CGRect
    private var occupied: [CGRect] = []

    init(bounds: CGRect) {
        self.bounds = bounds
    }

    /// Returns a rect for `preferred` that does not overlap anything placed so
    /// far, trying alternating offsets below and above before giving up.
    mutating func place(_ preferred: CGRect, step: CGFloat) -> CGRect {
        var candidates = [preferred]
        // Far enough to step clear of the readings block, and no further:
        // a label that wanders past that stops looking like it belongs to its
        // marker, and a small overlap reads better than a wrong pairing.
        for i in 1...8 {
            candidates.append(preferred.offsetBy(dx: 0, dy: step * CGFloat(i)))
            candidates.append(preferred.offsetBy(dx: 0, dy: -step * CGFloat(i)))
        }
        let visible = candidates.filter { $0.minY >= bounds.minY && $0.maxY <= bounds.maxY }
        let chosen = visible.first { candidate in
            !occupied.contains { $0.intersects(candidate) }
        } ?? visible.first ?? preferred
        occupied.append(chosen)
        return chosen
    }

    /// Reserves space without asking for a position, e.g. for fixed chrome.
    mutating func reserve(_ rect: CGRect) {
        occupied.append(rect)
    }
}

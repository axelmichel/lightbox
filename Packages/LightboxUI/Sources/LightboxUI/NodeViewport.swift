import CoreGraphics

/// Which part of the node canvas is in view: a point `p` on the canvas is
/// drawn at `offset + p * scale`.
struct NodeViewport: Equatable {
    static let scales = 0.1...4.0

    var scale = 1.0
    var offset = CGPoint.zero

    /// All of `bounds` in a view of `size`, centred, at most at `maxScale`.
    static func fit(_ bounds: CGRect, in size: CGSize, margin: Double = 24, maxScale: Double = 1) -> NodeViewport {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return NodeViewport() }
        let fitting = min((size.width - 2 * margin) / bounds.width, (size.height - 2 * margin) / bounds.height)
        let scale = min(max(fitting, scales.lowerBound), maxScale)
        return NodeViewport(
            scale: scale,
            offset: CGPoint(
                x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale))
    }

    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale) }

    func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }

    /// Zoomed by `factor`; what is under `point` (in the view) stays there.
    func zoomed(by factor: Double, around point: CGPoint) -> NodeViewport {
        let scale = min(max(scale * factor, Self.scales.lowerBound), Self.scales.upperBound)
        let p = toCanvas(point)
        return NodeViewport(scale: scale, offset: CGPoint(x: point.x - p.x * scale, y: point.y - p.y * scale))
    }

    func panned(by delta: CGSize) -> NodeViewport {
        NodeViewport(scale: scale, offset: CGPoint(x: offset.x + delta.width, y: offset.y + delta.height))
    }
}

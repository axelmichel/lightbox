// Guide lines on a composition's canvas, and snapping layers to them, to
// the grid and to the canvas's edges and center while they are moved or
// resized.

import Foundation

/// A guide line: dragged out of a ruler, saved with the composition.
public struct CanvasGuide: Codable, Hashable, Identifiable, Sendable {
    public enum Axis: String, Codable, Sendable {
        /// A line across at `position` (y), from the top ruler.
        case horizontal
        /// A line down at `position` (x), from the left ruler.
        case vertical
    }

    public var id: UUID
    public var axis: Axis
    /// Canvas pixels.
    public var position: Double

    public init(id: UUID = UUID(), axis: Axis, position: Double) {
        self.id = id
        self.axis = axis
        self.position = position
    }
}

extension Composition {
    public var guideLines: [CanvasGuide] { guides ?? [] }

    @discardableResult
    public mutating func addGuide(_ axis: CanvasGuide.Axis, at position: Double) -> UUID {
        let guide = CanvasGuide(axis: axis, position: position)
        guides = guideLines + [guide]
        return guide.id
    }

    public mutating func moveGuide(_ id: UUID, to position: Double) {
        guides = guideLines.map { $0.id == id ? CanvasGuide(id: id, axis: $0.axis, position: position) : $0 }
    }

    public mutating func removeGuide(_ id: UUID) {
        guides = guideLines.filter { $0.id != id }
    }

    /// What layers snap to: the grid (spacing in canvas pixels), the guide
    /// lines, and the canvas's edges and center when either is used.
    public func snapTargets(grid: Double?, guides useGuides: Bool) -> SnapTargets {
        var targets = SnapTargets(grid: grid.flatMap { $0 > 0 ? $0 : nil })
        if useGuides {
            for g in guideLines {
                switch g.axis {
                case .vertical: targets.xs.append(g.position)
                case .horizontal: targets.ys.append(g.position)
                }
            }
        }
        if useGuides || targets.grid != nil {
            targets.xs += [0, Double(width) / 2, Double(width)]
            targets.ys += [0, Double(height) / 2, Double(height)]
        }
        return targets
    }
}

/// Lines to snap to, per axis, and a grid.
public struct SnapTargets: Equatable, Sendable {
    /// Vertical lines (x positions).
    public var xs: [Double] = []
    /// Horizontal lines (y positions).
    public var ys: [Double] = []
    public var grid: Double?

    public init(xs: [Double] = [], ys: [Double] = [], grid: Double? = nil) {
        self.xs = xs
        self.ys = ys
        self.grid = grid
    }

    public var isEmpty: Bool { xs.isEmpty && ys.isEmpty && grid == nil }

    /// The target nearest to `value` within `threshold`.
    func nearest(_ value: Double, _ lines: [Double], threshold: Double) -> Double? {
        var candidates = lines
        if let grid { candidates.append((value / grid).rounded() * grid) }
        let best = candidates.min { abs($0 - value) < abs($1 - value) }
        guard let best, abs(best - value) <= threshold else { return nil }
        return best
    }
}

/// Where a moved or resized layer ends up, and the lines it snapped to
/// (for showing them while dragging).
public struct Snapped: Equatable, Sendable {
    public var frame: ImageFrame
    public var x: Double?
    public var y: Double?
}

public enum Snapping {
    /// A frame being moved: whichever of its left edge, center and right
    /// edge (top, middle, bottom) is closest to a target moves onto it.
    public static func move(_ f: ImageFrame, to targets: SnapTargets, threshold: Double) -> Snapped {
        func axis(_ edges: [Double], _ lines: [Double]) -> (delta: Double, line: Double)? {
            var best: (delta: Double, line: Double)?
            for e in edges {
                guard let line = targets.nearest(e, lines, threshold: threshold) else { continue }
                if best == nil || abs(line - e) < abs(best!.delta) { best = (line - e, line) }
            }
            return best
        }
        let sx = axis([f.x, f.x + f.width / 2, f.maxX], targets.xs)
        let sy = axis([f.y, f.y + f.height / 2, f.maxY], targets.ys)
        return Snapped(frame: f.offset(by: sx?.delta ?? 0, sy?.delta ?? 0), x: sx?.line, y: sy?.line)
    }

    /// A point being dragged (a resize handle).
    public static func point(_ x: Double, _ y: Double, to targets: SnapTargets, threshold: Double)
        -> (x: Double, y: Double, lineX: Double?, lineY: Double?)
    {
        let lx = targets.nearest(x, targets.xs, threshold: threshold)
        let ly = targets.nearest(y, targets.ys, threshold: threshold)
        return (lx ?? x, ly ?? y, lx, ly)
    }
}

// The composition editor's eraser: rubs out a layer's pixels along a
// stroke. Within one stroke the strength doesn't build up where dabs
// overlap (each pixel keeps the strongest dab it got), so going over a spot
// again in the same stroke doesn't erase it further; a new stroke does.

import Foundation

public struct EraserStroke: Sendable {
    /// The picture before the stroke (premultiplied RGBA).
    public let base: PixelBuffer
    /// How much of each pixel is gone, 0…1.
    public private(set) var coverage: [Float]
    private var last: (x: Double, y: Double)?

    public init(base: PixelBuffer) {
        self.base = base
        coverage = [Float](repeating: 0, count: base.width * base.height)
    }

    public var isEmpty: Bool { !coverage.contains { $0 > 0 } }

    /// Erase from the last point to (`x`, `y`) in picture pixels.
    /// `radius` in pixels; `strength` 0…1 is how much goes at the middle;
    /// `hardness` 0…1 is the share of the radius erased at full strength
    /// (the rest fades out).
    public mutating func move(toX x: Double, y: Double, radius: Double, strength: Double, hardness: Double) {
        let from = last ?? (x, y)
        let r = max(0.5, radius)
        let distance = hypot(x - from.x, y - from.y)
        // Dabs a quarter of the radius apart, so a quick drag leaves no gaps.
        let dabs = max(1, Int((distance / max(0.5, r / 4)).rounded(.up)))
        for i in 1...dabs {
            let t = Double(i) / Double(dabs)
            dab(
                x: from.x + (x - from.x) * t, y: from.y + (y - from.y) * t, radius: r, strength: strength,
                hardness: hardness)
        }
        last = (x, y)
    }

    mutating func dab(x cx: Double, y cy: Double, radius r: Double, strength: Double, hardness: Double) {
        let w = base.width
        let h = base.height
        let x0 = max(0, Int((cx - r).rounded(.down)))
        let x1 = min(w - 1, Int((cx + r).rounded(.up)))
        let y0 = max(0, Int((cy - r).rounded(.down)))
        let y1 = min(h - 1, Int((cy + r).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let strength = min(1, max(0, strength))
        let inner = min(1, max(0, hardness))
        coverage.withUnsafeMutableBufferPointer { c in
            for py in y0...y1 {
                let dy = Double(py) + 0.5 - cy
                for px in x0...x1 {
                    let dx = Double(px) + 0.5 - cx
                    let d = (dx * dx + dy * dy).squareRoot() / r
                    guard d < 1 else { continue }
                    var f = 1.0
                    if d > inner {
                        let t = (d - inner) / (1 - inner)
                        f = 1 - t * t * (3 - 2 * t)
                    }
                    let v = Float(strength * f)
                    let i = py * w + px
                    if v > c[i] { c[i] = v }
                }
            }
        }
    }

    /// The picture with the stroke erased.
    public func result() -> PixelBuffer {
        var out = base
        out.pixels.withUnsafeMutableBufferPointer { p in
            coverage.withUnsafeBufferPointer { c in
                for i in 0..<c.count where c[i] > 0 {
                    // Premultiplied: color and alpha fade together.
                    let keep = 1 - c[i]
                    for k in 0..<4 { p[i * 4 + k] = UInt8((Float(p[i * 4 + k]) * keep).rounded()) }
                }
            }
        }
        return out
    }
}

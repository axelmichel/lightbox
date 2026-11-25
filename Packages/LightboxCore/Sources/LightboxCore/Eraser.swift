// The composition editor's pixel brushes: the eraser rubs out a layer's
// pixels along a stroke, the smoothing brush evens out the jagged edge of a
// cut-out. Within one stroke the strength doesn't build up where dabs
// overlap (each pixel keeps the strongest dab it got), so going over a spot
// again in the same stroke does nothing more; a new stroke does.

import Foundation

/// A brush stroke over a layer's picture, made into a new picture.
public protocol LayerStroke: Sendable {
    /// Paint from the last point to (`x`, `y`) in picture pixels.
    /// `radius` in pixels; `strength` 0…1 is how much it does at the middle;
    /// `hardness` 0…1 is the share of the radius at full strength (the rest
    /// fades out).
    mutating func move(toX x: Double, y: Double, radius: Double, strength: Double, hardness: Double)
    var isEmpty: Bool { get }
    func result() -> PixelBuffer
}

/// How much of each pixel a stroke covers, 0…1.
public struct BrushCoverage: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var values: [Float]
    private var last: (x: Double, y: Double)?

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        values = [Float](repeating: 0, count: width * height)
    }

    public var isEmpty: Bool { !values.contains { $0 > 0 } }

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

    /// The whole picture at `strength`.
    public mutating func coverAll(strength: Double) {
        let v = Float(min(1, max(0, strength)))
        for i in values.indices { values[i] = max(values[i], v) }
    }

    mutating func dab(x cx: Double, y cy: Double, radius r: Double, strength: Double, hardness: Double) {
        let w = width
        let x0 = max(0, Int((cx - r).rounded(.down)))
        let x1 = min(w - 1, Int((cx + r).rounded(.up)))
        let y0 = max(0, Int((cy - r).rounded(.down)))
        let y1 = min(height - 1, Int((cy + r).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let strength = min(1, max(0, strength))
        let inner = min(1, max(0, hardness))
        values.withUnsafeMutableBufferPointer { c in
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
}

public struct EraserStroke: LayerStroke {
    /// The picture before the stroke (premultiplied RGBA).
    public let base: PixelBuffer
    /// How much of each pixel is gone.
    public private(set) var coverage: BrushCoverage

    public init(base: PixelBuffer) {
        self.base = base
        coverage = BrushCoverage(width: base.width, height: base.height)
    }

    public var isEmpty: Bool { coverage.isEmpty }

    public mutating func move(toX x: Double, y: Double, radius: Double, strength: Double, hardness: Double) {
        coverage.move(toX: x, y: y, radius: radius, strength: strength, hardness: hardness)
    }

    /// The picture with the stroke erased.
    public func result() -> PixelBuffer {
        var out = base
        out.pixels.withUnsafeMutableBufferPointer { p in
            coverage.values.withUnsafeBufferPointer { c in
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

/// Evens out a layer's edge where it is painted: the transparency is
/// blurred, so steps and specks along a cut-out's outline go. Only the
/// transparency changes; the colors inside stay sharp. `crisp` keeps the
/// smoothed outline sharp instead of letting it fade out.
public struct SmoothStroke: LayerStroke {
    public let base: PixelBuffer
    /// `base` blurred by the smoothness; make it with `blurred(_:radius:)`.
    let blurred: PixelBuffer
    let crisp: Bool
    public private(set) var coverage: BrushCoverage

    public init(base: PixelBuffer, blurred: PixelBuffer, crisp: Bool) {
        precondition(base.width == blurred.width && base.height == blurred.height)
        self.base = base
        self.blurred = blurred
        self.crisp = crisp
        coverage = BrushCoverage(width: base.width, height: base.height)
    }

    public init(base: PixelBuffer, smoothness: Int, crisp: Bool) {
        self.init(base: base, blurred: Self.blurred(base, radius: smoothness), crisp: crisp)
    }

    public var isEmpty: Bool { coverage.isEmpty }

    public mutating func move(toX x: Double, y: Double, radius: Double, strength: Double, hardness: Double) {
        coverage.move(toX: x, y: y, radius: radius, strength: strength, hardness: hardness)
    }

    /// The whole outline at once.
    public mutating func coverAll(strength: Double) { coverage.coverAll(strength: strength) }

    public func result() -> PixelBuffer {
        var out = base
        let crisp = crisp
        out.pixels.withUnsafeMutableBufferPointer { p in
            blurred.pixels.withUnsafeBufferPointer { b in
                coverage.values.withUnsafeBufferPointer { c in
                    for i in 0..<c.count where c[i] > 0 {
                        let a = Float(p[i * 4 + 3])
                        let ba = Float(b[i * 4 + 3])
                        var target = ba / 255
                        if crisp {
                            // Steepen around the middle: a smooth outline, still sharp.
                            let t = min(1, max(0, (target - 0.5) * 3 + 0.5))
                            target = t * t * (3 - 2 * t)
                        }
                        let alpha = a + (target * 255 - a) * c[i]
                        // The color as it was; where there was none, the neighbors'.
                        for k in 0..<3 {
                            let color: Float =
                                a > 0 ? Float(p[i * 4 + k]) / a : ba > 0 ? Float(b[i * 4 + k]) / ba : 0
                            p[i * 4 + k] = UInt8(min(255, max(0, (color * alpha).rounded())))
                        }
                        p[i * 4 + 3] = UInt8(min(255, max(0, alpha.rounded())))
                    }
                }
            }
        }
        return out
    }

    /// Three box blurs of `radius` pixels (close to a Gaussian), edges
    /// repeated so the picture's border doesn't fade.
    public static func blurred(_ image: PixelBuffer, radius: Int) -> PixelBuffer {
        let r = max(1, radius)
        let w = image.width
        let h = image.height
        var channels = (0..<4).map { k in (0..<(w * h)).map { Float(image.pixels[$0 * 4 + k]) } }
        var line = [Float]()
        func box(_ data: inout [Float], count: Int, stride: Int, lines: Int, lineStride: Int) {
            line = [Float](repeating: 0, count: count)
            let n = Float(2 * r + 1)
            for l in 0..<lines {
                let start = l * lineStride
                func at(_ i: Int) -> Float { data[start + min(count - 1, max(0, i)) * stride] }
                var sum: Float = 0
                for i in -r...r { sum += at(i) }
                for i in 0..<count {
                    line[i] = sum / n
                    sum += at(i + r + 1) - at(i - r)
                }
                for i in 0..<count { data[start + i * stride] = line[i] }
            }
        }
        for k in 0..<4 {
            for _ in 0..<3 {
                box(&channels[k], count: w, stride: 1, lines: h, lineStride: w)
                box(&channels[k], count: h, stride: w, lines: w, lineStride: 1)
            }
        }
        var out = image
        for i in 0..<(w * h) {
            for k in 0..<4 { out.pixels[i * 4 + k] = UInt8(min(255, max(0, channels[k][i].rounded()))) }
        }
        return out
    }
}

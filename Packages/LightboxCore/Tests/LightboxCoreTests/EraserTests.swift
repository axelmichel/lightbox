import Foundation
import Testing

@testable import LightboxCore

/// An opaque white picture.
private func white(_ w: Int, _ h: Int) -> PixelBuffer {
    PixelBuffer(width: w, height: h, pixels: [UInt8](repeating: 255, count: w * h * 4))
}

private func alpha(_ b: PixelBuffer, _ x: Int, _ y: Int) -> UInt8 { b.pixels[(y * b.width + x) * 4 + 3] }

@Test func erasesAlongTheStroke() {
    var stroke = EraserStroke(base: white(40, 10))
    #expect(stroke.isEmpty)
    stroke.move(toX: 5, y: 5, radius: 3, strength: 1, hardness: 1)
    stroke.move(toX: 35, y: 5, radius: 3, strength: 1, hardness: 1)
    let out = stroke.result()
    // The whole line is gone, with no gaps; outside the radius nothing is.
    for x in 5...35 { #expect(alpha(out, x, 5) == 0) }
    #expect(alpha(out, 20, 0) == 255)
    #expect(alpha(out, 0, 5) == 255)
    // Premultiplied: the color goes with the alpha.
    #expect(out.pixels[(5 * 40 + 20) * 4] == 0)
}

@Test func strengthAndHardnessControlHowMuchGoes() {
    var half = EraserStroke(base: white(20, 20))
    half.move(toX: 10, y: 10, radius: 6, strength: 0.5, hardness: 1)
    #expect(alpha(half.result(), 10, 10) == 128)

    var soft = EraserStroke(base: white(20, 20))
    soft.move(toX: 10, y: 10, radius: 8, strength: 1, hardness: 0)
    let out = soft.result()
    // Full in the middle, fading towards the edge.
    #expect(alpha(out, 10, 10) < 10)
    #expect(alpha(out, 15, 10) > alpha(out, 12, 10))
    #expect(alpha(out, 15, 10) < 255)
}

@Test func overlappingDabsInOneStrokeDontBuildUp() {
    var stroke = EraserStroke(base: white(20, 20))
    for _ in 0..<5 {
        stroke.move(toX: 10, y: 10, radius: 4, strength: 0.4, hardness: 1)
        stroke.move(toX: 11, y: 10, radius: 4, strength: 0.4, hardness: 1)
    }
    #expect(alpha(stroke.result(), 10, 10) == 153)
}

/// A red square with a jagged step in its right edge, on transparency.
private func cutOut() -> PixelBuffer {
    var b = PixelBuffer(width: 40, height: 40, pixels: [UInt8](repeating: 0, count: 40 * 40 * 4))
    for y in 10..<30 {
        let right = y % 2 == 0 ? 30 : 28
        for x in 10..<right {
            b.pixels.replaceSubrange((y * 40 + x) * 4..<(y * 40 + x) * 4 + 4, with: [255, 0, 0, 255])
        }
    }
    return b
}

@Test func smoothingEvensOutTheEdgeOnly() {
    var stroke = SmoothStroke(base: cutOut(), smoothness: 2, crisp: false)
    stroke.coverAll(strength: 1)
    let out = stroke.result()
    // The steps along the right edge become alike.
    let a = alpha(out, 29, 20)
    let b = alpha(out, 29, 21)
    #expect(abs(Int(a) - Int(b)) < 60)
    // The inside stays opaque and red; far outside stays clear.
    #expect(alpha(out, 20, 20) == 255)
    #expect(out.pixels[(20 * 40 + 20) * 4] == 255)
    #expect(alpha(out, 2, 2) == 0)
    // A pixel that gains alpha takes its neighbors' color, not black.
    let i = (21 * 40 + 28) * 4
    if out.pixels[i + 3] > 20 { #expect(out.pixels[i] >= out.pixels[i + 3] - 2) }
}

@Test func crispSmoothingKeepsASharpOutline() {
    var soft = SmoothStroke(base: cutOut(), smoothness: 3, crisp: false)
    var crisp = SmoothStroke(base: cutOut(), smoothness: 3, crisp: true)
    soft.coverAll(strength: 1)
    crisp.coverAll(strength: 1)
    // Fewer half-transparent pixels along a row across the left edge.
    func half(_ b: PixelBuffer) -> Int { (0..<40).filter { (20...235).contains(alpha(b, $0, 20)) }.count }
    #expect(half(crisp.result()) < half(soft.result()))
}

@Test func smoothingOnlyWherePainted() {
    var stroke = SmoothStroke(base: cutOut(), smoothness: 2, crisp: false)
    stroke.move(toX: 29, y: 15, radius: 3, strength: 1, hardness: 1)
    let out = stroke.result()
    // Far from the stroke the steps stay.
    #expect(alpha(out, 28, 27) == 0)
    #expect(alpha(out, 29, 26) == 255)
}

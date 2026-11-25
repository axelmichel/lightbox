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

import Testing

@testable import LightboxCore

/// A buffer from rows of characters: "." white, "#" black, "g" light gray
/// (white within tolerance 32), "_" transparent.
private func buffer(_ rows: [String]) -> PixelBuffer {
    var pixels: [UInt8] = []
    for row in rows {
        for c in row {
            switch c {
            case "#": pixels += [0, 0, 0, 255]
            case "g": pixels += [235, 235, 235, 255]
            case "_": pixels += [0, 0, 0, 0]
            default: pixels += [255, 255, 255, 255]
            }
        }
    }
    return PixelBuffer(width: rows[0].count, height: rows.count, pixels: pixels)
}

private func picture(_ mask: SelectionMask) -> [String] {
    (0..<mask.height).map { y in String((0..<mask.width).map { mask[$0, y] ? "x" : "-" }) }
}

// White outside a black ring, white inside it too.
private let ring = buffer([
    "......",
    ".####.",
    ".#..#.",
    ".####.",
    "......",
])

@Test func contiguousSelectionStopsAtOtherColors() {
    let outside = MagicWand.select(ring, x: 0, y: 0, tolerance: 0)
    #expect(
        picture(outside) == [
            "xxxxxx",
            "x----x",
            "x----x",
            "x----x",
            "xxxxxx",
        ])
}

@Test func nonContiguousSelectionTakesTheColorEverywhere() {
    let white = MagicWand.select(ring, x: 0, y: 0, tolerance: 0, contiguous: false)
    #expect(white.count == 18 + 2)
    #expect(white[2, 2] && white[3, 2])
}

@Test func toleranceDecidesWhatCountsAsTheSameColor() {
    let image = buffer(["..gg##"])
    #expect(picture(MagicWand.select(image, x: 0, y: 0, tolerance: 10)) == ["xx----"])
    #expect(picture(MagicWand.select(image, x: 0, y: 0, tolerance: 32)) == ["xxxx--"])
    #expect(picture(MagicWand.select(image, x: 0, y: 0, tolerance: 255)) == ["xxxxxx"])
}

@Test func floodFillReachesAroundCorners() {
    // A white path that turns back on itself.
    let image = buffer([
        ".#....",
        ".#.##.",
        ".#.#..",
        "...#.#",
    ])
    let path = MagicWand.select(image, x: 0, y: 0, tolerance: 0)
    #expect(
        picture(path) == [
            "x-xxxx",
            "x-x--x",
            "x-x-xx",
            "xxx-x-",
        ])
}

@Test func clicksOutsideTheImageSelectNothing() {
    #expect(MagicWand.select(ring, x: -1, y: 0, tolerance: 255).isEmpty)
    #expect(MagicWand.select(ring, x: 6, y: 0, tolerance: 255).isEmpty)
}

@Test func transparentPixelsAreAColorOfTheirOwn() {
    let image = buffer(["__..", "__##"])
    #expect(picture(MagicWand.select(image, x: 0, y: 0, tolerance: 20)) == ["xx--", "xx--"])
}

@Test func selectionsCombine() {
    let image = buffer(["..##.."])
    var both = MagicWand.select(image, x: 0, y: 0, tolerance: 0)
    both.formUnion(MagicWand.select(image, x: 5, y: 0, tolerance: 0))
    #expect(picture(both) == ["xx--xx"])
    both.subtract(MagicWand.select(image, x: 0, y: 0, tolerance: 0))
    #expect(picture(both) == ["----xx"])
}

@Test func eraseMakesTheSelectionTransparent() {
    let mask = MagicWand.select(ring, x: 0, y: 0, tolerance: 0)
    let hard = MagicWand.erase(ring, mask, antiAlias: false)
    func alpha(_ b: PixelBuffer, _ x: Int, _ y: Int) -> UInt8 { b.pixels[(y * b.width + x) * 4 + 3] }
    #expect(alpha(hard, 0, 0) == 0)
    #expect(alpha(hard, 1, 1) == 255)
    #expect(alpha(hard, 2, 2) == 255)
    // Premultiplied: color goes with alpha.
    #expect(hard.pixels[0..<4] == [0, 0, 0, 0])

    let soft = MagicWand.erase(ring, mask, antiAlias: true)
    #expect(alpha(soft, 0, 0) == 0)
    // The ring's pixels next to the removed area are faded a little; pixels
    // with no selected neighbor are not.
    #expect(alpha(soft, 1, 1) > 0 && alpha(soft, 1, 1) < 255)
    #expect(alpha(soft, 2, 2) == 255)
}

@Test func overlayMarksTheEdgeStronger() {
    let mask = MagicWand.select(buffer(["....", "....", "....", "####"]), x: 1, y: 1, tolerance: 0)
    let o = mask.overlay(red: 0, green: 0.5, blue: 1)
    func alpha(_ x: Int, _ y: Int) -> UInt8 { o.pixels[(y * 4 + x) * 4 + 3] }
    #expect(alpha(0, 0) > alpha(1, 1))
    #expect(alpha(1, 1) > 0)
    #expect(alpha(1, 3) == 0)
}

@Test func pixelBufferRoundTripsThroughPNG() throws {
    let png = try #require(ring.pngData())
    #expect(PixelBuffer(data: png) == ring)
}

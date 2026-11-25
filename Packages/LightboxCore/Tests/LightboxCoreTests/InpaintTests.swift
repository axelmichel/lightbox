import CoreGraphics
import Foundation
import Testing

@testable import LightboxCore

private func mask(_ w: Int, _ h: Int, _ rect: (x: Int, y: Int, w: Int, h: Int)) -> SelectionMask {
    var m = SelectionMask(width: w, height: h)
    for y in rect.y..<(rect.y + rect.h) {
        for x in rect.x..<(rect.x + rect.w) { m.values[y * w + x] = 1 }
    }
    return m
}

private func solid(_ w: Int, _ h: Int, _ rgba: [UInt8]) -> PixelBuffer {
    PixelBuffer(width: w, height: h, pixels: Array([[UInt8]](repeating: rgba, count: w * h).joined()))
}

@Test func nothingSelectedIsNoRegion() {
    #expect(InpaintRegion.plan(mask: SelectionMask(width: 10, height: 10), family: .sdxl) == nil)
}

@Test func regionHasRoomAroundTheSelectionAndTheModelsSize() throws {
    let r = try #require(InpaintRegion.plan(mask: mask(2000, 1500, (900, 700, 200, 100)), family: .sdxl))
    // Padded, at least 384 wide, inside the picture.
    #expect(r.x < 900 && r.y < 700 && r.x + r.width > 1100 && r.y + r.height > 800)
    #expect(r.width >= 384 && r.height >= 384)
    #expect(r.workWidth % 8 == 0 && r.workHeight % 8 == 0)
    let area = Double(r.workWidth * r.workHeight)
    #expect(abs(area / (1024 * 1024) - 1) < 0.1)
    #expect(abs(Double(r.workWidth) / Double(r.workHeight) - Double(r.width) / Double(r.height)) < 0.05)
}

@Test func regionStaysInsideThePicture() throws {
    let r = try #require(InpaintRegion.plan(mask: mask(300, 200, (0, 0, 300, 200)), family: .sd15))
    #expect((r.x, r.y, r.width, r.height) == (0, 0, 300, 200))
    // Small pictures are scaled up, at most 4×.
    #expect(r.workWidth <= 1200 && r.workWidth > 300)
}

@Test func preparedPicturesHaveTheWorkSize() throws {
    let m = mask(400, 400, (150, 150, 100, 100))
    let r = try #require(InpaintRegion.plan(mask: m, family: .sdxl))
    let sent = try #require(Inpaint.prepare(solid(400, 400, [255, 0, 0, 255]), mask: m, region: r))
    let image = try #require(ImageCoding.decode(sent.image))
    let maskImage = try #require(ImageCoding.decode(sent.mask))
    #expect((image.width, image.height) == (r.workWidth, r.workHeight))
    #expect((maskImage.width, maskImage.height) == (r.workWidth, r.workHeight))
    let mb = try #require(PixelBuffer(maskImage))
    let center = (r.workHeight / 2 * r.workWidth + r.workWidth / 2) * 4
    #expect(mb.pixels[center] == 255)
    #expect(mb.pixels[0] == 0)
}

@Test func mergeChangesOnlyTheSelectionWithASoftEdge() throws {
    let m = mask(400, 400, (150, 150, 100, 100))
    let r = try #require(InpaintRegion.plan(mask: m, family: .sdxl))
    let original = solid(400, 400, [255, 0, 0, 255])
    let result = try #require(solid(r.workWidth, r.workHeight, [0, 0, 255, 255]).cgImage())
    let out = try #require(Inpaint.merge(result, into: original, mask: m, region: r))
    func px(_ x: Int, _ y: Int) -> [UInt8] { Array(out.pixels[(y * 400 + x) * 4..<(y * 400 + x) * 4 + 4]) }
    #expect(px(200, 200) == [0, 0, 255, 255])  // inside: the model's
    #expect(px(5, 5) == [255, 0, 0, 255])  // far outside: untouched
    #expect(px(399, 399) == [255, 0, 0, 255])
    let edge = px(150 - r.grow - r.feather / 2, 200)  // in the soft edge: a mix
    #expect(edge[0] > 0 && edge[0] < 255 && edge[2] > 0)
}

@Test func blurKeepsTheTotalAndGrowWidens() {
    var m = [Float](repeating: 0, count: 21 * 21)
    m[10 * 21 + 10] = 1
    let soft = Inpaint.blur(m, width: 21, height: 21, radius: 2)
    #expect(abs(soft.reduce(0, +) - 1) < 0.001)
    let grown = Inpaint.grow(m, width: 21, height: 21, by: 2)
    #expect(grown[10 * 21 + 14] == 1 && grown[10 * 21 + 18] == 0)
}

@Test func areasAreRectanglesOrEllipses() {
    let rect = SelectionMask.area(
        width: 10, height: 10, frame: ImageFrame(x: 2, y: 2, width: 4, height: 4), ellipse: false)
    #expect(rect.count == 16 && rect[2, 2] && !rect[6, 6])
    let oval = SelectionMask.area(
        width: 10, height: 10, frame: ImageFrame(x: 0, y: 0, width: 10, height: 10), ellipse: true)
    #expect(oval[5, 5] && !oval[0, 0] && oval.count < 100 && oval.count > 70)
    // Partly outside: cut to the canvas.
    let cut = SelectionMask.area(
        width: 10, height: 10, frame: ImageFrame(x: -5, y: 8, width: 10, height: 10), ellipse: false)
    #expect(cut.count == 5 * 2)
}

@Test func patchesAreTransparentOutsideTheArea() throws {
    let m = mask(400, 400, (150, 150, 100, 100))
    let r = try #require(InpaintRegion.plan(mask: m, family: .sdxl))
    let result = try #require(solid(r.workWidth, r.workHeight, [0, 0, 255, 255]).cgImage())
    let patch = try #require(Inpaint.patch(result, mask: m, region: r))
    #expect((patch.width, patch.height) == (r.width, r.height))
    func px(_ x: Int, _ y: Int) -> [UInt8] { Array(patch.pixels[(y * r.width + x) * 4..<(y * r.width + x) * 4 + 4]) }
    #expect(px(200 - r.x, 200 - r.y) == [0, 0, 255, 255])
    #expect(px(0, 0) == [0, 0, 0, 0])
    let edge = px(150 - r.x - r.grow - r.feather / 2, 200 - r.y)
    #expect(edge[3] > 0 && edge[3] < 255 && edge[2] == edge[3])  // premultiplied
}

@Test func editsAreSentAtAboutAMegapixel() {
    let (w, h) = ImageEdit.workSize(width: 1216, height: 832)
    #expect(w % 16 == 0 && h % 16 == 0)
    #expect(abs(Double(w * h) / (1024 * 1024) - 1) < 0.05)
    #expect(abs(Double(w) / Double(h) - 1216.0 / 832) < 0.03)
    #expect(ImageEdit.workSize(width: 100, height: 100) == (208, 208))  // at most twice as large
}

@Test func editedPicturesBecomeLayersWholeOrInAnArea() throws {
    let result = try #require(solid(64, 64, [0, 0, 255, 255]).cgImage())
    let whole = try #require(ImageEdit.layer(from: result, width: 400, height: 300))
    #expect(whole.frame == ImageFrame(x: 0, y: 0, width: 400, height: 300))
    #expect((whole.picture.width, whole.picture.height) == (400, 300))

    let m = mask(400, 300, (150, 100, 80, 60))
    let part = try #require(ImageEdit.layer(from: result, width: 400, height: 300, mask: m))
    #expect(part.frame.width < 400 && part.frame.x <= 150)
    let px = { (x: Int, y: Int) -> UInt8 in part.picture.pixels[(y * part.picture.width + x) * 4 + 3] }
    #expect(px(190 - Int(part.frame.x), 130 - Int(part.frame.y)) == 255)  // inside: opaque
    #expect(px(0, 0) == 0)  // outside: transparent
}

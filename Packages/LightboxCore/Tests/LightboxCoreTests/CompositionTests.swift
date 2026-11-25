import CoreGraphics
import Foundation
import Testing

@testable import LightboxCore

/// A picture of one color (premultiplied RGBA 0…255).
private func solid(_ w: Int, _ h: Int, _ rgba: [UInt8]) -> CGImage {
    PixelBuffer(width: w, height: h, pixels: Array([[UInt8]](repeating: rgba, count: w * h).joined())).cgImage()!
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let b = PixelBuffer(image)!
    let o = (y * b.width + x) * 4
    return Array(b.pixels[o..<o + 4])
}

private func near(_ a: [UInt8], _ b: [UInt8], _ tolerance: Int = 2) -> Bool {
    zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}

@Test func firstLayerSetsTheCanvasAndLaterOnesFit() {
    var c = Composition(name: "C")
    let a = c.addLayer(name: "A", width: 800, height: 600)
    #expect((c.width, c.height) == (800, 600))
    #expect(c.layer(a)?.frame == ImageFrame(x: 0, y: 0, width: 800, height: 600))

    let big = c.addLayer(name: "B", width: 1600, height: 600)
    #expect(c.layer(big)?.frame == ImageFrame(x: 0, y: 150, width: 800, height: 300))
    let small = c.addLayer(name: "S", width: 100, height: 50)
    #expect(c.layer(small)?.frame == ImageFrame(x: 350, y: 275, width: 100, height: 50))
    #expect(c.layerList.map(\.name) == ["S", "B", "A"])
}

@Test func layersReorderInTheTopFirstList() {
    var c = Composition(name: "C")
    for name in ["A", "B", "C", "D"] { c.addLayer(name: name, width: 10, height: 10) }
    // List: D C B A. Drag A (offset 3) to the top.
    c.moveLayers(fromOffsets: [3], toOffset: 0)
    #expect(c.layerList.map(\.name) == ["A", "D", "C", "B"])
    // Drag D (offset 1) below B.
    c.moveLayers(fromOffsets: [1], toOffset: 4)
    #expect(c.layerList.map(\.name) == ["A", "C", "B", "D"])

    let b = c.layers.first { $0.name == "B" }!.id
    c.moveLayer(b, by: 1)
    #expect(c.layerList.map(\.name) == ["A", "B", "C", "D"])
    c.moveLayer(c.layers.last!.id, by: 1)  // already on top
    #expect(c.layerList.map(\.name) == ["A", "B", "C", "D"])
}

@Test func layersScaleAroundTheirCenter() {
    var c = Composition(name: "C")
    let a = c.addLayer(name: "A", width: 100, height: 50)
    c.setScale(a, to: 2)
    #expect(c.layer(a)?.frame == ImageFrame(x: -50, y: -25, width: 200, height: 100))
    #expect(c.layer(a)?.scale == 2)
}

@Test func cornerHandlesResizeFromTheOppositeCorner() {
    var c = Composition(name: "C", width: 400, height: 400)
    c.addLayer(name: "bottom", width: 400, height: 400)
    let a = c.addLayer(name: "A", width: 100, height: 50)
    let start = c.layer(a)!.frame  // 150,175 100×50
    c.resize(a, corner: .bottomRight, to: start.x + 300, start.y + 50)
    #expect(c.layer(a)?.frame == ImageFrame(x: start.x, y: start.y, width: 300, height: 150))

    c.resize(a, corner: .topLeft, to: start.x + 200, start.y + 100, keepAspect: false)
    #expect(c.layer(a)?.frame == ImageFrame(x: start.x + 200, y: start.y + 100, width: 100, height: 50))

    // Past the opposite corner: stays a few pixels wide.
    c.resize(a, corner: .topRight, to: 0, 1000)
    #expect(c.layer(a)!.frame.width >= 4 && c.layer(a)!.frame.height >= 4)
}

@Test func hitTestFindsTheTopmostVisibleLayer() {
    var c = Composition(name: "C")
    let a = c.addLayer(name: "A", width: 100, height: 100)
    let b = c.addLayer(name: "B", width: 50, height: 50)  // 25…75
    #expect(c.hitTest(x: 50, y: 50) == b)
    #expect(c.hitTest(x: 10, y: 10) == a)
    c.update(b) { $0.visible = false }
    #expect(c.hitTest(x: 50, y: 50) == a)
    #expect(c.hitTest(x: 150, y: 50) == nil)
}

@Test func canvasFitsTheLayersAndResizesAroundTheCenter() {
    var c = Composition(name: "C")
    let a = c.addLayer(name: "A", width: 100, height: 100)
    c.update(a) { $0.frame = ImageFrame(x: 20.5, y: -10, width: 50, height: 30) }
    c.fitCanvasToLayers()
    #expect((c.width, c.height) == (51, 30))
    #expect(c.layer(a)?.frame == ImageFrame(x: 0.5, y: 0, width: 50, height: 30))

    c.setCanvas(width: 151, height: 50)
    #expect(c.layer(a)?.frame == ImageFrame(x: 50.5, y: 10, width: 50, height: 30))
}

@Test func flattenDrawsLayersInOrderAtTheirFrames() throws {
    var c = Composition(name: "C")
    let red = UUID()
    let blue = UUID()
    c.addLayer(name: "red", image: red, width: 4, height: 4)
    let b = c.addLayer(name: "blue", image: blue, width: 2, height: 2)
    c.update(b) { $0.frame = ImageFrame(x: 0, y: 0, width: 2, height: 2) }
    let images = [red: solid(4, 4, [255, 0, 0, 255]), blue: solid(2, 2, [0, 0, 255, 255])]

    let out = try #require(c.flatten(images: images))
    #expect((out.width, out.height) == (4, 4))
    #expect(pixel(out, 0, 0) == [0, 0, 255, 255])  // blue on top, top left
    #expect(pixel(out, 3, 3) == [255, 0, 0, 255])

    c.update(b) { $0.opacity = 0.5 }
    let half = try #require(c.flatten(images: images))
    #expect(near(pixel(half, 0, 0), [128, 0, 128, 255]))

    c.update(b) { $0.visible = false }
    #expect(pixel(c.flatten(images: images)!, 0, 0) == [255, 0, 0, 255])
}

@Test func flattenMakesLayersOrEverythingGray() throws {
    var c = Composition(name: "C")
    let red = UUID()
    let green = UUID()
    let r = c.addLayer(name: "red", image: red, width: 2, height: 1)
    let g = c.addLayer(name: "green", image: green, width: 1, height: 1)
    c.update(g) { $0.frame = ImageFrame(x: 1, y: 0, width: 1, height: 1) }
    let images = [red: solid(2, 1, [255, 0, 0, 255]), green: solid(1, 1, [0, 255, 0, 255])]

    c.update(r) { $0.grayscale = true }
    var out = try #require(c.flatten(images: images))
    #expect(near(pixel(out, 0, 0), [54, 54, 54, 255]))
    #expect(pixel(out, 1, 0) == [0, 255, 0, 255])

    c.update(r) { $0.grayscale = false }
    c.grayscale = true
    out = try #require(c.flatten(images: images))
    #expect(near(pixel(out, 0, 0), [54, 54, 54, 255]))
    #expect(near(pixel(out, 1, 0), [182, 182, 182, 255]))
}

@Test func backgroundShowsWhereNoLayerIs() throws {
    var c = Composition(name: "C")
    let a = c.addLayer(name: "A", width: 2, height: 1)
    c.update(a) { $0.frame = ImageFrame(x: 0, y: 0, width: 1, height: 1) }
    let images = [c.layers[0].image: solid(2, 1, [255, 0, 0, 255])]
    #expect(pixel(c.flatten(images: images)!, 1, 0) == [0, 0, 0, 0])
    c.background = .white
    #expect(pixel(c.flatten(images: images)!, 1, 0) == [255, 255, 255, 255])
}

@Test func grayscaleKeepsAlpha() {
    let b = PixelBuffer(width: 1, height: 1, pixels: [128, 0, 0, 128]).grayscaled()
    #expect(b.pixels == [27, 27, 27, 128])
}

@Test func invertedSelectsTheRest() {
    var m = SelectionMask(width: 2, height: 1)
    m.values = [1, 0]
    #expect(m.inverted().values == [0, 1])
}

@Test func layerPixelsFollowTheFrame() {
    let layer = CompositionLayer(
        name: "A", pixelWidth: 100, pixelHeight: 50, frame: ImageFrame(x: 10, y: 10, width: 200, height: 100))
    #expect(layer.pixel(atX: 10, y: 10) == (0, 0))
    #expect(layer.pixel(atX: 209.9, y: 109.9) == (99, 49))
    #expect(layer.scale == 2)
}

@Test func storeKeepsCompositionsWithTheirLayers() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "lightbox-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CompositionStore(root: root)
    var c = Composition(name: "Two foxes", date: Date(timeIntervalSince1970: 1000))
    let first = UUID()
    let second = UUID()
    let a = c.addLayer(name: "A", image: first, width: 4, height: 2)
    let png = Data([1, 2, 3])
    try store.save(c, images: [first: png])
    #expect(try store.load(c.id) == c)
    #expect(store.layerImage(c.id, image: first) == png)

    // The wand made a new picture for the layer: the old file goes.
    c.update(a) { $0.image = second }
    try store.save(c, images: [first: png, second: Data([4])])
    #expect(store.layerImage(c.id, image: first) == nil)
    #expect(store.layerImage(c.id, image: second) == Data([4]))

    var newer = Composition(name: "Newer", date: Date(timeIntervalSince1970: 2000))
    newer.modified = Date(timeIntervalSince1970: 3000)
    try store.save(newer, images: [:])
    #expect(store.list().map(\.name) == ["Newer", "Two foxes"])
    store.delete(newer.id)
    #expect(store.list().map(\.name) == ["Two foxes"])
}

@Test func oldGalleryItemsHaveNoComposition() throws {
    let input = PromptInput(
        preset: GenerationPreset(name: "P", checkpoint: "m.safetensors"), prompt: "a fox", rating: .allAges)
    let item = GalleryItem(
        width: 1, height: 1, recipe: GenerationRecipe(input: input, sent: try compose(input), seed: 1, finish: .init()))
    var json = try JSONSerialization.jsonObject(with: JSONEncoder.gallery.encode(item)) as! [String: Any]
    json["composition"] = nil
    let old = try JSONDecoder.gallery.decode(GalleryItem.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.composition == nil)
    #expect(old.id == item.id)
}

@Test func emptyLayersCoverTheCanvasAboveTheSelectedOne() {
    var c = Composition(name: "C", width: 300, height: 200)
    let a = c.addLayer(name: "A", width: 300, height: 200)
    c.addLayer(name: "B", width: 100, height: 100)
    let e = c.addEmptyLayer(name: c.nextLayerName, above: a)
    #expect(c.layers.map(\.name) == ["A", "Layer 1", "B"])
    #expect(c.layer(e)?.frame == c.bounds)
    #expect((c.layer(e)?.pixelWidth, c.layer(e)?.pixelHeight) == (300, 200))
    c.addEmptyLayer(name: c.nextLayerName)
    #expect(c.layers.last?.name == "Layer 2")
    #expect(c.recipe == nil)
}

@Test func emptyPicturesAreTransparent() throws {
    let png = try #require(ImageCoding.emptyPNG(width: 4, height: 3))
    let image = try #require(ImageCoding.decodeUpright(png))
    #expect((image.width, image.height) == (4, 3))
    #expect(PixelBuffer(image)?.pixels.allSatisfy { $0 == 0 } == true)
}

@Test func composedRecipesHaveNoPrompt() throws {
    let r = GenerationRecipe.composed(rating: .allAges)
    #expect(r.prompt.isEmpty)
    let data = try JSONEncoder.gallery.encode(r)
    #expect(try JSONDecoder.gallery.decode(GenerationRecipe.self, from: data).prompt.isEmpty)
}

@Test func renderingLayersBakesTheirLookIntoOnePicture() throws {
    var c = Composition(name: "C", width: 4, height: 4)
    let red = UUID()
    let blue = UUID()
    let a = c.addLayer(name: "red", image: red, width: 4, height: 4)
    let b = c.addLayer(name: "blue", image: blue, width: 2, height: 2)
    c.update(b) {
        $0.frame = ImageFrame(x: 3, y: 3, width: 2, height: 2)  // partly off the canvas
        $0.opacity = 0.5
    }
    let images = [red: solid(4, 4, [255, 0, 0, 255]), blue: solid(2, 2, [0, 0, 255, 255])]
    let (frame, image) = try #require(c.render([a, b], images: images))
    #expect(frame == ImageFrame(x: 0, y: 0, width: 5, height: 5))  // keeps what is off the canvas
    #expect((image.width, image.height) == (5, 5))
    #expect(pixel(image, 0, 0) == [255, 0, 0, 255])
    #expect(near(pixel(image, 3, 3), [128, 0, 128, 255]))  // blue at half over red
    #expect(near(pixel(image, 4, 4), [0, 0, 128, 128]))  // blue at half, nothing under it
    #expect(c.render([], images: images) == nil)
}

@Test func mergedLayersTakeTheLowestPlace() {
    var c = Composition(name: "C")
    for name in ["A", "B", "C", "D"] { c.addLayer(name: name, width: 10, height: 10) }
    let ids = Set(c.layers.filter { $0.name == "B" || $0.name == "D" }.map(\.id))
    let merged = CompositionLayer(name: "B", pixelWidth: 10, pixelHeight: 10, frame: c.bounds)
    c.replace(ids, with: merged)
    #expect(c.layers.map(\.name) == ["A", "B", "C"])
    #expect(c.layers[1].id == merged.id)
    #expect(c.layer(below: merged.id)?.name == "A")
    #expect(c.layer(below: c.layers[0].id) == nil)
}

/// A 10×10 picture: transparent, with a white square at 2…5 (x and y).
private func square() -> CGImage {
    var px = [UInt8](repeating: 0, count: 10 * 10 * 4)
    for y in 2...5 { for x in 2...5 { for c in 0..<4 { px[(y * 10 + x) * 4 + c] = 255 } } }
    return PixelBuffer(width: 10, height: 10, pixels: px).cgImage()!
}

@Test func dropShadowsFallWhereTheyPoint() throws {
    var s = LayerShadow(style: .drop)
    (s.angle, s.distance, s.blur, s.opacity) = (90, 0.3, 0, 1)  // 3 px straight down
    let (image, rect) = try #require(s.render(square()))
    #expect(rect.minY > 0)  // moved down
    let b = try #require(PixelBuffer(image))
    // The square's shadow is at y 5…8 of the picture: dark and opaque.
    let y = Int(5 - rect.minY)
    let x = Int(3 - rect.minX)
    let o = (y * b.width + x) * 4
    #expect(Array(b.pixels[o..<o + 4]) == [0, 0, 0, 255])
}

@Test func castShadowsStandOnTheLowestPoint() throws {
    var s = LayerShadow(style: .cast)
    (s.angle, s.distance, s.blur) = (0, 0.5, 0)
    #expect(LayerShadow.lowestRow(square()) == 5)
    let (_, rect) = try #require(s.render(square()))
    // Squashed to half its height, its foot on row 5 (bottom at 6).
    #expect(abs(rect.maxY - 6) < 0.6)
    #expect(rect.height <= 2.6)
}

@Test func flattenDrawsTheShadowUnderTheLayer() throws {
    var c = Composition(name: "C", width: 10, height: 10)
    c.background = .white
    let image = UUID()
    let id = c.addLayer(name: "A", image: image, width: 10, height: 10)
    var s = LayerShadow(style: .drop)
    (s.angle, s.distance, s.blur, s.opacity) = (0, 0.3, 0, 1)  // 3 px to the right
    c.update(id) { $0.shadow = s }
    let out = try #require(c.flatten(images: [image: square()]))
    #expect(pixel(out, 3, 3) == [255, 255, 255, 255])  // the square itself
    #expect(pixel(out, 7, 3) == [0, 0, 0, 255])  // its shadow, right of it
    #expect(pixel(out, 0, 0) == [255, 255, 255, 255])
    // Merging keeps the shadow in the picture.
    let merged = try #require(c.render([id], images: [image: square()]))
    #expect(merged.frame.maxX >= 9)
}

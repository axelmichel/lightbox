// A composition: several gallery pictures as layers on one canvas, saved
// with its layers so it can be edited again, and flattened into a new
// gallery picture.

import CoreGraphics
import Foundation

/// Where a layer is drawn, in canvas pixels (y going down). Not rounded, so
/// moving and scaling keep full quality.
public struct ImageFrame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func contains(x px: Double, y py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }

    public func offset(by dx: Double, _ dy: Double) -> ImageFrame {
        ImageFrame(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Scaled around its center.
    public func scaled(by k: Double) -> ImageFrame {
        let w = width * k
        let h = height * k
        return ImageFrame(x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
    }

    /// A picture of `width` × `height` centered in `bounds`, all of it
    /// shown (`fill: false`) or covering all of `bounds` (`fill: true`).
    public static func fitting(width: Int, height: Int, in bounds: ImageFrame, fill: Bool) -> ImageFrame {
        let sx = bounds.width / Double(width)
        let sy = bounds.height / Double(height)
        let k = fill ? max(sx, sy) : min(sx, sy)
        let w = Double(width) * k
        let h = Double(height) * k
        return ImageFrame(
            x: bounds.x + (bounds.width - w) / 2, y: bounds.y + (bounds.height - h) / 2, width: w, height: h)
    }
}

public struct CompositionLayer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The layer's picture, `layers/<image>.png`. A new id each time its
    /// pixels change (the magic wand), so undo can go back to the old file.
    public var image: UUID
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var frame: ImageFrame
    public var opacity: Double = 1
    public var grayscale = false
    public var visible = true
    /// The gallery picture it came from, and that picture's recipe (kept
    /// here so it survives deleting the picture).
    public var source: UUID?
    public var recipe: GenerationRecipe?
    /// Parts painted again with the model, oldest first.
    public var edits: [GenerationRecipe]?
    /// A shadow made from what the layer shows; `nil` = none.
    public var shadow: LayerShadow?

    public init(
        id: UUID = UUID(), name: String, image: UUID = UUID(), pixelWidth: Int, pixelHeight: Int, frame: ImageFrame,
        source: UUID? = nil, recipe: GenerationRecipe? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frame = frame
        self.source = source
        self.recipe = recipe
    }

    /// Size in percent of the picture's own pixels.
    public var scale: Double { frame.width / Double(pixelWidth) }

    /// A canvas point in the layer's picture pixels.
    public func pixel(atX x: Double, y: Double) -> (x: Int, y: Int) {
        (
            Int(((x - frame.x) / frame.width * Double(pixelWidth)).rounded(.down)),
            Int(((y - frame.y) / frame.height * Double(pixelHeight)).rounded(.down))
        )
    }
}

public struct Composition: Codable, Hashable, Identifiable, Sendable {
    public enum Background: String, Codable, CaseIterable, Sendable {
        case transparent, white, black

        public var label: String {
            switch self {
            case .transparent: "Transparent"
            case .white: "White"
            case .black: "Black"
            }
        }
    }

    public enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    public static let currentVersion = 1
    public static let maxSide = 8192

    public var version = currentVersion
    public var id: UUID
    public var name: String
    public var created: Date
    public var modified: Date
    public var width: Int
    public var height: Int
    public var background: Background = .transparent
    /// The whole picture in gray.
    public var grayscale = false
    /// Bottom to top.
    public var layers: [CompositionLayer] = []
    /// The gallery picture made by the last "Save to Gallery".
    public var output: UUID?
    /// Guide lines dragged out of the rulers; `nil` in older files.
    public var guides: [CanvasGuide]?

    public init(id: UUID = UUID(), name: String, width: Int = 1024, height: Int = 1024, date: Date = Date()) {
        self.id = id
        self.name = name
        self.created = date
        self.modified = date
        self.width = width
        self.height = height
    }

    public var bounds: ImageFrame { ImageFrame(x: 0, y: 0, width: Double(width), height: Double(height)) }

    /// Top first, as the layer list shows them.
    public var layerList: [CompositionLayer] { layers.reversed() }

    public func layer(_ id: UUID?) -> CompositionLayer? {
        layers.first { $0.id == id }
    }

    /// Add a picture on top. The first one sets the canvas size; later ones
    /// are centered and made smaller if they don't fit.
    @discardableResult
    public mutating func addLayer(
        name: String, image: UUID = UUID(), width w: Int, height h: Int, source: UUID? = nil,
        recipe: GenerationRecipe? = nil
    ) -> UUID {
        if layers.isEmpty {
            (width, height) = (min(w, Self.maxSide), min(h, Self.maxSide))
        }
        var frame = ImageFrame.fitting(width: w, height: h, in: bounds, fill: false)
        if frame.width > Double(w) { frame = frame.scaled(by: Double(w) / frame.width) }
        let layer = CompositionLayer(
            name: name, image: image, pixelWidth: w, pixelHeight: h, frame: frame, source: source, recipe: recipe)
        layers.append(layer)
        return layer.id
    }

    /// A transparent layer the size of the canvas, on top of the selected
    /// one (`above`) or on top of all. Its picture is made by the caller.
    @discardableResult
    public mutating func addEmptyLayer(name: String, image: UUID = UUID(), above: UUID? = nil) -> UUID {
        let layer = CompositionLayer(
            name: name, image: image, pixelWidth: width, pixelHeight: height, frame: bounds)
        let i = layers.firstIndex { $0.id == above }.map { $0 + 1 } ?? layers.endIndex
        layers.insert(layer, at: i)
        return layer.id
    }

    /// "Layer 1", "Layer 2", … : the first number no layer is named with.
    public var nextLayerName: String {
        var n = 1
        while layers.contains(where: { $0.name == "Layer \(n)" }) { n += 1 }
        return "Layer \(n)"
    }

    /// Put a layer on top as it is (frame and all).
    public mutating func insertOnTop(_ layer: CompositionLayer) {
        layers.append(layer)
    }

    public mutating func update(_ id: UUID, _ change: (inout CompositionLayer) -> Void) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[i])
    }

    public mutating func remove(_ id: UUID) {
        layers.removeAll { $0.id == id }
    }

    /// Reorder as `List.onMove` does, with offsets into `layerList` (top first).
    public mutating func moveLayers(fromOffsets offsets: IndexSet, toOffset: Int) {
        let list = layerList
        let moving = offsets.map { list[$0] }
        var rest = list.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let at = toOffset - offsets.count(in: 0..<toOffset)
        rest.insert(contentsOf: moving, at: max(0, min(at, rest.count)))
        layers = rest.reversed()
    }

    /// One step up (towards the top, `delta` 1) or down (-1).
    public mutating func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard layers.indices.contains(j) else { return }
        layers.swapAt(i, j)
    }

    /// Scale a layer around its center to `scale` times its picture's pixels.
    public mutating func setScale(_ id: UUID, to scale: Double) {
        update(id) { $0.frame = $0.frame.scaled(by: max(0.01, scale) / $0.scale) }
    }

    /// Drag `corner` of a layer to a canvas point; the opposite corner stays.
    /// With `keepAspect` the picture keeps its proportions.
    public mutating func resize(_ id: UUID, corner: Corner, to x: Double, _ y: Double, keepAspect: Bool = true) {
        update(id) { layer in
            let f = layer.frame
            let ax = corner.isLeft ? f.maxX : f.x
            let ay = corner.isTop ? f.maxY : f.y
            var w = max(4, corner.isLeft ? ax - x : x - ax)
            var h = max(4, corner.isTop ? ay - y : y - ay)
            if keepAspect {
                let k = max(w / f.width, h / f.height)
                (w, h) = (max(4, f.width * k), max(4, f.height * k))
            }
            layer.frame = ImageFrame(x: corner.isLeft ? ax - w : ax, y: corner.isTop ? ay - h : ay, width: w, height: h)
        }
    }

    /// The topmost visible layer at a canvas point.
    public func hitTest(x: Double, y: Double) -> UUID? {
        layers.last { $0.visible && $0.frame.contains(x: x, y: y) }?.id
    }

    /// A new canvas size; the layers stay centered.
    public mutating func setCanvas(width w: Int, height h: Int) {
        let w = min(max(8, w), Self.maxSide)
        let h = min(max(8, h), Self.maxSide)
        let dx = Double(w - width) / 2
        let dy = Double(h - height) / 2
        (width, height) = (w, h)
        for i in layers.indices { layers[i].frame = layers[i].frame.offset(by: dx, dy) }
    }

    /// Crop or grow the canvas to just hold the visible layers.
    public mutating func fitCanvasToLayers() {
        let visible = layers.filter(\.visible)
        guard let first = visible.first?.frame else { return }
        var minX = first.x
        var minY = first.y
        var maxX = first.maxX
        var maxY = first.maxY
        for f in visible.map(\.frame) {
            (minX, minY) = (min(minX, f.x), min(minY, f.y))
            (maxX, maxY) = (max(maxX, f.maxX), max(maxY, f.maxY))
        }
        let x0 = minX.rounded(.down)
        let y0 = minY.rounded(.down)
        width = min(max(8, Int((maxX - x0).rounded(.up))), Self.maxSide)
        height = min(max(8, Int((maxY - y0).rounded(.up))), Self.maxSide)
        for i in layers.indices { layers[i].frame = layers[i].frame.offset(by: -x0, -y0) }
    }

    /// The recipe the flattened picture is filed with: the bottom layer's
    /// that has one.
    public var recipe: GenerationRecipe? { layers.lazy.compactMap(\.recipe).first }

    /// The picture all layers make together, at canvas size. `images` are
    /// the layers' pictures by `CompositionLayer.image`.
    public func flatten(images: [UUID: CGImage]) -> CGImage? {
        guard let ctx = Self.context(width: width, height: height, originX: 0, originY: 0) else { return nil }
        switch background {
        case .transparent: break
        case .white: ctx.setFillColor(gray: 1, alpha: 1)
        case .black: ctx.setFillColor(gray: 0, alpha: 1)
        }
        if background != .transparent { ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        Self.draw(layers.filter(\.visible), images: images, in: ctx)
        guard let out = ctx.makeImage() else { return nil }
        return grayscale ? PixelBuffer(out)?.grayscaled().cgImage() : out
    }

    /// The layers `ids` drawn together as they look (stack order, opacity,
    /// gray), at canvas pixels, framed by all of them; for merging. `nil`
    /// when none of them has a picture.
    public func render(_ ids: Set<UUID>, images: [UUID: CGImage]) -> (frame: ImageFrame, image: CGImage)? {
        let chosen = layers.filter { ids.contains($0.id) && images[$0.image] != nil }
        guard let first = chosen.first?.frame else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.maxX
        var maxY = first.maxY
        // Shadows are part of how the layers look.
        let shadowFrames = chosen.compactMap { layer -> ImageFrame? in
            guard let s = layer.shadow, let image = images[layer.image], let r = s.render(image) else { return nil }
            return layer.canvasFrame(of: r.rect)
        }
        for f in chosen.map(\.frame) + shadowFrames {
            (minX, minY) = (min(minX, f.x), min(minY, f.y))
            (maxX, maxY) = (max(maxX, f.maxX), max(maxY, f.maxY))
        }
        let x0 = minX.rounded(.down)
        let y0 = minY.rounded(.down)
        let w = min(max(1, Int((maxX - x0).rounded(.up))), Self.maxSide)
        let h = min(max(1, Int((maxY - y0).rounded(.up))), Self.maxSide)
        guard let ctx = Self.context(width: w, height: h, originX: x0, originY: y0) else { return nil }
        Self.draw(chosen, images: images, in: ctx)
        return ctx.makeImage().map { (ImageFrame(x: x0, y: y0, width: Double(w), height: Double(h)), $0) }
    }

    /// Put `merged` where the lowest of `ids` was, and take `ids` out.
    public mutating func replace(_ ids: Set<UUID>, with merged: CompositionLayer) {
        let at = layers.firstIndex { ids.contains($0.id) } ?? layers.endIndex
        let below = layers[..<at].count
        layers.removeAll { ids.contains($0.id) }
        layers.insert(merged, at: min(below, layers.count))
    }

    /// A transparent context `width` × `height` whose top left is the canvas
    /// point (`originX`, `originY`), with canvas coordinates (y going down).
    private static func context(width: Int, height: Int, originX: Double, originY: Double) -> CGContext? {
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: ImageCoding.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // Canvas pixels have y going down; Core Graphics has y going up.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -originX, y: -originY)
        return ctx
    }

    private static func draw(_ list: [CompositionLayer], images: [UUID: CGImage], in ctx: CGContext) {
        for layer in list where layer.opacity > 0 {
            guard var image = images[layer.image] else { continue }
            // The shadow first, under the layer.
            if let shadow = layer.shadow, let (picture, rect) = shadow.render(image) {
                let s = layer.canvasFrame(of: rect)
                ctx.saveGState()
                ctx.setAlpha(layer.opacity)
                ctx.translateBy(x: s.x, y: s.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(picture, in: CGRect(x: 0, y: 0, width: s.width, height: s.height))
                ctx.restoreGState()
            }
            if layer.grayscale, let gray = PixelBuffer(image)?.grayscaled().cgImage() { image = gray }
            let f = layer.frame
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            // Draw the picture upright inside the flipped space.
            ctx.translateBy(x: f.x, y: f.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: f.width, height: f.height))
            ctx.restoreGState()
        }
    }

    /// The layer below `id` in the stack, if any.
    public func layer(below id: UUID) -> CompositionLayer? {
        guard let i = layers.firstIndex(where: { $0.id == id }), i > 0 else { return nil }
        return layers[i - 1]
    }
}

/// Reads and writes compositions in the gallery folder:
/// `compositions/<id>/composition.json` and `compositions/<id>/layers/<image>.png`.
public struct CompositionStore: Sendable {
    /// The gallery folder.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    var folder: URL { root.appending(path: "compositions") }
    func folder(_ id: UUID) -> URL { folder.appending(path: id.uuidString) }
    func fileURL(_ id: UUID) -> URL { folder(id).appending(path: "composition.json") }
    public func layerURL(_ id: UUID, image: UUID) -> URL {
        folder(id).appending(path: "layers/\(image.uuidString).png")
    }

    /// All compositions that can be read, last changed first.
    public func list() -> [Composition] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            UUID(uuidString: dir.lastPathComponent).flatMap { try? load($0) }
        }
        .sorted { $0.modified > $1.modified }
    }

    public func load(_ id: UUID) throws -> Composition {
        let c = try JSONDecoder.gallery.decode(Composition.self, from: Data(contentsOf: fileURL(id)))
        if c.version > Composition.currentVersion { throw GalleryError.newerFormat(c.version) }
        return c
    }

    public func layerImage(_ id: UUID, image: UUID) -> Data? {
        try? Data(contentsOf: layerURL(id, image: image))
    }

    /// Write the composition and the layer pictures it uses that aren't
    /// written yet (`images`, PNG by `CompositionLayer.image`), and delete
    /// the ones it no longer uses.
    public func save(_ c: Composition, images: [UUID: Data]) throws {
        let fm = FileManager.default
        let layers = folder(c.id).appending(path: "layers")
        try fm.createDirectory(at: layers, withIntermediateDirectories: true)
        let used = Set(c.layers.map(\.image))
        for image in used {
            let url = layerURL(c.id, image: image)
            guard !fm.fileExists(atPath: url.path(percentEncoded: false)), let data = images[image] else { continue }
            try data.write(to: url, options: .atomic)
        }
        try JSONEncoder.gallery.encode(c).write(to: fileURL(c.id), options: .atomic)
        for url in (try? fm.contentsOfDirectory(at: layers, includingPropertiesForKeys: nil)) ?? [] {
            guard let image = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !used.contains(image)
            else { continue }
            try? fm.removeItem(at: url)
        }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }
}

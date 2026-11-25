import ComfyKit
import CoreGraphics
import Foundation
import LightboxCore
import Observation

/// The compositions in the sidebar, and the one open in the editor.
@MainActor @Observable
public final class CompositionsModel {
    public private(set) var list: [Composition] = []
    /// Shown in the main area instead of the gallery.
    public private(set) var document: ComposeDocument?

    let store: CompositionStore
    private let gallery: GalleryModel

    init(store: CompositionStore, gallery: GalleryModel) {
        self.store = store
        self.gallery = gallery
        list = store.list()
    }

    public func composition(_ id: UUID?) -> Composition? { list.first { $0.id == id } }

    /// A new composition with `pictures` (gallery IDs) as layers, opened.
    public func create(with pictures: [UUID] = []) {
        var name = "Composition"
        var n = 2
        while list.contains(where: { $0.name == name }) {
            name = "Composition \(n)"
            n += 1
        }
        let doc = ComposeDocument(Composition(name: name), store: store, gallery: gallery, owner: self)
        document?.close()
        document = doc
        doc.add(pictures, undo: nil)
        doc.save()
    }

    /// Open gallery pictures in the editor: a picture saved from a
    /// composition opens that composition again; others start a new one
    /// (the oldest lowest).
    public func edit(_ ids: [UUID]) {
        if ids.count == 1, let id = gallery.item(ids[0])?.composition, composition(id) != nil {
            return open(id)
        }
        create(with: gallery.index.items.filter { ids.contains($0.id) }.map(\.id).reversed())
    }

    public func open(_ id: UUID) {
        guard document?.composition.id != id, let c = try? store.load(id) else { return }
        document?.close()
        document = ComposeDocument(c, store: store, gallery: gallery, owner: self)
    }

    /// Back to the gallery.
    public func close() {
        document?.close()
        document = nil
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let document, document.composition.id == id {
            document.change("Rename", undo: nil) { $0.name = trimmed }
        } else if var c = try? store.load(id) {
            c.name = trimmed
            try? store.save(c, images: [:])
            saved(c)
        }
    }

    /// The composition and its layers; a picture saved from it stays in the gallery.
    public func delete(_ id: UUID) {
        if document?.composition.id == id {
            document?.discard()
            document = nil
        }
        store.delete(id)
        list.removeAll { $0.id == id }
    }

    func saved(_ c: Composition) {
        list.removeAll { $0.id == c.id }
        list.insert(c, at: list.firstIndex { $0.modified < c.modified } ?? list.endIndex)
    }
}

/// A composition being edited: undo, the layers' pictures, the selected
/// layer, the tools. Saved on its own a moment after each change.
@MainActor @Observable
public final class ComposeDocument {
    public enum Tool: Hashable, Sendable { case move, magicWand, brush, eraser, area }

    public enum WandMode: Hashable, CaseIterable, Sendable {
        case replace, add, subtract

        var label: String {
            switch self {
            case .replace: "New"
            case .add: "Add"
            case .subtract: "Subtract"
            }
        }
    }

    public private(set) var composition: Composition
    /// The layers' pictures by `CompositionLayer.image`, including earlier
    /// versions undo can bring back.
    public private(set) var images: [UUID: CGImage] = [:]
    /// The layer the settings, handles and tools work on.
    public var selection: UUID? {
        didSet {
            if selection != oldValue, pixels.layer != selection { clearMask() }
            // Picked on the canvas: that layer alone.
            if !selectingFromList { selectedLayers = selection.map { [$0] } ?? [] }
        }
    }
    /// All layers selected in the list (⌘- or ⇧-click), for merging or
    /// deleting them together; `selection` is one of them.
    public private(set) var selectedLayers: Set<UUID> = []
    @ObservationIgnored private var selectingFromList = false
    public var tool: Tool = .move

    /// Screen points per canvas pixel; `nil` = fit the window.
    public var zoom: Double?
    /// Running: removing a background, a wand edit, saving to the gallery.
    public private(set) var busy = false
    public var problem: String?
    /// The sheet with gallery pictures, and the file importer, are open.
    public var pickingFromGallery = false
    public var importingFiles = false

    // The pixels selected on a layer, with the magic wand or the brush:
    // what Delete Selection removes and Edit with Model paints again.
    public var tolerance = 32.0
    public var contiguous = true
    public var antiAlias = true
    public var wandMode: WandMode = .replace
    /// Brush diameter in canvas pixels.
    public var brushSize = 60.0
    /// The brush takes away from the selection (⌥ on the Mac does too).
    public var brushErases = false
    /// Eraser diameter in canvas pixels.
    public var eraserSize = 60.0
    /// How much the eraser takes away, 0…1.
    public var eraserStrength = 1.0
    /// The share of the eraser's radius erased at full strength; the rest fades.
    public var eraserHardness = 0.5
    public private(set) var maskOverlay: CGImage?
    public var hasMask: Bool { pixels.mask.map { !$0.isEmpty } ?? false }

    /// A part of the whole picture to redraw, in canvas pixels (the area tool).
    public var area: ImageFrame?
    public var areaEllipse = false

    // Edit with Model and Redraw Area.
    public var editPrompt = ""
    public var editPresetID: UUID?
    /// How much the selected part may change (the sampler's denoise).
    public var editStrength = 0.75
    public private(set) var editing = false
    public private(set) var editStatus = ""

    /// The eraser stroke being dragged: the layer, its picture before, and
    /// what is erased so far. The canvas shows the stroke live through
    /// `images`; the end of the stroke writes a new picture (one undo step).
    private struct EraseStroke {
        var layer: UUID
        var image: UUID
        var original: CGImage
        var stroke: EraserStroke
        var generation = 0
    }
    @ObservationIgnored private var erasing: EraseStroke?
    @ObservationIgnored private var erasePreviewRunning = false

    private struct PixelSelection {
        var layer: UUID?
        var image: UUID?
        /// The mask before the last wand click, so a new tolerance redoes only that click.
        var base: SelectionMask?
        var lastClick: (x: Int, y: Int, mode: WandMode)?
        var mask: SelectionMask?
        /// The last brush point of the stroke, in picture pixels.
        var brushPoint: (x: Double, y: Double)?
        var generation = 0
    }
    @ObservationIgnored private var pixels = PixelSelection()
    @ObservationIgnored private var overlayRunning = false
    @ObservationIgnored private var overlayDirty = false
    @ObservationIgnored private var editTask: Task<Void, Never>?
    @ObservationIgnored private var pngs: [UUID: Data] = [:]
    @ObservationIgnored private var buffers: [UUID: PixelBuffer] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSave: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    /// Changed since the last save.
    public private(set) var unsaved = false

    private let store: CompositionStore
    private let gallery: GalleryModel
    private weak var owner: CompositionsModel?

    init(_ composition: Composition, store: CompositionStore, gallery: GalleryModel, owner: CompositionsModel) {
        self.composition = composition
        self.store = store
        self.gallery = gallery
        self.owner = owner
        let id = composition.id
        for image in Set(composition.layers.map(\.image)) {
            Task {
                let loaded = await Task.detached(priority: .userInitiated) { () -> (Data, CGImage)? in
                    guard let data = store.layerImage(id, image: image), let cg = ImageCoding.decode(data) else {
                        return nil
                    }
                    return (data, cg)
                }.value
                guard let loaded else {
                    self.problem = "A layer's picture is missing."
                    return
                }
                self.pngs[image] = loaded.0
                self.images[image] = loaded.1
                self.updateShadows()
            }
        }
    }

    public var selectedLayer: CompositionLayer? { composition.layer(selection) }

    // MARK: - Undo

    /// Make an undoable change.
    public func change(_ name: String, undo: UndoManager?, _ edit: (inout Composition) -> Void) {
        let before = composition
        edit(&composition)
        commit(since: before, name, undo: undo)
    }

    /// For continuous edits (sliders, drags): change without undo while
    /// dragging, then `commit` once.
    public func live(_ edit: (inout Composition) -> Void) {
        edit(&composition)
        updateShadows()
    }

    public func commit(since before: Composition, _ name: String, undo: UndoManager?) {
        guard composition != before else { return }
        register(restoring: before, name, undo)
        changed()
    }

    private func register(restoring old: Composition, _ name: String, _ undo: UndoManager?) {
        undo?.registerUndo(withTarget: self) { doc in
            let current = doc.composition
            doc.composition = old
            if doc.composition.layer(doc.selection) == nil { doc.selection = nil }
            doc.register(restoring: current, name, undo)
            doc.changed()
        }
        undo?.setActionName(name)
    }

    private func changed() {
        updateShadows()
        composition.modified = Date()
        if let layer = selectedLayer, layer.image != pixels.image { clearMask() }
        unsaved = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    // MARK: - Saving

    /// Write the composition now (it is also saved shortly after each change).
    public func save() {
        guard !closed else { return }
        saveTask?.cancel()
        unsaved = false
        let c = composition
        let pngs = pngs.filter { image, _ in c.layers.contains { $0.image == image } }
        let store = store
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            let error = await Task.detached(priority: .utility) { () -> Error? in
                do {
                    try store.save(c, images: pngs)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                self.unsaved = true
                self.problem = "Could not save the composition: \(AppModel.describe(error))"
            }
        }
        owner?.saved(c)
    }

    /// Write the composition before the app quits; there is no time to
    /// wait for the background save.
    func saveBeforeQuitting() {
        guard !closed, unsaved else { return }
        saveTask?.cancel()
        let c = composition
        try? store.save(c, images: pngs.filter { image, _ in c.layers.contains { $0.image == image } })
        unsaved = false
    }

    /// Save and stop.
    func close() {
        save()
        closed = true
    }

    /// Stop without saving (the composition is being deleted).
    func discard() {
        saveTask?.cancel()
        closed = true
    }

    // MARK: - Layers

    /// Add gallery pictures as layers on top.
    public func add(_ ids: [UUID], undo: UndoManager?) {
        let before = composition
        var added: UUID?
        for id in ids {
            guard let item = gallery.item(id), let png = gallery.pngData(id), let cg = ImageCoding.decode(png) else {
                continue
            }
            let image = UUID()
            pngs[image] = png
            images[image] = cg
            let prompt = item.recipe.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = prompt.isEmpty ? "Picture" : String(prompt.prefix(40))
            added = composition.addLayer(
                name: name, image: image, width: cg.width, height: cg.height, source: id, recipe: item.recipe)
        }
        commit(since: before, ids.count == 1 ? "Add Picture" : "Add Pictures", undo: undo)
        if let added { selection = added }
    }

    /// A transparent layer the size of the canvas, above the selected one:
    /// for selecting a part with the brush and painting it with the model.
    public func addEmptyLayer(undo: UndoManager?) {
        let c = composition
        guard let png = ImageCoding.emptyPNG(width: c.width, height: c.height), let cg = ImageCoding.decode(png)
        else { return }
        let image = UUID()
        pngs[image] = png
        images[image] = cg
        var id: UUID?
        change("New Layer", undo: undo) {
            id = $0.addEmptyLayer(name: $0.nextLayerName, image: image, above: selection)
        }
        selection = id
    }

    /// Pictures from files as layers on top, turned upright; the first one
    /// into an empty composition sets the canvas size.
    public func importImages(_ files: [(name: String, data: Data)], undo: UndoManager?) async {
        guard !files.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        let decoded = await Task.detached(priority: .userInitiated) { () -> [(String, Data, CGImage)] in
            files.compactMap { file in
                guard let cg = ImageCoding.decodeUpright(file.data), let png = ImageCoding.encodePNG(cg) else {
                    return nil
                }
                let stem = (file.name as NSString).deletingPathExtension
                return (stem.isEmpty ? "Picture" : stem, png, cg)
            }
        }.value
        if decoded.count < files.count {
            let unread = files.count - decoded.count
            problem =
                unread == 1
                ? "A file isn't a picture this device can read."
                : "\(unread) files aren't pictures this device can read."
        }
        guard !decoded.isEmpty else { return }
        let before = composition
        var added: UUID?
        for (name, png, cg) in decoded {
            let image = UUID()
            pngs[image] = png
            images[image] = cg
            added = composition.addLayer(name: name, image: image, width: cg.width, height: cg.height)
        }
        commit(since: before, decoded.count == 1 ? "Import Picture" : "Import Pictures", undo: undo)
        if let added { selection = added }
    }

    // MARK: - Selecting and merging layers

    /// Select layers from the list; the one the settings show stays if it
    /// is among them.
    public func selectLayers(_ ids: Set<UUID>) {
        let ids = ids.filter { composition.layer($0) != nil }
        selectingFromList = true
        selectedLayers = ids
        if selection.map(ids.contains) != true {
            selection = composition.layers.last { ids.contains($0.id) }?.id
        }
        selectingFromList = false
        // The arrow keys then move the layers instead of walking the list.
        if !ids.isEmpty { canvasFocusRequests += 1 }
    }

    /// Counts requests for the canvas to take the keyboard focus.
    public private(set) var canvasFocusRequests = 0

    /// Move the selected layers by canvas pixels (the arrow keys).
    public func nudgeSelected(by dx: Double, _ dy: Double, undo: UndoManager?) {
        let ids = selectedLayers.isEmpty ? Set(selection.map { [$0] } ?? []) : selectedLayers
        guard !ids.isEmpty else { return }
        change(ids.count == 1 ? "Move Layer" : "Move Layers", undo: undo) { c in
            for id in ids { c.update(id) { $0.frame = $0.frame.offset(by: dx, dy) } }
        }
    }

    /// The selected layers that are shown; hidden ones stay out of a merge.
    public var mergeable: Set<UUID> {
        Set(composition.layers.filter { selectedLayers.contains($0.id) && $0.visible }.map(\.id))
    }

    public var canMergeSelected: Bool { mergeable.count >= 2 }

    /// The selected (shown) layers become one, as they look now.
    public func mergeSelected(undo: UndoManager?) async {
        let ids = mergeable
        guard ids.count >= 2 else { return }
        await merge(ids, name: "Merge Layers", undo: undo)
    }

    public func removeSelectedLayers(undo: UndoManager?) {
        let ids = selectedLayers
        guard !ids.isEmpty else { return }
        change(ids.count == 1 ? "Delete Layer" : "Delete Layers", undo: undo) { c in
            for id in ids { c.remove(id) }
        }
        selection = nil
    }

    /// Draw `ids` together into one layer at canvas pixels, with their
    /// opacity and gray baked in, in the lowest one's place and name.
    private func merge(_ ids: Set<UUID>, name: String, undo: UndoManager?) async {
        guard !busy, !editing else { return }
        busy = true
        defer { busy = false }
        let c = composition
        let images = images
        let made = await Task.detached(priority: .userInitiated) { () -> (ImageFrame, Data, CGImage)? in
            guard let (frame, cg) = c.render(ids, images: images), let png = ImageCoding.encodePNG(cg) else {
                return nil
            }
            return (frame, png, cg)
        }.value
        guard let (frame, png, cg) = made else { return problem = "Could not merge the layers." }
        // The layers may have changed meanwhile; then it is left out.
        guard composition == c else { return }
        let parts = c.layers.filter { ids.contains($0.id) }
        guard let lowest = parts.first else { return }
        let image = UUID()
        pngs[image] = png
        self.images[image] = cg
        var merged = CompositionLayer(
            name: lowest.name, image: image, pixelWidth: cg.width, pixelHeight: cg.height, frame: frame,
            source: lowest.source, recipe: parts.lazy.compactMap(\.recipe).first)
        let edits = parts.flatMap { $0.edits ?? [] }
        merged.edits = edits.isEmpty ? nil : edits
        clearMask()
        change(name, undo: undo) { $0.replace(ids, with: merged) }
        selection = merged.id
    }

    public func removeLayer(_ id: UUID, undo: UndoManager?) {
        change("Delete Layer", undo: undo) { $0.remove(id) }
        if selection == id { selection = nil }
    }

    /// Fit or fill the canvas with the layer, keeping its proportions.
    public func place(_ id: UUID, fill: Bool, undo: UndoManager?) {
        change(fill ? "Fill Canvas" : "Fit to Canvas", undo: undo) { c in
            let bounds = c.bounds
            c.update(id) {
                $0.frame = .fitting(width: $0.pixelWidth, height: $0.pixelHeight, in: bounds, fill: fill)
            }
        }
    }

    /// Whether any of the layer is on the canvas.
    public func isOnCanvas(_ id: UUID) -> Bool {
        guard let f = composition.layer(id)?.frame else { return true }
        return f.maxX > 0 && f.maxY > 0 && f.x < Double(composition.width) && f.y < Double(composition.height)
    }

    /// Put the layer in the middle of the canvas, at its size.
    public func centerOnCanvas(_ id: UUID, undo: UndoManager?) {
        let c = composition
        change("Center on Canvas", undo: undo) { comp in
            comp.update(id) {
                $0.frame.x = (Double(c.width) - $0.frame.width) / 2
                $0.frame.y = (Double(c.height) - $0.frame.height) / 2
            }
        }
    }

    /// The layer at its own pixel size, centered where it is.
    public func actualSize(_ id: UUID, undo: UndoManager?) {
        change("Actual Size", undo: undo) { $0.setScale(id, to: 1) }
    }

    /// The layer's picture without its background, made on the device.
    public func removeBackground(of id: UUID, undo: UndoManager?) async {
        guard let layer = composition.layer(id), let png = pngs[layer.image], !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let cut = try await BackgroundRemoval.cutOut(png, edge: BackgroundRemoval.lastEdge)
            guard let cg = ImageCoding.decode(cut) else { throw BackgroundRemoval.Failure.notAnImage }
            replaceImage(of: id, png: cut, image: cg, name: "Remove Background", undo: undo)
        } catch {
            problem = "Can't remove the background: \(AppModel.describe(error))"
        }
    }

    /// A new picture for a layer. The old one stays in memory for undo.
    private func replaceImage(
        of id: UUID, png: Data, image: CGImage, name: String, undo: UndoManager?,
        also: (inout CompositionLayer) -> Void = { _ in }
    ) {
        let new = UUID()
        pngs[new] = png
        images[new] = image
        change(name, undo: undo) {
            $0.update(id) {
                $0.image = new
                also(&$0)
            }
        }
    }

    // MARK: - Saving to the gallery

    /// Flatten into a new gallery picture; each save adds one.
    /// `rating` files a composition of imported pictures only, which has no recipe of its own.
    public func saveToGallery(rating: ContentRating) async {
        guard !busy else { return }
        let recipe = composition.recipe ?? .composed(rating: rating)
        busy = true
        defer { busy = false }
        let c = composition
        let images = images
        let png = await Task.detached(priority: .userInitiated) {
            c.flatten(images: images).flatMap(ImageCoding.encodePNG)
        }.value
        guard let png else {
            problem = "Could not make the picture."
            return
        }
        guard let id = gallery.saveComposition(png, recipe: recipe, composition: c.id) else {
            return
        }
        if composition.output != id {
            composition.output = id
            changed()
        }
    }

    // MARK: - Selecting pixels

    /// Start or keep the pixel selection on the selected layer (or the one
    /// at the canvas point); `nil` when there is no layer.
    private func selectionLayer(atX x: Double, y: Double) -> CompositionLayer? {
        if selectedLayer.map({ !$0.frame.contains(x: x, y: y) }) ?? true, let hit = composition.hitTest(x: x, y: y) {
            selection = hit
        }
        guard let layer = selectedLayer else { return nil }
        if pixels.layer != layer.id || pixels.image != layer.image {
            pixels = PixelSelection(layer: layer.id, image: layer.image, generation: pixels.generation + 1)
            maskOverlay = nil
        }
        return layer
    }

    /// Select by color where a layer was clicked (canvas coordinates).
    public func wandClick(atX x: Double, y: Double, mode: WandMode? = nil) {
        guard let layer = selectionLayer(atX: x, y: y) else { return }
        let p = layer.pixel(atX: x, y: y)
        let mode = mode ?? wandMode
        pixels.base = mode == .replace ? nil : pixels.mask
        pixels.lastClick = (p.x, p.y, mode)
        reselect()
    }

    /// Redo the last wand click after the tolerance or contiguous setting changed.
    public func reselect() {
        guard let layer = selectedLayer, layer.id == pixels.layer, layer.image == pixels.image,
            let click = pixels.lastClick, let cg = images[layer.image]
        else { return }
        pixels.generation += 1
        let generation = pixels.generation
        let base = pixels.base
        let tolerance = Int(tolerance)
        let contiguous = contiguous
        let cached = buffers[layer.image]
        let image = layer.image
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (PixelBuffer, SelectionMask)? in
                guard let buffer = cached ?? PixelBuffer(cg) else { return nil }
                let m = MagicWand.select(buffer, x: click.x, y: click.y, tolerance: tolerance, contiguous: contiguous)
                var mask = base ?? SelectionMask(width: buffer.width, height: buffer.height)
                switch click.mode {
                case .replace: mask = m
                case .add: mask.formUnion(m)
                case .subtract: mask.subtract(m)
                }
                return (buffer, mask)
            }.value
            guard let result, generation == self.pixels.generation else { return }
            self.buffers[image] = result.0
            self.pixels.mask = result.1
            self.updateOverlay()
        }
    }

    /// Paint the selection with the brush (canvas coordinates); `erase`
    /// takes it away. Call `endStroke` when the drag ends.
    public func brush(atX x: Double, y: Double, erase: Bool) {
        let fresh = pixels.brushPoint == nil
        guard let layer = fresh ? selectionLayer(atX: x, y: y) : selectedLayer, layer.id == pixels.layer else {
            return
        }
        let w = layer.pixelWidth
        let h = layer.pixelHeight
        var mask = pixels.mask ?? SelectionMask(width: w, height: h)
        guard mask.width == w, mask.height == h else { return }
        let px = (x - layer.frame.x) / layer.frame.width * Double(w)
        let py = (y - layer.frame.y) / layer.frame.height * Double(h)
        let radius = max(1, brushSize / 2 / layer.scale)
        let from = pixels.brushPoint ?? (px, py)
        // Dabs along the way, so a quick drag leaves no gaps.
        let distance = hypot(px - from.x, py - from.y)
        let dabs = max(1, Int(distance / max(1, radius / 3)))
        let value: UInt8 = erase ? 0 : 1
        for i in 1...dabs {
            let t = Double(i) / Double(dabs)
            let cx = from.x + (px - from.x) * t
            let cy = from.y + (py - from.y) * t
            let r2 = radius * radius
            let x0 = max(0, Int((cx - radius).rounded(.down)))
            let x1 = min(w - 1, Int((cx + radius).rounded(.up)))
            let y0 = max(0, Int((cy - radius).rounded(.down)))
            let y1 = min(h - 1, Int((cy + radius).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for yy in y0...y1 {
                let dy = Double(yy) + 0.5 - cy
                for xx in x0...x1 {
                    let dx = Double(xx) + 0.5 - cx
                    if dx * dx + dy * dy <= r2 { mask.values[yy * w + xx] = value }
                }
            }
        }
        pixels.mask = mask
        pixels.brushPoint = (px, py)
        pixels.generation += 1
        updateOverlay()
    }

    public func endStroke() {
        pixels.brushPoint = nil
        pixels.base = pixels.mask
        pixels.lastClick = nil
    }

    // MARK: - Eraser

    /// Rub out the selected layer's pixels (or the one at the point) along
    /// the drag, in canvas coordinates. Call `endErase` when the drag ends.
    public func erase(atX x: Double, y: Double) {
        if erasing == nil {
            if selectedLayer.map({ !$0.visible || !$0.frame.contains(x: x, y: y) }) ?? true,
                let hit = composition.hitTest(x: x, y: y)
            {
                selection = hit
            }
            guard let layer = selectedLayer, layer.visible, let cg = images[layer.image],
                let buffer = buffers[layer.image] ?? PixelBuffer(cg)
            else { return }
            buffers[layer.image] = buffer
            erasing = EraseStroke(layer: layer.id, image: layer.image, original: cg, stroke: EraserStroke(base: buffer))
        }
        guard var e = erasing, let layer = composition.layer(e.layer), layer.image == e.image else { return }
        let px = (x - layer.frame.x) / layer.frame.width * Double(layer.pixelWidth)
        let py = (y - layer.frame.y) / layer.frame.height * Double(layer.pixelHeight)
        e.stroke.move(
            toX: px, y: py, radius: max(0.5, eraserSize / 2 / layer.scale), strength: eraserStrength,
            hardness: eraserHardness)
        e.generation += 1
        erasing = e
        showErasePreview()
    }

    /// Draw the stroke so far off the main thread, one at a time.
    private func showErasePreview() {
        guard !erasePreviewRunning, let e = erasing else { return }
        erasePreviewRunning = true
        let stroke = e.stroke
        let generation = e.generation
        Task {
            let image = await Task.detached(priority: .userInitiated) { stroke.result().cgImage() }.value
            self.erasePreviewRunning = false
            guard let current = self.erasing else { return }
            if let image { self.images[current.image] = image }
            if current.generation != generation { self.showErasePreview() }
        }
    }

    public func endErase(undo: UndoManager?) {
        guard let e = erasing else { return }
        erasing = nil
        guard !e.stroke.isEmpty else {
            images[e.image] = e.original
            return
        }
        let stroke = e.stroke
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (PixelBuffer, Data, CGImage)? in
                let out = stroke.result()
                guard let cg = out.cgImage(), let png = ImageCoding.encodePNG(cg) else { return nil }
                return (out, png, cg)
            }.value
            // The old picture stays as it was, for undo.
            self.images[e.image] = e.original
            guard let result, let layer = self.composition.layer(e.layer), layer.image == e.image else { return }
            self.replaceImage(of: e.layer, png: result.1, image: result.2, name: "Erase", undo: undo)
            if let new = self.composition.layer(e.layer)?.image { self.buffers[new] = result.0 }
        }
    }

    public func invertMask() {
        guard let mask = pixels.mask else { return }
        pixels.mask = mask.inverted()
        pixels.base = pixels.mask
        pixels.lastClick = nil
        pixels.generation += 1
        updateOverlay()
    }

    public func clearMask() {
        pixels = PixelSelection(generation: pixels.generation + 1)
        maskOverlay = nil
    }

    /// Draw the selection off the main thread; while one is drawn, later
    /// changes wait for it, so painting stays quick.
    private func updateOverlay() {
        guard !overlayRunning else {
            overlayDirty = true
            return
        }
        guard let mask = pixels.mask else {
            maskOverlay = nil
            return
        }
        overlayRunning = true
        let generation = pixels.generation
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                mask.overlay(red: 0.1, green: 0.5, blue: 1).cgImage()
            }.value
            self.overlayRunning = false
            self.maskOverlay = self.pixels.mask == nil ? nil : image
            if self.overlayDirty, generation != self.pixels.generation {
                self.overlayDirty = false
                self.updateOverlay()
            }
        }
    }

    /// Make the selected pixels transparent. The gallery picture isn't changed.
    public func deleteMasked(undo: UndoManager?) async {
        guard let id = pixels.layer, let layer = composition.layer(id), layer.image == pixels.image,
            let mask = pixels.mask, !mask.isEmpty, !busy, let cg = images[layer.image]
        else { return }
        busy = true
        defer { busy = false }
        let antiAlias = antiAlias
        let cached = buffers[layer.image]
        let result = await Task.detached(priority: .userInitiated) { () -> (PixelBuffer, Data, CGImage)? in
            guard let buffer = cached ?? PixelBuffer(cg) else { return nil }
            let out = MagicWand.erase(buffer, mask, antiAlias: antiAlias)
            guard let cg = out.cgImage(), let png = ImageCoding.encodePNG(cg) else { return nil }
            return (out, png, cg)
        }.value
        guard let result else { return }
        clearMask()
        replaceImage(of: id, png: result.1, image: result.2, name: "Delete Selection", undo: undo)
        if let new = composition.layer(id)?.image { buffers[new] = result.0 }
    }

    // MARK: - Edit with Model

    /// The preset used: the one picked, else the layer's own if it is still
    /// there, else the Generate panel's.
    public func editPreset(_ app: AppModel) -> GenerationPreset? {
        let presets = app.library.presets
        if let p = presets.first(where: { $0.id == editPresetID }) { return p }
        if let id = selectedLayer?.recipe?.preset.id, let p = presets.first(where: { $0.id == id }) { return p }
        return app.generation.preset(in: app.library)
    }

    /// What every edit with the model needs: checked, with the prompt
    /// composed (and guarded) like every other one.
    private struct EditSetup {
        var client: ComfyClient
        var catalog: ComfyCatalog
        var preset: GenerationPreset
        var prompt: ComposedPrompt
        var recipe: GenerationRecipe
        var seed: Int
        var strength: Double
    }

    private func editSetup(_ app: AppModel, preset chosen: GenerationPreset? = nil, text: String? = nil) -> EditSetup? {
        guard !editing, !busy else { return nil }
        guard let client = app.client else {
            problem = "Not connected to ComfyUI. Check the Settings."
            return nil
        }
        guard app.catalog.canInpaint else {
            problem =
                "The ComfyUI server can't paint parts of a picture: it lacks LoadImageMask, VAEEncode or "
                + "SetLatentNoiseMask."
            return nil
        }
        guard let preset = chosen ?? editPreset(app) else {
            problem = "Create a preset first."
            return nil
        }
        if let trouble = preset.problem(with: app.catalog) {
            problem = trouble
            return nil
        }
        let input = PromptInput(preset: preset, prompt: text ?? editPrompt, rating: app.library.rating)
        let prompt: ComposedPrompt
        do {
            prompt = try compose(input)
        } catch {
            problem = error.description
            return nil
        }
        let seed = Int.random(in: 0...Int(UInt32.max))
        let recipe = GenerationRecipe(
            input: input, sent: prompt, seed: seed, finish: FinishSettings(), server: app.serverAddress)
        return EditSetup(
            client: client, catalog: app.catalog, preset: preset, prompt: prompt, recipe: recipe, seed: seed,
            strength: editStrength)
    }

    /// Send the region of `buffer` under `mask` to ComfyUI and wait for the
    /// painted region; `nil` when it failed (`problem` says why) or was cancelled.
    private func paint(_ setup: EditSetup, _ buffer: PixelBuffer, mask: SelectionMask, region: InpaintRegion) async
        -> CGImage?
    {
        let sent = await Task.detached(priority: .userInitiated) {
            Inpaint.prepare(buffer, mask: mask, region: region)
        }.value
        guard let sent else {
            problem = "Could not read the picture."
            return nil
        }
        let request = setup.preset.request(
            setup.prompt, seed: setup.seed, width: region.workWidth, height: region.workHeight,
            inpaint: InpaintSource(
                image: sent.image, mask: sent.mask, denoise: setup.strength,
                filename: "edit-\(UUID().uuidString.prefix(8))"))
        return await send(setup, request)
    }

    /// Run `request` on the server, showing its progress; the picture it
    /// made, or `nil` when it failed (`problem` says why) or was cancelled.
    private func send(_ setup: EditSetup, _ request: GenerationRequest) async -> CGImage? {
        var result: Data?
        do {
            for try await event in setup.client.generate(request, catalog: setup.catalog) {
                switch event {
                case .uploading: editStatus = "Uploading…"
                case .queued: editStatus = "Waiting in the ComfyUI queue…"
                case .started, .stage: editStatus = "Starting…"
                case .progress(let value, let total): editStatus = "Painting · step \(value) of \(total)"
                case .preview: break
                case .finished(let images): result = images.first?.data
                case .cancelled: return nil
                }
            }
        } catch {
            if !Task.isCancelled { problem = "ComfyUI: \(AppModel.describe(error))" }
            return nil
        }
        guard let result, let painted = ImageCoding.decode(result) else {
            problem = "ComfyUI sent no picture back."
            return nil
        }
        return painted
    }

    /// Run an edit with the busy state and Cancel.
    private func runEdit(_ work: @escaping @MainActor () async -> Void) {
        editing = true
        editStatus = "Preparing…"
        editTask = Task {
            await work()
            editing = false
            editStatus = ""
            editTask = nil
        }
    }

    /// Paint the selected pixels of a layer again with the model, following
    /// `editPrompt`. Only that part and some room around it is sent; the
    /// result replaces the layer's picture as one undo step, and the
    /// selection stays for another try.
    public func editWithModel(_ app: AppModel, undo: UndoManager?) {
        guard let id = pixels.layer, let layer = composition.layer(id), layer.image == pixels.image,
            let mask = pixels.mask, !mask.isEmpty, let cg = images[layer.image]
        else { return problem = "Select the part to paint again first, with the magic wand or the brush." }
        guard let setup = editSetup(app),
            let region = InpaintRegion.plan(mask: mask, family: setup.preset.family)
        else { return }
        let cached = buffers[layer.image]
        runEdit { [self] in
            guard
                let buffer = await Task.detached(priority: .userInitiated, operation: { cached ?? PixelBuffer(cg) })
                    .value
            else { return problem = "Could not read the layer's picture." }
            buffers[layer.image] = buffer
            guard let painted = await paint(setup, buffer, mask: mask, region: region) else { return }
            guard composition.layer(id)?.image == layer.image else {
                return problem = "The layer changed while it was being painted, so the result was left out."
            }
            editStatus = "Putting it in…"
            let merged = await Task.detached(priority: .userInitiated) { () -> (PixelBuffer, Data, CGImage)? in
                guard let out = Inpaint.merge(painted, into: buffer, mask: mask, region: region),
                    let cg = out.cgImage(), let png = ImageCoding.encodePNG(cg)
                else { return nil }
                return (out, png, cg)
            }.value
            guard let merged else { return problem = "Could not put the result into the layer." }
            let recipe = setup.recipe
            replaceImage(of: id, png: merged.1, image: merged.2, name: "Edit with Model", undo: undo) {
                $0.edits = ($0.edits ?? []) + [recipe]
            }
            // Keep the selection on the new picture, for another try.
            guard let new = composition.layer(id)?.image else { return }
            buffers[new] = merged.0
            let overlay = maskOverlay
            pixels = PixelSelection(layer: id, image: new, base: mask, mask: mask, generation: pixels.generation + 1)
            maskOverlay = overlay
        }
    }

    /// Redraw `area` of the whole picture (all visible layers together) with
    /// the model. The result goes on a new layer on top, the size of the
    /// part sent and with a soft edge, so the layers below stay as they are.
    /// The area stays for another try.
    public func redrawArea(_ app: AppModel, undo: UndoManager?) {
        let c = composition
        guard let area, c.layers.contains(where: \.visible) else {
            return problem = "Drag an area on the canvas first, with the area tool."
        }
        let mask = SelectionMask.area(width: c.width, height: c.height, frame: area, ellipse: areaEllipse)
        guard !mask.isEmpty else { return problem = "The area is outside the canvas." }
        guard let setup = editSetup(app),
            let region = InpaintRegion.plan(mask: mask, family: setup.preset.family)
        else { return }
        let images = images
        runEdit { [self] in
            editStatus = "Putting the layers together…"
            let picture = await Task.detached(priority: .userInitiated) {
                c.flatten(images: images).flatMap(PixelBuffer.init)
            }.value
            guard let picture else { return problem = "Could not put the layers together." }
            guard let painted = await paint(setup, picture, mask: mask, region: region) else { return }
            let made = await Task.detached(priority: .userInitiated) { () -> (Data, CGImage)? in
                guard let patch = Inpaint.patch(painted, mask: mask, region: region), let cg = patch.cgImage(),
                    let png = ImageCoding.encodePNG(cg)
                else { return nil }
                return (png, cg)
            }.value
            guard let made else { return problem = "Could not make the new layer." }
            let image = UUID()
            pngs[image] = made.0
            self.images[image] = made.1
            let words = editPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let layer = CompositionLayer(
                name: words.isEmpty ? "Redrawn" : "Redrawn: \(words.prefix(30))", image: image,
                pixelWidth: region.width, pixelHeight: region.height,
                frame: ImageFrame(
                    x: Double(region.x), y: Double(region.y), width: Double(region.width),
                    height: Double(region.height)),
                recipe: setup.recipe)
            change("Redraw Area", undo: undo) { $0.insertOnTop(layer) }
            selection = layer.id
        }
    }

    // MARK: - Shadows

    /// Each layer's shadow as the canvas shows it: the picture and where it
    /// lies in the layer's pixels. Made with `LayerShadow.render`, as the
    /// saved picture's.
    public private(set) var shadowImages: [UUID: (image: CGImage, rect: CGRect)] = [:]
    /// What each was made from (picture and settings), to make it only again when they change.
    @ObservationIgnored private var shadowKeys: [UUID: String] = [:]
    @ObservationIgnored private var shadowTasks: [UUID: Task<Void, Never>] = [:]

    private func updateShadows() {
        let ids = Set(composition.layers.map(\.id))
        for id in Array(shadowImages.keys) + Array(shadowKeys.keys) where !ids.contains(id) {
            shadowImages[id] = nil
            shadowKeys[id] = nil
        }
        for layer in composition.layers {
            let id = layer.id
            guard let shadow = layer.shadow, let cg = images[layer.image] else {
                if shadowKeys[id] != nil || shadowImages[id] != nil {
                    shadowTasks[id]?.cancel()
                    shadowKeys[id] = nil
                    shadowImages[id] = nil
                }
                continue
            }
            let key =
                "\(layer.image)/\(shadow.style)/\(shadow.angle)/\(shadow.distance)/\(shadow.blur)/\(shadow.opacity)"
            guard shadowKeys[id] != key else { continue }
            shadowKeys[id] = key
            shadowTasks[id]?.cancel()
            shadowTasks[id] = Task {
                let made = await Task.detached(priority: .userInitiated) { shadow.render(cg) }.value
                guard !Task.isCancelled, self.shadowKeys[id] == key else { return }
                self.shadowImages[id] = made.map { ($0.image, $0.rect) }
            }
        }
    }

    // MARK: - Edit with Instruction

    /// What to change in the whole picture ("add a shadow of the woman on the floor").
    public var instruction = ""
    /// Keep the change inside the dragged area (when there is one).
    public var instructionInArea = true

    /// The Flux 2 preset the instruction edit uses: the one picked for
    /// editing if it is Flux 2, else the first Flux 2 preset.
    public func instructionPreset(_ app: AppModel) -> GenerationPreset? {
        if let p = editPreset(app), p.family == .flux2 { return p }
        return app.library.presets.first { $0.family == .flux2 && $0.problem(with: app.catalog) == nil }
            ?? app.library.presets.first { $0.family == .flux2 }
    }

    /// Change the whole picture (all visible layers) as `instruction` says,
    /// with an edit model: it sees the picture and returns it changed, so a
    /// shadow or light fits the scene. The result goes on a new layer on
    /// top: all of it, or only the area if one is dragged and
    /// `instructionInArea` is on.
    public func editWithInstruction(_ app: AppModel, undo: UndoManager?) {
        let c = composition
        guard c.layers.contains(where: \.visible) else { return problem = "Add a layer first." }
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return problem = "Write what should change first."
        }
        guard app.catalog.canEditWithReference else {
            return problem = "The ComfyUI server can't edit pictures by instruction: it lacks ReferenceLatent."
        }
        guard let preset = instructionPreset(app) else {
            return problem = "Editing by instruction needs a Flux 2 (Klein) preset."
        }
        guard let setup = editSetup(app, preset: preset, text: instruction) else { return }
        let mask =
            instructionInArea
            ? area.map { SelectionMask.area(width: c.width, height: c.height, frame: $0, ellipse: areaEllipse) } : nil
        let size = ImageEdit.workSize(width: c.width, height: c.height)
        let images = images
        let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        runEdit { [self] in
            editStatus = "Putting the layers together…"
            let png = await Task.detached(priority: .userInitiated) { () -> Data? in
                c.flatten(images: images).flatMap(ImageEdit.prepare)
            }.value
            guard let png else { return problem = "Could not put the layers together." }
            var request = setup.preset.request(setup.prompt, seed: setup.seed, width: size.width, height: size.height)
            request.references = [ReferenceImage(image: png, filename: "edit-\(UUID().uuidString.prefix(8))")]
            guard let edited = await send(setup, request) else { return }
            editStatus = "Putting it in…"
            let made = await Task.detached(priority: .userInitiated) { () -> (Data, CGImage, ImageFrame)? in
                guard
                    let (picture, frame) = ImageEdit.layer(from: edited, width: c.width, height: c.height, mask: mask),
                    let cg = picture.cgImage(), let png = ImageCoding.encodePNG(cg)
                else { return nil }
                return (png, cg, frame)
            }.value
            guard let (png2, cg, frame) = made else { return problem = "Could not make the new layer." }
            let image = UUID()
            pngs[image] = png2
            self.images[image] = cg
            let layer = CompositionLayer(
                name: "Edited: \(words.prefix(30))", image: image, pixelWidth: cg.width, pixelHeight: cg.height,
                frame: frame, recipe: setup.recipe)
            change("Edit with Instruction", undo: undo) { $0.insertOnTop(layer) }
            selection = layer.id
        }
    }

    public func cancelEdit() {
        editTask?.cancel()
    }
}

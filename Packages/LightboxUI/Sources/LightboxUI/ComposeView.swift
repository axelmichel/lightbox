import LightboxCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The composition editor in the main area: the canvas, and the layers
/// with their settings on the right.
struct ComposeView: View {
    @Bindable var doc: ComposeDocument
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PanelKeys.layers) private var layersShown = true
    @AppStorage(PanelKeys.generate) private var showGenerate = true

    var body: some View {
        HStack(spacing: 0) {
            ComposeCanvas(doc: doc)
                .overlay(alignment: .top) {
                    if doc.tool != .move { SelectionBar(doc: doc).padding(10) }
                }
                .overlay(alignment: .bottomLeading) {
                    Button(doc.unsaved ? "Save" : "Saved", systemImage: "square.and.arrow.down") { doc.save() }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        .keyboardShortcut("s")
                        .help(doc.unsaved ? "Save the composition (⌘S)" : "All changes are saved")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
                // Closed, the layer panel's button (and the Generate panel's,
                // if that is closed too) sit top right, where they were.
                .overlay(alignment: .topTrailing) {
                    if !layersShown {
                        HStack(spacing: 12) {
                            PanelButton(title: "Show the layers", systemImage: "square.3.layers.3d") {
                                layersShown = true
                            }
                            if !showGenerate {
                                PanelButton(title: "Show the Generate panel", systemImage: "sidebar.trailing") {
                                    showGenerate = true
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: PanelHeader.height - 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 4)
                        .padding(.trailing, 8)
                        .transition(.opacity)
                    }
                }
            if layersShown {
                Divider()
                ComposeSidePanel(doc: doc) { layersShown = false }
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(doc.composition.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Gallery", systemImage: "chevron.backward") { app.compositions.close() }
                    .help("Back to the gallery; the composition is kept")
            }
        }
        #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                doc.saveBeforeQuitting()
            }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, doc.unsaved { doc.save() }
        }
        .sheet(isPresented: $doc.pickingFromGallery) {
            PicturePicker { doc.add($0, undo: undo) }
        }
        .fileImporter(isPresented: $doc.importingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls):
                let files = urls.compactMap { url in
                    (try? readPickedFile(url)).map { (name: url.lastPathComponent, data: $0) }
                }
                Task { await doc.importImages(files, undo: undo) }
            case .failure(let error):
                doc.problem = "Could not open the files: \(error.localizedDescription)"
            }
        }
        .alert(
            "Composition", isPresented: Binding(get: { doc.problem != nil }, set: { if !$0 { doc.problem = nil } })
        ) {
            Button("OK") { doc.problem = nil }
        } message: {
            Text(doc.problem ?? "")
        }
        // Redraw Area is in the layer panel; dragging an area opens it.
        .onChange(of: doc.area != nil) { _, has in
            if has, !layersShown { withAnimation { layersShown = true } }
        }
        .onDisappear { undo?.removeAllActions(withTarget: doc) }
    }
}

/// The canvas with its layers, the selected layer's handles and the
/// magic wand's selection.
private struct ComposeCanvas: View {
    @Bindable var doc: ComposeDocument
    @Environment(\.undoManager) private var undo
    @FocusState private var focused: Bool
    /// The drag that moves a layer: the state before it, and where the layer was.
    @State private var moving: (before: Composition, id: UUID, frame: ImageFrame)?
    @State private var dragging = false
    @State private var resizing: Composition?
    @State private var pinchStart: Double?
    /// The zoom shown, for the zoom keys.
    @State private var shownScale = 1.0
    #if os(macOS)
        /// Reads ⌘+, ⌘− and ⌘0 while the editor is shown (see `zoomKey`).
        @State private var keyMonitor: Any?
    #endif
    /// Where the canvas is in the editor, and its zoom, for the rulers and guides.
    @State private var placement = CanvasPlacement()
    /// The lines a drag snapped to, shown while dragging.
    @State private var snapped: (x: Double?, y: Double?) = (nil, nil)
    /// A guide being dragged: the state before, and the guide.
    @State private var guideDrag: (before: Composition, id: UUID)?
    @AppStorage("composeRulers") private var rulers = false
    @AppStorage("composeGrid") private var grid = false
    @AppStorage("composeGridSize") private var gridSize = 64.0
    @AppStorage("composeSnap") private var snap = true

    private static let margin = 24.0
    static let rulerSize = 20.0

    var body: some View {
        let r = rulers ? Self.rulerSize : 0
        GeometryReader { outer in
            ZStack(alignment: .topLeading) {
                viewport
                    .padding(.leading, r)
                    .padding(.top, r)
                if rulers {
                    guideLines(in: outer.size)
                    rulerBars(in: outer.size)
                }
                snapLines(in: outer.size)
                ToolPalette(
                    doc: doc, rulers: $rulers, grid: $grid, gridSize: $gridSize, snap: $snap, bounds: outer.size,
                    inset: r)
            }
            .coordinateSpace(.named("editor"))
        }
        .background(Color.secondary.opacity(0.12))
        // Picture files dropped on the editor become layers.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.compactMap { url in
                (try? readPickedFile(url)).map { (name: url.lastPathComponent, data: $0) }
            }
            guard !files.isEmpty else { return false }
            Task { await doc.importImages(files, undo: undo) }
            return true
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(characters: ["v", "w", "b", "e", "s", "m"]) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.characters {
            case "v": doc.tool = .move
            case "w": doc.tool = .magicWand
            case "e": doc.tool = .eraser
            case "s": doc.tool = .smooth
            case "m": doc.tool = .area
            default: doc.tool = .brush
            }
            return .handled
        }
        // A layer picked in the list hands the keys back to the canvas.
        .onChange(of: doc.canvasFocusRequests) { focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            nudge(press) ? .handled : .ignored
        }
        .onKeyPress(.delete) { deleteKey() ? .handled : .ignored }
        #if os(macOS)
            .onAppear {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { zoomKey(event) } ? nil : event
                }
            }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
        #endif
        .onKeyPress(.escape) {
            if doc.area != nil {
                doc.area = nil
            } else if doc.hasMask {
                doc.clearMask()
            } else {
                doc.selection = nil
            }
            return .handled
        }
    }

    /// The scrolling, zooming area the canvas sits in.
    private var viewport: some View {
        GeometryReader { geo in
            let c = doc.composition
            let fit = max(
                0.01,
                min(
                    (geo.size.width - 2 * Self.margin) / Double(c.width),
                    (geo.size.height - 2 * Self.margin) / Double(c.height)))
            let s = doc.zoom ?? fit
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    canvas(c, scale: s)
                        .id("canvas")
                        .padding(Self.margin)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        // The whole area takes drags, so a layer partly or
                        // wholly off the canvas can still be grabbed.
                        .contentShape(Rectangle())
                        // The canvas sits centered in this area, at least the margin in.
                        .gesture(
                            canvasDrag(
                                scale: s,
                                origin: CGPoint(
                                    x: max(Self.margin, (geo.size.width - Double(c.width) * s) / 2),
                                    y: max(Self.margin, (geo.size.height - Double(c.height) * s) / 2))))
                }
                // Zooming keeps the canvas in the middle.
                .onChange(of: doc.zoom) { proxy.scrollTo("canvas", anchor: .center) }
                // Where the canvas is, for the rulers and guides.
                .onPreferenceChange(CanvasPlacementKey.self) { placement = $0 }
            }
            .onChange(of: s, initial: true) { shownScale = s }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if pinchStart == nil { pinchStart = s }
                        doc.zoom = Self.clampZoom((pinchStart ?? s) * v.magnification)
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .overlay(alignment: .bottomTrailing) { zoomControls(scale: s, fit: fit).padding(10) }
        }
    }

    // MARK: Drawing

    private func canvas(_ c: Composition, scale s: Double) -> some View {
        ZStack(alignment: .topLeading) {
            switch c.background {
            case .transparent: Checkerboard()
            case .white: Color.white
            case .black: Color.black
            }
            ForEach(c.layers) { layer in
                // The layer's shadow under it, as the saved picture has it.
                if layer.visible, let shadow = doc.shadowImages[layer.id] {
                    let f = layer.canvasFrame(of: shadow.rect)
                    Image(decorative: shadow.image, scale: 1)
                        .resizable()
                        .frame(width: f.width * s, height: f.height * s)
                        .opacity(layer.opacity)
                        .offset(x: f.x * s, y: f.y * s)
                        .allowsHitTesting(false)
                }
                if layer.visible, let image = doc.images[layer.image] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: layer.frame.width * s, height: layer.frame.height * s)
                        .grayscale(layer.grayscale ? 1 : 0)
                        .opacity(layer.opacity)
                        .offset(x: layer.frame.x * s, y: layer.frame.y * s)
                }
            }
        }
        .frame(width: Double(c.width) * s, height: Double(c.height) * s, alignment: .topLeading)
        .compositingGroup()
        .grayscale(c.grayscale ? 1 : 0)
        .clipped()
        // Where the selected layer sticks out of the canvas, faintly.
        .background(alignment: .topLeading) { offCanvas(c, scale: s) }
        .overlay {
            if grid {
                GridLines(spacing: gridSize * s)
                    .clipped()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background {
            GeometryReader { g in
                Color.clear.preference(
                    key: CanvasPlacementKey.self,
                    value: CanvasPlacement(origin: g.frame(in: .named("editor")).origin, scale: s))
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 4)
        .overlay(alignment: .topLeading) { selectionOverlay(c, scale: s) }
        .overlay(alignment: .topLeading) { areaOverlay(scale: s) }
        .coordinateSpace(.named("canvas"))
    }

    /// The selected layer drawn faintly, under the canvas: only what lies
    /// outside the canvas shows, so it can be found and dragged back.
    @ViewBuilder private func offCanvas(_ c: Composition, scale s: Double) -> some View {
        if let layer = c.layer(doc.selection), layer.visible, let image = doc.images[layer.image] {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: layer.frame.width * s, height: layer.frame.height * s)
                .opacity(0.3)
                .offset(x: layer.frame.x * s, y: layer.frame.y * s)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func selectionOverlay(_ c: Composition, scale s: Double) -> some View {
        if let layer = c.layer(doc.selection) {
            let f = layer.frame
            ZStack(alignment: .topLeading) {
                if let overlay = doc.maskOverlay {
                    Image(decorative: overlay, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: f.width * s, height: f.height * s)
                        .offset(x: f.x * s, y: f.y * s)
                        .allowsHitTesting(false)
                }
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .frame(width: f.width * s, height: f.height * s)
                    .offset(x: f.x * s, y: f.y * s)
                    .allowsHitTesting(false)
                if doc.tool == .move {
                    ForEach(Composition.Corner.allCases, id: \.self) { corner in
                        handle(layer.id, corner, at: Self.point(of: corner, in: f), scale: s)
                    }
                }
            }
        }
    }

    /// The area to redraw, as marching-ants lines.
    @ViewBuilder private func areaOverlay(scale s: Double) -> some View {
        if let a = doc.area {
            let shape = doc.areaEllipse ? AnyShape(Ellipse()) : AnyShape(Rectangle())
            ZStack {
                shape.stroke(Color.black.opacity(0.6), lineWidth: 1)
                shape.stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .frame(width: a.width * s, height: a.height * s)
            .offset(x: a.x * s, y: a.y * s)
            .allowsHitTesting(false)
        }
    }

    /// The area between two points of a drag, in canvas pixels, kept on the
    /// canvas; ⇧ makes it a square (or circle).
    static func area(from a: CGPoint, to b: CGPoint, scale s: Double, square: Bool) -> ImageFrame {
        var w = (b.x - a.x) / s
        var h = (b.y - a.y) / s
        if square {
            let side = max(abs(w), abs(h))
            w = w < 0 ? -side : side
            h = h < 0 ? -side : side
        }
        let x = a.x / s + min(0, w)
        let y = a.y / s + min(0, h)
        return ImageFrame(x: x.rounded(), y: y.rounded(), width: abs(w).rounded(), height: abs(h).rounded())
    }

    private func handle(_ id: UUID, _ corner: Composition.Corner, at p: CGPoint, scale s: Double) -> some View {
        let size = 12.0
        return Rectangle()
            .fill(.white)
            .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5) }
            .frame(width: size, height: size)
            .offset(x: p.x * s - size / 2, y: p.y * s - size / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        if resizing == nil { resizing = doc.composition }
                        let p = Snapping.point(
                            v.location.x / s, v.location.y / s, to: targets(), threshold: Self.snapDistance / s)
                        snapped = (p.lineX, p.lineY)
                        doc.live {
                            $0.resize(id, corner: corner, to: p.x, p.y, keepAspect: !Self.modifiers.shift)
                        }
                    }
                    .onEnded { _ in
                        if let before = resizing { doc.commit(since: before, "Resize Layer", undo: undo) }
                        resizing = nil
                        snapped = (nil, nil)
                    }
            )
            .help("Drag to resize; ⇧ to change the proportions")
    }

    private static func point(of corner: Composition.Corner, in f: ImageFrame) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: f.x, y: f.y)
        case .topRight: CGPoint(x: f.maxX, y: f.y)
        case .bottomLeft: CGPoint(x: f.x, y: f.maxY)
        case .bottomRight: CGPoint(x: f.maxX, y: f.maxY)
        }
    }

    // MARK: Input

    /// `origin`: where the canvas's top left is in the area the drag is on.
    private func canvasDrag(scale s: Double, origin: CGPoint) -> some Gesture {
        /// Points in that area → points from the canvas's top left.
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
        return DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                let start = local(v.startLocation)
                let now = local(v.location)
                let x = start.x / s
                let y = start.y / s
                if doc.tool == .area {
                    focused = true
                    doc.area = Self.area(from: start, to: now, scale: s, square: Self.modifiers.shift)
                    return
                }
                if doc.tool == .brush {
                    focused = true
                    doc.brush(atX: now.x / s, y: now.y / s, erase: doc.brushErases != Self.modifiers.option)
                    return
                }
                if doc.tool == .eraser || doc.tool == .smooth {
                    focused = true
                    doc.strokeLayer(atX: now.x / s, y: now.y / s)
                    return
                }
                if !dragging {
                    dragging = true
                    focused = true
                    guard doc.tool == .move else { return }
                    let keep = doc.selectedLayer.map { $0.visible && $0.frame.contains(x: x, y: y) } ?? false
                    let id = keep ? doc.selection : doc.composition.hitTest(x: x, y: y)
                    doc.selection = id
                    if let id, let frame = doc.composition.layer(id)?.frame {
                        moving = (doc.composition, id, frame)
                    }
                }
                if let moving {
                    let moved = Snapping.move(
                        moving.frame.offset(by: v.translation.width / s, v.translation.height / s), to: targets(),
                        threshold: Self.snapDistance / s)
                    snapped = (moved.x, moved.y)
                    doc.live { $0.update(moving.id) { $0.frame = moved.frame } }
                }
            }
            .onEnded { v in
                if doc.tool == .brush { return doc.endStroke() }
                if doc.tool == .eraser || doc.tool == .smooth { return doc.endLayerStroke(undo: undo) }
                if doc.tool == .area {
                    // A click without dragging clears the area.
                    if hypot(v.translation.width, v.translation.height) < 3 { doc.area = nil }
                    return
                }
                let click = hypot(v.translation.width, v.translation.height) < 3
                if doc.tool == .magicWand, click {
                    let m = Self.modifiers
                    let p = local(v.startLocation)
                    doc.wandClick(atX: p.x / s, y: p.y / s, mode: m.shift ? .add : m.option ? .subtract : nil)
                }
                if let moving { doc.commit(since: moving.before, "Move Layer", undo: undo) }
                moving = nil
                dragging = false
                snapped = (nil, nil)
            }
    }

    private func nudge(_ press: KeyPress) -> Bool {
        guard doc.tool == .move, doc.selection != nil else { return false }
        let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
        let (dx, dy): (Double, Double) =
            switch press.key {
            case .leftArrow: (-step, 0)
            case .rightArrow: (step, 0)
            case .upArrow: (0, -step)
            default: (0, step)
            }
        doc.nudgeSelected(by: dx, dy, undo: undo)
        return true
    }

    private func deleteKey() -> Bool {
        if doc.hasMask {
            Task { await doc.deleteMasked(undo: undo) }
            return true
        }
        guard let id = doc.selection else { return false }
        doc.removeLayer(id, undo: undo)
        return true
    }

    // MARK: Zoom

    private static func clampZoom(_ z: Double) -> Double { min(max(z, 0.02), 16) }

    private func zoomControls(scale s: Double, fit: Double) -> some View {
        HStack(spacing: 6) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { doc.zoom = Self.clampZoom(s / 1.25) }
                .help("Zoom out (⌘−)")
                #if os(iOS)
                    .keyboardShortcut("-", modifiers: .command)
                #endif
            Menu("\(Int((s * 100).rounded())) %") {
                Button("Fit (⌘0)") { doc.zoom = nil }
                ForEach([0.25, 0.5, 1, 2], id: \.self) { z in
                    Button("\(Int(z * 100)) %") { doc.zoom = z }
                }
            }
            .fixedSize()
            Button("Zoom In", systemImage: "plus.magnifyingglass") { doc.zoom = Self.clampZoom(s * 1.25) }
                .help("Zoom in (⌘+)")
                #if os(iOS)
                    .keyboardShortcut("+", modifiers: .command)
                #endif
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    #if os(macOS)
        /// ⌘+ (or ⌘=) zooms in, ⌘− out, ⌘0 fits. Read from the typed
        /// character, so it works on every keyboard layout: button
        /// shortcuts for + and − follow the US key positions and miss on
        /// others (German + and − are other keys). Not in sheets.
        private func zoomKey(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), flags.isDisjoint(with: [.control, .option]),
                event.window?.isSheet != true, event.window?.attachedSheet == nil,
                let key = event.charactersIgnoringModifiers ?? event.characters
            else { return false }
            let scale = shownScale
            switch key {
            case "+", "=": doc.zoom = Self.clampZoom(scale * 1.25)
            case "-", "_": doc.zoom = Self.clampZoom(scale / 1.25)
            case "0": doc.zoom = nil
            default: return false
            }
            return true
        }
    #endif

    /// Shift, Option and Command on the Mac; the iPad has no modifier keys here.
    static var modifiers: (shift: Bool, option: Bool, command: Bool) {
        #if os(macOS)
            let flags = NSEvent.modifierFlags
            return (flags.contains(.shift), flags.contains(.option), flags.contains(.command))
        #else
            return (false, false, false)
        #endif
    }

    // MARK: Snapping, rulers and guides

    /// Screen points within which a layer snaps.
    static let snapDistance = 8.0

    /// The grid (while shown), the guides (while the rulers are), and the
    /// canvas edges; ⌘ while dragging turns snapping off.
    private func targets() -> SnapTargets {
        guard snap, !Self.modifiers.command else { return SnapTargets() }
        return doc.composition.snapTargets(grid: grid ? gridSize : nil, guides: rulers)
    }

    /// A canvas position on an axis → editor points, and back.
    private func screen(_ v: Double, _ axis: CanvasGuide.Axis) -> Double {
        (axis == .vertical ? placement.origin.x : placement.origin.y) + v * placement.scale
    }

    private func canvasValue(_ p: CGPoint, _ axis: CanvasGuide.Axis) -> Double {
        let raw =
            axis == .vertical
            ? (p.x - placement.origin.x) / placement.scale : (p.y - placement.origin.y) / placement.scale
        // Guides snap to the grid while it is shown, else to whole pixels.
        if grid, snap, !Self.modifiers.command { return (raw / gridSize).rounded() * gridSize }
        return raw.rounded()
    }

    /// The top ruler makes horizontal guides, the left one vertical guides.
    private func rulerBars(in size: CGSize) -> some View {
        let r = Self.rulerSize
        return ZStack(alignment: .topLeading) {
            Ruler(axis: .horizontal, origin: placement.origin.x, scale: placement.scale, start: r)
                .frame(width: size.width, height: r)
                .gesture(guideMaker(.horizontal))
                .help("Drag down to make a guide")
            Ruler(axis: .vertical, origin: placement.origin.y, scale: placement.scale, start: r)
                .frame(width: r, height: size.height)
                .gesture(guideMaker(.vertical))
                .help("Drag right to make a guide")
            Rectangle().fill(.bar).frame(width: r, height: r)
                .overlay { Image(systemName: "ruler").font(.system(size: 9)).foregroundStyle(.secondary) }
                .contextMenu {
                    Button("Remove All Guides", role: .destructive) {
                        doc.change("Remove Guides", undo: undo) { $0.guides = [] }
                    }
                    .disabled(doc.composition.guideLines.isEmpty)
                }
                .help("Right-click to remove all guides")
        }
    }

    /// Dragging out of a ruler: a new guide follows the pointer; dropped
    /// back on the ruler it is gone again.
    private func guideMaker(_ axis: CanvasGuide.Axis) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("editor"))
            .onChanged { v in
                let position = canvasValue(v.location, axis)
                if let drag = guideDrag {
                    doc.live { $0.moveGuide(drag.id, to: position) }
                } else {
                    let before = doc.composition
                    var id = UUID()
                    doc.live { id = $0.addGuide(axis, at: position) }
                    guideDrag = (before, id)
                }
            }
            .onEnded { v in endGuideDrag(v.location, axis, name: "Add Guide") }
    }

    private func endGuideDrag(_ location: CGPoint, _ axis: CanvasGuide.Axis, name: String) {
        guard let drag = guideDrag else { return }
        let onRuler = (axis == .horizontal ? location.y : location.x) < Self.rulerSize
        if onRuler { doc.live { $0.removeGuide(drag.id) } }
        doc.commit(since: drag.before, onRuler ? "Remove Guide" : name, undo: undo)
        guideDrag = nil
    }

    /// The guides across the viewport; with the move tool they can be
    /// dragged, and dropped on their ruler to remove them.
    private func guideLines(in size: CGSize) -> some View {
        let r = Self.rulerSize
        return ZStack(alignment: .topLeading) {
            ForEach(doc.composition.guideLines) { guide in
                let at = screen(guide.position, guide.axis == .vertical ? .vertical : .horizontal)
                let vertical = guide.axis == .vertical
                Rectangle()
                    .fill(Color.cyan)
                    .frame(width: vertical ? 1 : size.width, height: vertical ? size.height : 1)
                    .overlay {
                        // A wider strip to grab it by.
                        Color.clear
                            .frame(width: vertical ? 9 : size.width, height: vertical ? size.height : 9)
                            .contentShape(Rectangle())
                            .gesture(guideMover(guide))
                            #if os(macOS)
                                .onHover { inside in
                                    if inside {
                                        (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            #endif
                    }
                    .offset(x: vertical ? at : 0, y: vertical ? 0 : at)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .mask { Rectangle().padding(.leading, r).padding(.top, r) }
        .allowsHitTesting(doc.tool == .move)
    }

    private func guideMover(_ guide: CanvasGuide) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("editor"))
            .onChanged { v in
                if guideDrag == nil { guideDrag = (doc.composition, guide.id) }
                let position = canvasValue(v.location, guide.axis)
                doc.live { $0.moveGuide(guide.id, to: position) }
            }
            .onEnded { v in endGuideDrag(v.location, guide.axis, name: "Move Guide") }
    }

    /// The lines a layer snapped to, while it is dragged.
    private func snapLines(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let x = snapped.x {
                Rectangle().fill(Color.pink).frame(width: 1, height: size.height).offset(x: screen(x, .vertical))
            }
            if let y = snapped.y {
                Rectangle().fill(Color.pink).frame(width: size.width, height: 1).offset(y: screen(y, .horizontal))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .mask { Rectangle().padding(.leading, rulers ? Self.rulerSize : 0).padding(.top, rulers ? Self.rulerSize : 0) }
        .allowsHitTesting(false)
    }
}

/// Where the canvas is in the editor (top left, in points) and its zoom.
struct CanvasPlacement: Equatable {
    var origin = CGPoint.zero
    var scale = 1.0
}

struct CanvasPlacementKey: PreferenceKey {
    static let defaultValue = CanvasPlacement()
    static func reduce(value: inout CanvasPlacement, nextValue: () -> CanvasPlacement) { value = nextValue() }
}

/// A ruler in canvas pixels along the top or the left edge.
private struct Ruler: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    /// Where canvas pixel 0 is, in the editor's points along the ruler.
    let origin: Double
    let scale: Double
    /// Nothing is drawn before this point (the corner).
    let start: Double

    var body: some View {
        Canvas { ctx, size in
            let length = axis == .horizontal ? size.width : size.height
            // Labels at least 60 points apart.
            let steps: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000]
            let step = steps.first { $0 * scale >= 60 } ?? 10000
            let minor = step / 5
            var v = (((start - origin) / scale) / minor).rounded(.down) * minor
            let end = (length - origin) / scale
            let ink = GraphicsContext.Shading.color(.secondary)
            while v <= end {
                let at = origin + v * scale
                if at >= start {
                    let major = abs(v.remainder(dividingBy: step)) < minor / 2
                    let tick = major ? 8.0 : 4.0
                    var line = Path()
                    if axis == .horizontal {
                        line.move(to: CGPoint(x: at, y: size.height - tick))
                        line.addLine(to: CGPoint(x: at, y: size.height))
                    } else {
                        line.move(to: CGPoint(x: size.width - tick, y: at))
                        line.addLine(to: CGPoint(x: size.width, y: at))
                    }
                    ctx.stroke(line, with: ink, lineWidth: 0.5)
                    if major {
                        let label = ctx.resolve(Text("\(Int(v))").font(.system(size: 9)).foregroundStyle(.secondary))
                        if axis == .horizontal {
                            ctx.draw(label, at: CGPoint(x: at + 2, y: 1), anchor: .topLeading)
                        } else {
                            var turned = ctx
                            turned.translateBy(x: 1, y: at - 2)
                            turned.rotate(by: .degrees(-90))
                            turned.draw(label, at: .zero, anchor: .topLeading)
                        }
                    }
                }
                v += minor
            }
        }
        .background(.bar)
        .overlay(alignment: axis == .horizontal ? .bottom : .trailing) {
            if axis == .horizontal { Divider() } else { Divider().frame(maxHeight: .infinity) }
        }
    }
}

/// The grid over the canvas; too fine at this zoom, only every few lines.
private struct GridLines: View {
    let spacing: Double

    var body: some View {
        Canvas { ctx, size in
            guard spacing > 0 else { return }
            let step = spacing * (spacing < 6 ? (6 / spacing).rounded(.up) : 1)
            var path = Path()
            var x = step
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y = step
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            ctx.stroke(path, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
        }
    }
}

/// The tools, the rulers and the grid as a vertical bar over the canvas,
/// which can be dragged anywhere by its grip.
private struct ToolPalette: View {
    @Bindable var doc: ComposeDocument
    @Binding var rulers: Bool
    @Binding var grid: Bool
    @Binding var gridSize: Double
    @Binding var snap: Bool
    let bounds: CGSize
    /// The rulers' width, which it keeps clear of.
    let inset: Double
    @AppStorage("toolPaletteX") private var x = 12.0
    @AppStorage("toolPaletteY") private var y = 12.0
    @State private var dragStart: CGPoint?
    @State private var size = CGSize(width: 44, height: 340)
    @Environment(\.undoManager) private var undo
    /// What Undo and Redo would do; `nil` = nothing. `UndoManager` can't be
    /// observed, so this follows its notifications.
    @State private var history: (undo: String?, redo: String?) = (nil, nil)

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(coordinateSpace: .named("editor"))
                        .onChanged { v in
                            let start = dragStart ?? CGPoint(x: x, y: y)
                            dragStart = start
                            x = start.x + v.translation.width
                            y = start.y + v.translation.height
                        }
                        .onEnded { _ in
                            dragStart = nil
                            (x, y) = (clamped.x, clamped.y)
                        }
                )
                .help("Drag to move the tools")
            tool(.move, "arrow.up.and.down.and.arrow.left.and.right", "Move and resize layers (V)")
            tool(.magicWand, "wand.and.rays", "Magic wand: select by color (W)")
            tool(.brush, "paintbrush.pointed", "Brush: paint a selection (B)")
            tool(.eraser, "eraser", "Eraser: rub out pixels of a layer (E)")
            tool(.smooth, "scribble.variable", "Smooth edges: even out a cut-out's outline where you paint (S)")
            tool(.area, "rectangle.dashed", "Area: drag a part of the picture to redraw with the model (M)")
            Divider().frame(width: 28)
            button(
                "arrow.uturn.backward",
                history.undo.map { $0.isEmpty ? "Undo (⌘Z)" : "Undo \($0) (⌘Z)" } ?? "Nothing to undo", on: false
            ) { undo?.undo() }
            .disabled(history.undo == nil)
            #if os(iOS)
                .keyboardShortcut("z", modifiers: .command)
            #endif
            button(
                "arrow.uturn.forward",
                history.redo.map { $0.isEmpty ? "Redo (⇧⌘Z)" : "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo", on: false
            ) { undo?.redo() }
            .disabled(history.redo == nil)
            #if os(iOS)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            #endif
            button("plus.square.on.square", "New empty layer, above the selected one", on: false) {
                doc.addEmptyLayer(undo: undo)
            }
            Divider().frame(width: 28)
            toggle($rulers, "ruler", "Rulers and guides: drag a guide out of a ruler (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            toggle($grid, "grid", "Grid; right-click for its size and snapping (⌘')")
                .keyboardShortcut("'", modifiers: .command)
                .contextMenu {
                    Picker("Grid Size", selection: $gridSize) {
                        ForEach([8.0, 16, 32, 64, 128, 256], id: \.self) { Text("\(Int($0)) px").tag($0) }
                    }
                    Toggle("Snap to Grid and Guides", isOn: $snap)
                }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .background { GeometryReader { g in Color.clear.onAppear { size = g.size } } }
        .offset(x: clamped.x, y: clamped.y)
        .onAppear(perform: readHistory)
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in readHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in readHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in readHistory() }
    }

    private func readHistory() {
        guard let undo else { return history = (nil, nil) }
        history = (undo.canUndo ? undo.undoActionName : nil, undo.canRedo ? undo.redoActionName : nil)
    }

    /// Inside the editor and clear of the rulers.
    private var clamped: CGPoint {
        CGPoint(
            x: min(max(inset + 4, x), max(inset + 4, bounds.width - size.width - 4)),
            y: min(max(inset + 4, y), max(inset + 4, bounds.height - size.height - 4)))
    }

    private func tool(_ t: ComposeDocument.Tool, _ icon: String, _ help: String) -> some View {
        button(icon, help, on: doc.tool == t) { doc.tool = t }
    }

    private func toggle(_ value: Binding<Bool>, _ icon: String, _ help: String) -> some View {
        button(icon, help, on: value.wrappedValue) {
            withAnimation(.easeInOut(duration: 0.2)) { value.wrappedValue.toggle() }
        }
    }

    private func button(_ icon: String, _ help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The magic wand's or the brush's settings, and what to do with the
/// selection, over the canvas while one of them is the tool.
private struct SelectionBar: View {
    @Bindable var doc: ComposeDocument
    @Environment(\.undoManager) private var undo

    var body: some View {
        if doc.tool == .area {
            areaBar
        } else if doc.tool == .eraser {
            eraserBar
        } else if doc.tool == .smooth {
            smoothBar
        } else {
            pixelBar
        }
    }

    /// The smoothing brush: size, strength, how far it evens out, and
    /// whether the outline stays sharp.
    private var smoothBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Size")
                Slider(value: $doc.smoothSize, in: 4...400).frame(width: 100)
                Text("\(Int(doc.smoothSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }
            .help("Diameter in canvas pixels")
            HStack(spacing: 4) {
                Text("Strength")
                Slider(value: $doc.smoothStrength, in: 0.05...1).frame(width: 80)
                Text("\(Int((doc.smoothStrength * 100).rounded())) %").monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            HStack(spacing: 4) {
                Text("Smoothness")
                Slider(value: $doc.smoothness, in: 1...20).frame(width: 80)
                Text("\(Int(doc.smoothness))").monospacedDigit().frame(width: 22, alignment: .trailing)
            }
            .help("How far along the edge steps and specks are evened out, in canvas pixels")
            Toggle("Keep Edge Sharp", isOn: $doc.smoothCrisp)
                .help("On: a smooth but sharp outline. Off: the edge fades out softly")
            Button("Whole Edge", systemImage: "circle.dashed") { doc.smoothWholeEdge(undo: undo) }
                .disabled(doc.selectedLayer == nil || doc.busy)
                .help("Smooth the selected layer's whole outline at once")
        }
        #if os(macOS)
            .toggleStyle(.checkbox)
        #endif
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The eraser: size, strength and how soft its edge is.
    private var eraserBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Size")
                Slider(value: $doc.eraserSize, in: 2...400).frame(width: 110)
                Text("\(Int(doc.eraserSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }
            .help("Diameter in canvas pixels")
            HStack(spacing: 4) {
                Text("Strength")
                Slider(value: $doc.eraserStrength, in: 0.05...1).frame(width: 90)
                Text("\(Int((doc.eraserStrength * 100).rounded())) %").monospacedDigit().frame(
                    width: 40, alignment: .trailing)
            }
            .help("How much one stroke takes away; go over it again with a new stroke for more")
            HStack(spacing: 4) {
                Text("Hardness")
                Slider(value: $doc.eraserHardness, in: 0...1).frame(width: 90)
                Text("\(Int((doc.eraserHardness * 100).rounded())) %").monospacedDigit().frame(
                    width: 40, alignment: .trailing)
            }
            .help("100 %: a hard edge; lower fades the edge out")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The area tool: its shape, and how to redraw.
    private var areaBar: some View {
        HStack(spacing: 12) {
            Picker("Shape", selection: $doc.areaEllipse) {
                Label("Rectangle", systemImage: "rectangle").tag(false)
                Label("Ellipse", systemImage: "oval").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(
                doc.area == nil
                    ? "Drag over the part of the picture to redraw (⇧ for a square)"
                    : "Write what should be there under Redraw Area, on the right"
            )
            .font(.callout).foregroundStyle(.secondary)
            Button("Deselect", systemImage: "xmark.circle") { doc.area = nil }
                .labelStyle(.iconOnly)
                .disabled(doc.area == nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var pixelBar: some View {
        HStack(spacing: 12) {
            if doc.tool == .magicWand {
                Picker("Mode", selection: $doc.wandMode) {
                    ForEach(ComposeDocument.WandMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("A click makes a new selection, adds to it or takes from it (⇧ adds, ⌥ subtracts)")
                HStack(spacing: 4) {
                    Text("Tolerance")
                    Slider(value: $doc.tolerance, in: 0...128, onEditingChanged: { if !$0 { doc.reselect() } })
                        .frame(width: 110)
                    Text("\(Int(doc.tolerance))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                Toggle("Contiguous", isOn: $doc.contiguous)
                    .help("Only pixels connected to the clicked one")
            } else {
                Picker("Brush", selection: $doc.brushErases) {
                    Text("Paint").tag(false)
                    Text("Erase").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Paint the selection or take from it (⌥ switches while held)")
                HStack(spacing: 4) {
                    Text("Size")
                    Slider(value: $doc.brushSize, in: 4...400).frame(width: 110)
                    Text("\(Int(doc.brushSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
            Toggle("Smooth Edge", isOn: $doc.antiAlias)
                .help("Fade the pixels along the edge of what is deleted")
            Button("Invert", systemImage: "circle.lefthalf.filled") { doc.invertMask() }
                .disabled(!doc.hasMask)
                .help("Select everything else")
            Button("Deselect", systemImage: "xmark.circle") { doc.clearMask() }
                .disabled(!doc.hasMask)
            Button("Delete Selection", systemImage: "trash") {
                Task { await doc.deleteMasked(undo: undo) }
            }
            .disabled(!doc.hasMask || doc.busy)
            .help("Make the selected pixels transparent (⌫)")
        }
        #if os(macOS)
            .toggleStyle(.checkbox)
        #endif
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: doc.contiguous) { doc.reselect() }
        .overlay(alignment: .bottom) {
            if !doc.hasMask {
                Text(
                    doc.tool == .magicWand
                        ? "Click a layer to select by color" : "Paint over the part of a layer to select"
                )
                .font(.caption).foregroundStyle(.secondary).offset(y: 22)
            }
        }
    }
}

/// Pick gallery pictures to add as layers.
struct PicturePicker: View {
    /// One picture only (a LoRA's), instead of several layers.
    var single = false
    let add: ([UUID]) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// In the order they were picked; the first goes lowest.
    @State private var picked: [UUID] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(app.gallery.index.items) { item in
                        ThumbnailCell(item: item, selected: picked.contains(item.id))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .topTrailing) {
                                if !single, let n = picked.firstIndex(of: item.id) {
                                    Text("\(n + 1)").font(.caption.bold()).padding(5)
                                        .background(Color.accentColor, in: Circle()).foregroundStyle(.white)
                                        .padding(4)
                                }
                            }
                            .onTapGesture {
                                if single {
                                    picked = picked == [item.id] ? [] : [item.id]
                                } else if let i = picked.firstIndex(of: item.id) {
                                    picked.remove(at: i)
                                } else {
                                    picked.append(item.id)
                                }
                            }
                    }
                }
                .padding()
            }
            .navigationTitle(single ? "Choose a Picture" : "Add Pictures")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(single ? "Use" : picked.count > 1 ? "Add \(picked.count) Pictures" : "Add") {
                        add(picked)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 620, minHeight: 480)
        #endif
    }
}

/// Adding layers: an empty one, gallery pictures, or picture files.
struct AddLayerMenu: View {
    @Bindable var doc: ComposeDocument
    @Environment(\.undoManager) private var undo

    var body: some View {
        Menu("Add Layer", systemImage: "plus") {
            Button("Empty Layer", systemImage: "square.dashed") { doc.addEmptyLayer(undo: undo) }
            Button("Pictures from the Gallery…", systemImage: "photo.on.rectangle") { doc.pickingFromGallery = true }
            Button("Import Picture Files…", systemImage: "square.and.arrow.down") { doc.importingFiles = true }
        }
        .help("Add a layer: empty, from the gallery, or from picture files (or drop files on the canvas)")
    }
}

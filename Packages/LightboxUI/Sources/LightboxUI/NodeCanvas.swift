import ComfyKit
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The node editor's canvas. Positions are in canvas units, as in the file;
/// on screen a point is `(canvas + offset) * scale`, like ComfyUI's
/// `extra.ds`. Drag the background to pan (⇧ or ⌘ to select a rectangle),
/// scroll with the trackpad to pan, pinch or use the mouse wheel to zoom.
struct NodeCanvas: View {
    @Bindable var editor: NodeEditorModel
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo

    @State private var scale = 1.0
    @State private var offset = CGPoint.zero
    @State private var size = CGSize.zero
    @State private var hover: CGPoint?
    @FocusState private var focused: Bool

    // Drags in progress.
    @State private var before: WorkflowDocument?
    @State private var moveBase: [Int: CGPoint] = [:]
    @State private var resizeBase: CGSize?
    @State private var groupBase: (frame: CGRect, nodes: [Int: CGPoint])?
    @State private var link: LinkDrag?
    @State private var panBase: CGPoint?
    @State private var rubber: (start: CGPoint, end: CGPoint)?
    @State private var pinchBase: Double?
    #if os(macOS)
        @State private var monitor: Any?
    #endif

    struct LinkDrag {
        /// Dragged from an output (to an input), or from an input (to an output).
        var fromOutput: Bool
        var node: Int
        var slot: Int
        var type: String
        var anchor: CGPoint
        var current: CGPoint
    }

    struct Item {
        let node: GraphNode
        let kind: NodeKind
        let layout: NodeLayout
    }

    var body: some View {
        let graph = editor.graph
        let items = graph.nodes.map { n -> Item in
            let kind = editor.kind(n, catalog: app.catalog)
            let shows =
                editor.outputs[editor.nodePath(n.id)] != nil
                || (kind.spec?.isOutputNode == true && kind.spec?.inputs.values.contains { $0.type == "IMAGE" } == true)
            return Item(node: n, kind: kind, layout: NodeLayout(n, kind: kind, showsImages: shows))
        }
        let layouts = Dictionary(uniqueKeysWithValues: items.map { ($0.node.id, $0.layout) })
        ZStack(alignment: .topLeading) {
            background(graph, layouts: layouts)
            content(graph, items: items)
            overlayDrawing
        }
        .coordinateSpace(.named("canvas"))
        .clipped()
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            size = $0
            editor.viewCenter = center
        }
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover = p } else { hover = nil }
        }
        .gesture(
            MagnifyGesture()
                .onChanged { v in
                    let base = pinchBase ?? scale
                    pinchBase = base
                    zoom(to: base * v.magnification, around: v.startLocation)
                }
                .onEnded { _ in
                    pinchBase = nil
                    persistViewport()
                }
        )
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            editor.deleteSelection(undo: undo)
            return .handled
        }
        .onKeyPress(.escape) {
            editor.selection = []
            return .handled
        }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            editor.selectAll()
            return .handled
        }
        #if os(macOS)
            .onCopyCommand {
                editor.copySelection()
                return []
            }
            .onCutCommand {
                editor.copySelection()
                editor.deleteSelection(undo: undo)
                return []
            }
            .onPasteCommand(of: [.plainText]) { _ in editor.paste(at: hoverCanvas, undo: undo) }
        #endif
        .onAppear {
            scale = editor.doc.scale
            offset = editor.doc.offset
            installScrollMonitor()
        }
        .onDisappear { removeScrollMonitor() }
        .onChange(of: editor.path) { fit(items) }
        .task(id: size == .zero) {
            // A file without a saved view (or a new one) shows all its nodes.
            if size != .zero, editor.doc.scale == 1, editor.doc.offset == .zero, !items.isEmpty { fit(items) }
        }
        .contextMenu { backgroundMenu(items) }
    }

    // MARK: - Coordinates

    private func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / scale - offset.x, y: p.y / scale - offset.y) }
    private func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x + offset.x) * scale, y: (p.y + offset.y) * scale) }
    private var hoverCanvas: CGPoint? { hover.map(toCanvas) }
    private var center: CGPoint { toCanvas(CGPoint(x: size.width / 2, y: size.height / 3)) }

    private func zoom(to newScale: Double, around p: CGPoint) {
        let s = min(4, max(0.1, newScale))
        let c = toCanvas(p)
        scale = s
        offset = CGPoint(x: p.x / s - c.x, y: p.y / s - c.y)
    }

    private func persistViewport() {
        editor.setViewport(scale: scale, offset: offset)
        editor.viewCenter = center
    }

    func fit(_ items: [Item]) {
        let bounds = items.map(\.layout.bounds).reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull, size.width > 0 else { return }
        let s = min(1.2, max(0.1, min(size.width / (bounds.width + 80), size.height / (bounds.height + 80))))
        scale = s
        offset = CGPoint(
            x: (size.width / s - bounds.width) / 2 - bounds.minX, y: (size.height / s - bounds.height) / 2 - bounds.minY
        )
        persistViewport()
    }

    // MARK: - Drawing

    /// Grid, groups and links, under the nodes; also takes the background's
    /// clicks and drags.
    private func background(_ graph: NodeGraph, layouts: [Int: NodeLayout]) -> some View {
        Canvas { ctx, canvasSize in
            ctx.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(NodeColors.canvas))
            // Grid.
            let step = scale < 0.5 ? 200.0 : 50.0
            var grid = Path()
            let start = toCanvas(.zero)
            let end = toCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))
            var x = (start.x / step).rounded(.down) * step
            while x < end.x {
                grid.move(to: toScreen(CGPoint(x: x, y: start.y)))
                grid.addLine(to: toScreen(CGPoint(x: x, y: end.y)))
                x += step
            }
            var y = (start.y / step).rounded(.down) * step
            while y < end.y {
                grid.move(to: toScreen(CGPoint(x: start.x, y: y)))
                grid.addLine(to: toScreen(CGPoint(x: end.x, y: y)))
                y += step
            }
            ctx.stroke(grid, with: .color(NodeColors.grid), lineWidth: 1)

            for group in graph.groups {
                let r = CGRect(
                    origin: toScreen(group.frame.origin),
                    size: group.frame.size.applying(.init(scaleX: scale, y: scale)))
                let color = Color(hex: group.color ?? "#3f789e")
                ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(color.opacity(0.25)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(color.opacity(0.6)), lineWidth: 1)
                let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: 34 * scale)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 6), with: .color(color.opacity(0.5)))
                let text = Text(group.title).font(.system(size: 20 * scale, weight: .semibold)).foregroundColor(.white)
                ctx.draw(text, at: CGPoint(x: r.minX + 10 * scale, y: r.minY + 17 * scale), anchor: .leading)
            }

            let reroutes = Dictionary(uniqueKeysWithValues: graph.reroutes.map { ($0.id, $0) })
            for l in graph.links {
                guard let from = layouts[l.origin]?.outputPoints[safe: l.originSlot],
                    let to = layouts[l.target]?.inputPoints[safe: l.targetSlot] ?? nil
                else { continue }
                // Through native reroutes, last first.
                var points: [CGPoint] = []
                var next = l.parentReroute
                var guardCount = 0
                while let id = next, let r = reroutes[id], guardCount < 32 {
                    points.insert(r.position, at: 0)
                    next = r.parent
                    guardCount += 1
                }
                let all = [from] + points + [to]
                var path = Path()
                for i in 0..<(all.count - 1) { Self.curve(&path, toScreen(all[i]), toScreen(all[i + 1]), scale: scale) }
                ctx.stroke(path, with: .color(NodeColors.type(l.type)), lineWidth: max(1.5, 3 * scale))
                for p in points {
                    let s = toScreen(p)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10)),
                        with: .color(NodeColors.type(l.type)))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(backgroundDrag(layouts))
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { v in
                guard !editor.isReadOnly else { return }
                editor.search = .init(position: toCanvas(v.location))
            }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                editor.selection = []
                focused = true
            })
    }

    /// The link being dragged and the selection rectangle, over the nodes.
    private var overlayDrawing: some View {
        Canvas { ctx, _ in
            if let link {
                var path = Path()
                let a = toScreen(link.anchor)
                let b = toScreen(link.current)
                if link.fromOutput {
                    Self.curve(&path, a, b, scale: scale)
                } else {
                    Self.curve(&path, b, a, scale: scale)
                }
                ctx.stroke(
                    path, with: .color(NodeColors.type(link.type)),
                    style: StrokeStyle(lineWidth: max(1.5, 3 * scale), dash: [8, 4]))
            }
            if let rubber {
                let r = CGRect(from: toScreen(rubber.start), to: toScreen(rubber.end))
                ctx.fill(Path(r), with: .color(.white.opacity(0.08)))
                ctx.stroke(Path(r), with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    static func curve(_ path: inout Path, _ a: CGPoint, _ b: CGPoint, scale: Double) {
        let d = max(abs(b.x - a.x) * 0.5, 40 * scale)
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + d, y: a.y), control2: CGPoint(x: b.x - d, y: b.y))
    }

    // MARK: - Nodes

    private func content(_ graph: NodeGraph, items: [Item]) -> some View {
        let actions = NodeActions(
            select: select, move: { move($0, $1, graph) }, endMove: { end("Move") },
            resize: { resize($0, $1, graph, items) }, endResize: { end("Resize") },
            dragSocket: { dragSocket($0, $1, $2, $3, graph, items) }, endSocket: { endSocket($0, items) },
            open: { editor.enter($0) })
        return ZStack(alignment: .topLeading) {
            ForEach(Array(graph.groups.enumerated()), id: \.element.id) { _, group in
                groupHandle(group, graph: graph, items: items)
            }
            ForEach(items, id: \.node.id) { item in
                NodeView(
                    node: item.node, layout: item.layout, kind: item.kind,
                    selected: editor.selection.contains(item.node.id),
                    actions: actions, editor: editor
                )
                .offset(x: item.layout.bounds.minX, y: item.layout.bounds.minY)
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .offset(x: offset.x, y: offset.y)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .allowsHitTesting(true)
    }

    private func select(_ id: Int, _ extend: Bool) {
        focused = true
        if extend {
            if editor.selection.contains(id) { editor.selection.remove(id) } else { editor.selection.insert(id) }
        } else {
            editor.selection = [id]
        }
    }

    private func move(_ id: Int, _ t: CGSize, _ graph: NodeGraph) {
        guard !editor.isReadOnly else { return }
        if before == nil {
            before = editor.snapshot
            if !editor.selection.contains(id) { editor.selection = [id] }
            moveBase = Dictionary(
                uniqueKeysWithValues: graph.nodes.filter { editor.selection.contains($0.id) && !$0.pinned }.map {
                    ($0.id, $0.position)
                })
        }
        let d = CGSize(width: t.width / scale, height: t.height / scale)
        editor.live { g in
            for i in g.nodes.indices {
                guard let base = moveBase[g.nodes[i].id] else { continue }
                g.nodes[i].position = CGPoint(x: base.x + d.width, y: base.y + d.height)
            }
        }
    }

    private func resize(_ id: Int, _ t: CGSize, _ graph: NodeGraph, _ items: [Item]) {
        guard !editor.isReadOnly, let item = items.first(where: { $0.node.id == id }) else { return }
        if before == nil {
            before = editor.snapshot
            resizeBase = CGSize(width: item.layout.frame.width, height: item.layout.frame.height)
        }
        guard let base = resizeBase else { return }
        editor.live { g in
            guard let i = g.index(of: id) else { return }
            g.nodes[i].size = CGSize(
                width: max(140, base.width + t.width / scale),
                height: max(item.layout.minHeight, base.height + t.height / scale))
        }
    }

    private func end(_ name: String) {
        if let before { editor.commit(since: before, name, undo: undo) }
        before = nil
        moveBase = [:]
        resizeBase = nil
        groupBase = nil
    }

    // MARK: - Links

    private func dragSocket(
        _ id: Int, _ slot: Int, _ isOutput: Bool, _ location: CGPoint, _ graph: NodeGraph, _ items: [Item]
    ) {
        guard !editor.isReadOnly else { return }
        let p = toCanvas(location)
        if link == nil {
            guard let node = graph.node(id), let layout = items.first(where: { $0.node.id == id })?.layout else {
                return
            }
            before = editor.snapshot
            if isOutput {
                link = LinkDrag(
                    fromOutput: true, node: id, slot: slot, type: node.outputs[slot].type,
                    anchor: layout.outputPoints[slot], current: p)
            } else if let existing = node.inputs[slot].link.flatMap({ graph.link($0) }),
                let from = items.first(where: { $0.node.id == existing.origin })?.layout.outputPoints[
                    safe: existing.originSlot]
            {
                // Pick the link up from the input: it hangs from its output again.
                editor.live { $0.removeLink(existing.id) }
                link = LinkDrag(
                    fromOutput: true, node: existing.origin, slot: existing.originSlot, type: existing.type,
                    anchor: from,
                    current: p)
            } else if let anchor = layout.inputPoints[slot] {
                link = LinkDrag(
                    fromOutput: false, node: id, slot: slot, type: node.inputs[slot].type, anchor: anchor, current: p)
            }
        }
        link?.current = p
    }

    private func endSocket(_ location: CGPoint, _ items: [Item]) {
        defer {
            link = nil
            before = nil
        }
        guard let drag = link else { return }
        let p = toCanvas(location)
        let reach = max(14, 14 / scale)
        if drag.fromOutput {
            if let (node, slot) = input(near: p, accepting: drag.type, items: items, reach: reach, except: drag.node) {
                editor.live { $0.connect(from: drag.node, drag.slot, to: node, slot) }
                if let before { editor.commit(since: before, "Connect", undo: undo) }
            } else if items.contains(where: { $0.layout.bounds.contains(p) }) {
                if let before { editor.commit(since: before, "Disconnect", undo: undo) }
            } else {
                if let before { editor.commit(since: before, "Disconnect", undo: undo) }
                editor.search = .init(position: p, fromOutput: (drag.node, drag.slot, drag.type))
            }
        } else {
            if let (node, slot) = output(near: p, accepting: drag.type, items: items, reach: reach, except: drag.node) {
                editor.live { $0.connect(from: node, slot, to: drag.node, drag.slot) }
                if let before { editor.commit(since: before, "Connect", undo: undo) }
            } else if !items.contains(where: { $0.layout.bounds.contains(p) }) {
                editor.search = .init(
                    position: CGPoint(x: p.x - 300, y: p.y), toInput: (drag.node, drag.slot, drag.type))
            }
        }
    }

    /// The input at `p`: a socket within reach, else the first fitting
    /// (free if possible) input of the node under `p`.
    private func input(near p: CGPoint, accepting type: String, items: [Item], reach: Double, except: Int)
        -> (Int, Int)?
    {
        var best: (Int, Int, Double)?
        for item in items where item.node.id != except {
            for (i, point) in item.layout.inputPoints.enumerated() {
                guard let point, NodeGraph.accepts(item.node.inputs[i].type, from: type) else { continue }
                let d = hypot(point.x - p.x, point.y - p.y)
                if d < reach, d < (best?.2 ?? .infinity) { best = (item.node.id, i, d) }
            }
        }
        if let best { return (best.0, best.1) }
        guard let item = items.last(where: { $0.layout.bounds.contains(p) && $0.node.id != except }) else { return nil }
        let fitting = item.node.inputs.indices.filter {
            NodeGraph.accepts(item.node.inputs[$0].type, from: type) && item.node.inputs[$0].widget == nil
        }
        return (fitting.first { item.node.inputs[$0].link == nil } ?? fitting.first).map { (item.node.id, $0) }
    }

    private func output(near p: CGPoint, accepting type: String, items: [Item], reach: Double, except: Int)
        -> (Int, Int)?
    {
        for item in items where item.node.id != except {
            for (i, point) in item.layout.outputPoints.enumerated()
            where NodeGraph.accepts(type, from: item.node.outputs[i].type)
                && hypot(point.x - p.x, point.y - p.y) < reach
            {
                return (item.node.id, i)
            }
        }
        guard let item = items.last(where: { $0.layout.bounds.contains(p) && $0.node.id != except }) else { return nil }
        return item.node.outputs.indices.first { NodeGraph.accepts(type, from: item.node.outputs[$0].type) }.map {
            (item.node.id, $0)
        }
    }

    // MARK: - Background

    private func backgroundDrag(_ layouts: [Int: NodeLayout]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { v in
                if rubber == nil, panBase == nil {
                    if Self.selectsRectangle {
                        rubber = (toCanvas(v.startLocation), toCanvas(v.location))
                    } else {
                        panBase = offset
                    }
                }
                if rubber != nil {
                    rubber?.end = toCanvas(v.location)
                } else if let base = panBase {
                    offset = CGPoint(x: base.x + v.translation.width / scale, y: base.y + v.translation.height / scale)
                }
            }
            .onEnded { _ in
                if let rubber {
                    let r = CGRect(from: rubber.start, to: rubber.end)
                    let hit = layouts.filter { $0.value.bounds.intersects(r) }.map(\.key)
                    if Self.extendsSelection { editor.selection.formUnion(hit) } else { editor.selection = Set(hit) }
                    focused = true
                }
                if panBase != nil { persistViewport() }
                rubber = nil
                panBase = nil
            }
    }

    static var selectsRectangle: Bool {
        #if os(macOS)
            NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                || NSEvent.modifierFlags.contains(.control)
        #else
            false
        #endif
    }

    static var extendsSelection: Bool {
        #if os(macOS)
            NSEvent.modifierFlags.contains(.shift)
        #else
            false
        #endif
    }

    @ViewBuilder
    private func backgroundMenu(_ items: [Item]) -> some View {
        let at = hoverCanvas ?? center
        if !editor.isReadOnly {
            Button("Add Node…", systemImage: "plus") { editor.search = .init(position: at) }
            Button("Add Group", systemImage: "rectangle.dashed") {
                editor.addGroup(at: at, catalog: app.catalog, undo: undo)
            }
            Button("Paste", systemImage: "doc.on.clipboard") { editor.paste(at: at, undo: undo) }
                .disabled(NodeEditorModel.clipboard == nil)
            Divider()
        }
        Button("Show All Nodes", systemImage: "arrow.up.left.and.arrow.down.right") { fit(items) }
        Button("Select All", systemImage: "checklist") { editor.selectAll() }
    }

    // MARK: - Groups

    private func groupHandle(_ group: GraphGroup, graph: NodeGraph, items: [Item]) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: group.frame.width, height: 34)
                .contentShape(Rectangle())
                .frame(width: group.frame.width, height: group.frame.height, alignment: .top)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                        .onChanged { moveGroup(group, $0.translation, items) }
                        .onEnded { _ in end("Move Group") })
            Color.clear
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                        .onChanged { resizeGroup(group, $0.translation) }
                        .onEnded { _ in end("Resize Group") })
        }
        .frame(width: group.frame.width, height: group.frame.height)
        .allowsHitTesting(!editor.isReadOnly)
        .contextMenu {
            GroupMenu(group: group, editor: editor)
        }
        .offset(x: group.frame.minX, y: group.frame.minY)
    }

    private func moveGroup(_ group: GraphGroup, _ t: CGSize, _ items: [Item]) {
        if before == nil {
            before = editor.snapshot
            let inside = items.filter { group.frame.contains($0.layout.bounds) && !$0.node.pinned }
            groupBase = (group.frame, Dictionary(uniqueKeysWithValues: inside.map { ($0.node.id, $0.node.position) }))
        }
        guard let base = groupBase else { return }
        let d = CGSize(width: t.width / scale, height: t.height / scale)
        editor.live { g in
            if let i = g.groups.firstIndex(where: { $0.id == group.id }) {
                g.groups[i].frame.origin = CGPoint(x: base.frame.minX + d.width, y: base.frame.minY + d.height)
            }
            for i in g.nodes.indices {
                guard let p = base.nodes[g.nodes[i].id] else { continue }
                g.nodes[i].position = CGPoint(x: p.x + d.width, y: p.y + d.height)
            }
        }
    }

    private func resizeGroup(_ group: GraphGroup, _ t: CGSize) {
        if before == nil {
            before = editor.snapshot
            groupBase = (group.frame, [:])
        }
        guard let base = groupBase else { return }
        editor.live { g in
            guard let i = g.groups.firstIndex(where: { $0.id == group.id }) else { return }
            g.groups[i].frame.size = CGSize(
                width: max(140, base.frame.width + t.width / scale),
                height: max(80, base.frame.height + t.height / scale))
        }
    }

    // MARK: - Scrolling (Mac)

    private func installScrollMonitor() {
        #if os(macOS)
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { scrolled(event) } ? nil : event
            }
        #endif
    }

    private func removeScrollMonitor() {
        #if os(macOS)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        #endif
    }

    #if os(macOS)
        /// Trackpad scrolling pans; the mouse wheel, or ⌘ with either, zooms.
        private func scrolled(_ event: NSEvent) -> Bool {
            guard let hover, event.window?.isKeyWindow == true else { return false }
            let zooms = !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command)
            if zooms {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 10
                zoom(to: scale * (1 + delta), around: hover)
            } else {
                offset.x += event.scrollingDeltaX / scale
                offset.y += event.scrollingDeltaY / scale
            }
            persistViewport()
            return true
        }
    #endif
}

/// A group's menu: rename, colour, fit, remove.
private struct GroupMenu: View {
    let group: GraphGroup
    let editor: NodeEditorModel
    @Environment(\.undoManager) private var undo

    var body: some View {
        Menu("Colour") {
            ForEach(
                [("Blue", "#3f789e"), ("Red", "#a1309b"), ("Green", "#8A8"), ("Yellow", "#b58b2a"), ("Gray", "#444")],
                id: \.0
            ) { name, hex in
                Button(name) { edit("Group Colour") { $0.color = hex } }
            }
        }
        Button("Remove Group", systemImage: "rectangle.badge.minus", role: .destructive) {
            editor.change("Remove Group", undo: undo) { g in g.groups.removeAll { $0.id == group.id } }
        }
    }

    private func edit(_ name: String, _ body: @escaping (inout GraphGroup) -> Void) {
        editor.change(name, undo: undo) { g in
            if let i = g.groups.firstIndex(where: { $0.id == group.id }) { body(&g.groups[i]) }
        }
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

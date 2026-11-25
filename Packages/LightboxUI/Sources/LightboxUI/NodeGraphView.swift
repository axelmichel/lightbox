import ComfyKit
import SwiftUI

/// The graph the Generate form would send, drawn as ComfyUI shows it. It
/// follows every change in the form; nothing can be changed here yet.
struct NodeGraphView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PanelKeys.generate) private var showGenerate = true
    @AppStorage(PanelKeys.nodes) private var showNodes = false

    var body: some View {
        Group {
            switch app.generation.graph(app) {
            case .success(let state):
                NodeCanvas(state: state, catalog: app.catalog)
            case .failure(let problem):
                ContentUnavailableView(
                    "No Graph", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(problem.message))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    /// Like the gallery's bar, with the way back to it.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Nodes").font(.headline)
            Text("What Generate sends").foregroundStyle(.secondary)
            Spacer()
            Button("Show the Gallery", systemImage: "photo.on.rectangle.angled") { showNodes = false }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
            if !showGenerate {
                // Where the Generate panel's own button was, at the same height.
                PanelButton(title: "Show the Generate panel", systemImage: "sidebar.trailing") { showGenerate = true }
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: PanelHeader.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A document's nodes and links. Drag the background to move it, pinch
/// (or on the Mac, scroll the wheel) to zoom. Until then all of it is in view.
struct NodeCanvas: View {
    let state: GenerationModel.GraphState
    let catalog: ComfyCatalog

    /// `nil`: fitted to the view.
    @State private var viewport: NodeViewport?
    @State private var panStart: NodeViewport?
    @State private var zoomStart: NodeViewport?

    private var doc: WorkflowDocument { state.doc }

    var body: some View {
        let layouts = Dictionary(
            doc.graph.nodes.map { ($0.id, NodeLayout($0, spec: catalog.nodes[$0.type])) },
            uniquingKeysWith: { a, _ in a })
        let roles = doc.roles
        let bounds = layouts.values.reduce(CGRect.null) { $0.union($1.bounds) }
        GeometryReader { geometry in
            let size = geometry.size
            let shown = viewport ?? NodeViewport.fit(bounds, in: size)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(NodeColors.canvas))
                context.translateBy(x: shown.offset.x, y: shown.offset.y)
                context.scaleBy(x: shown.scale, y: shown.scale)
                // Only what is in view.
                let seen = CGRect(
                    origin: shown.toCanvas(.zero),
                    size: CGSize(width: size.width / shown.scale, height: size.height / shown.scale))
                for link in doc.graph.links { draw(link, layouts, in: context) }
                for node in doc.graph.nodes {
                    guard let layout = layouts[node.id], layout.bounds.intersects(seen) else { continue }
                    draw(node, layout, role: roles[node.id], in: context)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let start = panStart ?? shown
                        panStart = start
                        viewport = start.panned(by: value.translation)
                    }
                    .onEnded { _ in panStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = zoomStart ?? shown
                        zoomStart = start
                        viewport = start.zoomed(by: value.magnification, around: value.startLocation)
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            #if os(macOS)
                .background {
                    ScrollCatcher { scroll in
                        let current = viewport ?? NodeViewport.fit(bounds, in: size)
                        if scroll.isPrecise && !scroll.command {
                            // Trackpad: two fingers move the canvas.
                            viewport = current.panned(by: scroll.delta)
                        } else {
                            // Wheel notches (or ⌘ + trackpad) zoom under the pointer.
                            let amount = scroll.isPrecise ? scroll.delta.height / 100 : scroll.delta.height / 10
                            viewport = current.zoomed(by: pow(2, amount), around: scroll.location)
                        }
                    }
                }
            #endif
            .overlay(alignment: .bottomTrailing) { controls(shown, size: size) }
        }
    }

    private func controls(_ shown: NodeViewport, size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 2) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                viewport = shown.zoomed(by: 1 / 1.25, around: center)
            }
            Text(shown.scale.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().frame(minWidth: 44)
            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                viewport = shown.zoomed(by: 1.25, around: center)
            }
            Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") { viewport = nil }
                .help("Show the whole graph")
                .disabled(viewport == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private func draw(_ link: GraphLink, _ layouts: [Int: NodeLayout], in context: GraphicsContext) {
        guard let from = layouts[link.origin]?.outputPoints, from.indices.contains(link.originSlot),
            let to = layouts[link.target]?.inputPoints, to.indices.contains(link.targetSlot)
        else { return }
        let (a, b) = (from[link.originSlot], to[link.targetSlot])
        // LiteGraph's curve: handles a quarter of the distance long, level.
        let handle = hypot(b.x - a.x, b.y - a.y) * 0.25
        var path = Path()
        path.move(to: a)
        path.addCurve(
            to: b, control1: CGPoint(x: a.x + handle, y: a.y), control2: CGPoint(x: b.x - handle, y: b.y))
        context.stroke(path, with: .color(NodeColors.type(link.type)), lineWidth: 3)
    }

    private func draw(_ node: GraphNode, _ layout: NodeLayout, role: NodeRole?, in context: GraphicsContext) {
        let corner = 8.0
        context.fill(Path(roundedRect: layout.bounds, cornerRadius: corner), with: .color(NodeColors.body))
        let title = UnevenRoundedRectangle(
            topLeadingRadius: corner, bottomLeadingRadius: node.collapsed ? corner : 0,
            bottomTrailingRadius: node.collapsed ? corner : 0, topTrailingRadius: corner)
        context.fill(title.path(in: layout.titleRect), with: .color(NodeColors.title))
        let name = node.title ?? catalog.nodes[node.type]?.displayName ?? node.type
        context.draw(
            Text(name).font(.system(size: 14)).foregroundStyle(NodeColors.text),
            at: CGPoint(x: layout.titleRect.minX + 12, y: layout.titleRect.midY), anchor: .leading)
        guard !node.collapsed else { return }

        let spec = catalog.nodes[node.type]
        for row in layout.rows { draw(row, of: node, spec: spec, role: role, in: context) }
        // Sockets of widgets show only when something is linked in.
        let rowNames = Set(layout.rows.map(\.name))
        for (i, input) in node.inputs.enumerated() where i < layout.inputPoints.count {
            let onRow = rowNames.contains(input.widget ?? input.name)
            if onRow && input.link == nil { continue }
            socket(layout.inputPoints[i], type: input.type, linked: input.link != nil, in: context)
            if !onRow {
                context.draw(
                    Text(input.label ?? input.name).font(.system(size: 11)).foregroundStyle(NodeColors.label),
                    at: CGPoint(x: layout.inputPoints[i].x + 10, y: layout.inputPoints[i].y), anchor: .leading)
            }
        }
        for (i, output) in node.outputs.enumerated() where i < layout.outputPoints.count {
            socket(layout.outputPoints[i], type: output.type, linked: !output.links.isEmpty, in: context)
            context.draw(
                Text(output.label ?? output.name).font(.system(size: 11)).foregroundStyle(NodeColors.label),
                at: CGPoint(x: layout.outputPoints[i].x - 10, y: layout.outputPoints[i].y), anchor: .trailing)
        }
    }

    private func draw(
        _ row: NodeLayout.Row, of node: GraphNode, spec: NodeSpec?, role: NodeRole?, in context: GraphicsContext
    ) {
        let rect = row.rect.insetBy(dx: 12, dy: 0)
        context.fill(
            Path(roundedRect: rect, cornerRadius: row.multiline ? 6 : rect.height / 2), with: .color(NodeColors.widget))
        let locked = row.kind == .value && NodeRowText.isLocked(role, input: row.name)
        let inset = rect.insetBy(dx: 10, dy: 0)
        if locked {
            var lock = context.resolve(Image(systemName: "lock.fill"))
            lock.shading = .color(NodeColors.label)
            let at = row.multiline ? CGPoint(x: inset.maxX, y: rect.minY + 10) : CGPoint(x: inset.maxX, y: rect.midY)
            context.draw(lock, in: CGRect(x: at.x - 9, y: at.y - 5, width: 9, height: 10))
        }
        let name = row.kind == .control ? "control after generate" : row.name
        let value: String
        if row.kind == .control {
            value = node.controlValue(row.name, spec: spec) ?? "—"
        } else if state.randomSeed && ["seed", "noise_seed"].contains(row.name) {
            value = "random"
        } else {
            value = NodeRowText.value(node.widgetValue(row.name, spec: spec))
        }
        let small = Font.system(size: 11)
        if row.multiline {
            context.draw(
                Text(name).font(small).foregroundStyle(NodeColors.label),
                at: CGPoint(x: inset.minX, y: rect.minY + 10), anchor: .leading)
            // The composed prompt, or why the guard refused it.
            let refused = state.refusal.flatMap { role?.kind == .positive ? $0 : nil }
            let text = Text(refused ?? (value.isEmpty ? "—" : value)).font(small)
                .foregroundStyle(refused == nil ? NodeColors.text : NodeColors.error)
            context.draw(
                text, in: CGRect(x: inset.minX, y: rect.minY + 20, width: inset.width, height: rect.height - 24))
        } else {
            // ComfyUI's row: the name on the left, the value on the right.
            let room = inset.width - (locked ? 14 : 0)
            let label = Self.fitted(name, width: room * 0.45, font: small, in: context)
            context.draw(
                Text(label).font(small).foregroundStyle(NodeColors.label),
                at: CGPoint(x: inset.minX, y: rect.midY), anchor: .leading)
            let shown = Self.fitted(value, width: room * 0.55 - 6, font: small, in: context)
            context.draw(
                Text(shown).font(small).foregroundStyle(NodeColors.text),
                at: CGPoint(x: inset.minX + room, y: rect.midY), anchor: .trailing)
        }
    }

    /// `text` shortened in the middle ("checkpo…v1.safetensors") to fit.
    static func fitted(_ text: String, width: Double, font: Font, in context: GraphicsContext) -> String {
        func fits(_ s: String) -> Bool {
            // No letter of the 11-point font is wider than 11 points: short texts need no measuring.
            if Double(s.count) * 11 <= width { return true }
            return context.resolve(Text(s).font(font)).measure(in: CGSize(width: CGFloat.infinity, height: 100)).width
                <= width
        }
        guard !fits(text) else { return text }
        func cut(_ keep: Int) -> String {
            let head = keep - keep / 2
            return String(text.prefix(head)) + "…" + String(text.suffix(keep / 2))
        }
        var (low, high) = (0, text.count - 1)
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(cut(mid)) { low = mid } else { high = mid - 1 }
        }
        return cut(low)
    }

    private func socket(_ p: CGPoint, type: String, linked: Bool, in context: GraphicsContext) {
        let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        if linked {
            context.fill(dot, with: .color(NodeColors.type(type)))
        } else {
            context.stroke(dot, with: .color(NodeColors.type(type)), lineWidth: 1.5)
        }
    }
}

/// ComfyUI's dark theme.
enum NodeColors {
    static let canvas = Color(hex: 0x202020)
    static let body = Color(hex: 0x353535)
    static let title = Color(hex: 0x222222)
    static let text = Color(hex: 0xdddddd)
    static let label = Color(hex: 0xaaaaaa)
    static let widget = Color(hex: 0x222222)
    static let error = Color(hex: 0xFF6E6E)

    /// ComfyUI's colours for link types.
    static func type(_ type: String) -> Color {
        switch type.split(separator: ",").first.map(String.init) ?? type {
        case "CLIP": Color(hex: 0xFFD500)
        case "CLIP_VISION": Color(hex: 0xA8DADC)
        case "CLIP_VISION_OUTPUT": Color(hex: 0xAD7452)
        case "CONDITIONING": Color(hex: 0xFFA931)
        case "CONTROL_NET": Color(hex: 0x6EE7B7)
        case "IMAGE": Color(hex: 0x64B5F6)
        case "LATENT": Color(hex: 0xFF9CF9)
        case "MASK": Color(hex: 0x81C784)
        case "MODEL": Color(hex: 0xB39DDB)
        case "VAE": Color(hex: 0xFF6E6E)
        case "NOISE": Color(hex: 0xB0B0B0)
        case "GUIDER": Color(hex: 0x66FFFF)
        case "SAMPLER": Color(hex: 0xECB4B4)
        case "SIGMAS": Color(hex: 0xCDFFCD)
        case "INT", "FLOAT", "BOOLEAN": Color(hex: 0x7F9FBF)
        case "STRING": Color(hex: 0x77BB77)
        default: Color(hex: 0x99AA99)
        }
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}

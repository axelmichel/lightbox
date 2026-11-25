import ComfyKit
import SwiftUI

/// The graph the Generate form would send, drawn as ComfyUI shows it. It
/// follows every change in the form; nothing can be changed here yet.
struct NodeGraphView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.generation.graph(app) {
        case .success(let doc):
            NodeCanvas(doc: doc, catalog: app.catalog)
        case .failure(let problem):
            ContentUnavailableView(
                "No Graph", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text(problem.message))
        }
    }
}

/// A document's nodes and links, scaled so all of it is in view.
struct NodeCanvas: View {
    let doc: WorkflowDocument
    let catalog: ComfyCatalog

    static let margin = 24.0

    var body: some View {
        let layouts = Dictionary(
            doc.graph.nodes.map { ($0.id, NodeLayout($0, spec: catalog.nodes[$0.type])) },
            uniquingKeysWith: { a, _ in a })
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(NodeColors.canvas))
            let bounds = layouts.values.reduce(CGRect.null) { $0.union($1.bounds) }
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(
                (size.width - 2 * Self.margin) / bounds.width, (size.height - 2 * Self.margin) / bounds.height, 1)
            guard scale > 0 else { return }
            context.translateBy(
                x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            context.scaleBy(x: scale, y: scale)
            for link in doc.graph.links { draw(link, layouts, in: context) }
            for node in doc.graph.nodes {
                if let layout = layouts[node.id] { draw(node, layout, in: context) }
            }
        }
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

    private func draw(_ node: GraphNode, _ layout: NodeLayout, in context: GraphicsContext) {
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

        for row in layout.rows where row.kind == .value {
            let rect = row.rect.insetBy(dx: 12, dy: 0)
            context.fill(
                Path(roundedRect: rect, cornerRadius: row.multiline ? 6 : rect.height / 2),
                with: .color(NodeColors.widget))
            context.draw(
                Text(row.name).font(.system(size: 11)).foregroundStyle(NodeColors.label),
                at: CGPoint(x: rect.minX + 10, y: row.multiline ? rect.minY + 10 : rect.midY), anchor: .leading)
        }
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

import ComfyKit
import CoreGraphics
import SwiftUI

/// Where things are on a node, in canvas units. Uses LiteGraph's metrics,
/// so workflows look as they do in ComfyUI: a node's `pos` is the top left
/// of its body; the title bar sits above it.
struct NodeLayout {
    static let title = 30.0
    static let slot = 20.0
    static let widget = 24.0
    static let multiline = 80.0
    static let image = 160.0

    enum Row {
        case widget(name: String, input: Int?, multiline: Bool)
        /// Pictures (Load Image's, or what an output node made).
        case images
    }

    let frame: CGRect
    let titleRect: CGRect
    /// By input index; `nil` for inputs drawn in no row (hidden).
    let inputPoints: [CGPoint?]
    let outputPoints: [CGPoint]
    let rows: [(row: Row, rect: CGRect)]
    /// The smallest height that fits the slots and widgets.
    let minHeight: Double

    /// The whole node, title included.
    var bounds: CGRect { frame.union(titleRect) }

    init(_ node: GraphNode, kind: NodeKind, showsImages: Bool) {
        let x = node.position.x
        let y = node.position.y
        let width = max(node.size.width, node.type == "Reroute" ? 75 : 140)
        titleRect = CGRect(x: x, y: y - Self.title, width: width, height: Self.title)
        if node.collapsed || node.type == "Reroute" {
            let mid = node.type == "Reroute" ? y - Self.title / 2 : y - Self.title / 2
            frame = CGRect(x: x, y: y, width: width, height: 0)
            inputPoints = node.inputs.map { _ in CGPoint(x: x, y: mid) }
            outputPoints = node.outputs.map { _ in CGPoint(x: x + width, y: mid) }
            rows = []
            minHeight = 0
            return
        }
        // Sockets without a widget, beside the outputs.
        let socketInputs = node.inputs.indices.filter { kind.widgetName(for: node.inputs[$0]) == nil }
        let slotRows = max(socketInputs.count, node.outputs.count)
        var points = [CGPoint?](repeating: nil, count: node.inputs.count)
        for (row, i) in socketInputs.enumerated() {
            points[i] = CGPoint(x: x, y: y + Self.slot * (Double(row) + 0.5) + 4)
        }
        let outputs = node.outputs.indices.map { CGPoint(x: x + width, y: y + Self.slot * (Double($0) + 0.5) + 4) }
        var top = y + Double(slotRows) * Self.slot + 8
        var rows: [(Row, CGRect)] = []
        let widgets = kind.widgets
        let fixed = widgets.filter { !$0.multiline }.count
        let multilineCount = widgets.filter(\.multiline).count
        let images = showsImages || kind.showsImageWidget
        let needed =
            top - y + Double(fixed) * Self.widget + Double(multilineCount) * Self.multiline + (images ? Self.image : 0)
            + 6
        let height = max(node.size.height, needed)
        // Multiline boxes share what is left over.
        let spare = height - needed
        let extra = multilineCount > 0 && !images ? spare / Double(multilineCount) : 0
        for w in widgets {
            let h = w.multiline ? Self.multiline + extra : Self.widget
            let input = node.inputs.firstIndex { kind.widgetName(for: $0) == w.name }
            let rect = CGRect(x: x, y: top, width: width, height: h)
            rows.append((.widget(name: w.name, input: input, multiline: w.multiline), rect))
            if let input { points[input] = CGPoint(x: x, y: top + Self.widget / 2 - 2) }
            top += h
        }
        if images {
            rows.append((.images, CGRect(x: x, y: top, width: width, height: max(Self.image, y + height - top - 6))))
        }
        frame = CGRect(x: x, y: y, width: width, height: height)
        inputPoints = points
        outputPoints = outputs
        self.rows = rows
        minHeight = needed
    }
}

/// What a node is in the editor: its widgets and how it is drawn.
struct NodeKind {
    struct Widget {
        var name: String
        var spec: InputSpec
        var multiline: Bool
    }

    enum Role {
        case regular(NodeSpec)
        /// Not on the server.
        case missing
        case note
        case reroute
        /// A primitive node: its one widget is typed like the input it feeds.
        case primitive(InputSpec?)
        case subgraph(SubgraphDefinition)
    }

    let role: Role
    let widgets: [Widget]

    init(_ node: GraphNode, doc: WorkflowDocument, graph: NodeGraph, catalog: ComfyCatalog) {
        switch node.type {
        case "Note", "MarkdownNote":
            role = .note
            widgets = [Widget(name: "text", spec: InputSpec(type: "STRING", options: []), multiline: true)]
            return
        case "Reroute":
            role = .reroute
            widgets = []
            return
        case "PrimitiveNode":
            // The spec of the first input it is linked to.
            let target = node.outputs.first?.links.first.flatMap { graph.link($0) }
            let spec = target.flatMap { l -> InputSpec? in
                guard let t = graph.node(l.target), t.inputs.indices.contains(l.targetSlot) else { return nil }
                let input = t.inputs[l.targetSlot]
                return catalog.nodes[t.type]?.inputs[input.widget ?? input.name]
            }
            role = .primitive(spec)
            widgets = spec.map { [Widget(name: "value", spec: $0, multiline: $0.multiline)] } ?? []
            return
        default: break
        }
        if let def = doc.subgraph(node.type) {
            role = .subgraph(def)
            widgets = []
        } else if let spec = catalog.nodes[node.type] {
            role = .regular(spec)
            widgets = WidgetLayout.widgets(spec).compactMap { w in
                guard w.kind == .value, let s = w.spec else { return nil }
                return Widget(name: w.name, spec: s, multiline: s.multiline && s.type == "STRING")
            }
        } else {
            role = .missing
            widgets = []
        }
    }

    var spec: NodeSpec? {
        if case .regular(let s) = role { s } else { nil }
    }

    /// The widget an input belongs to, if it is a widget's socket.
    func widgetName(for input: NodeInputSlot) -> String? {
        guard let name = input.widget, widgets.contains(where: { $0.name == name }) else { return nil }
        return name
    }

    var showsImageWidget: Bool {
        spec?.inputs.values.contains { $0.imageUpload } == true
    }
}

// MARK: - Colours

enum NodeColors {
    static let canvas = Color(hex: "#202020")
    static let grid = Color(hex: "#2a2a2a")
    static let body = Color(hex: "#353535")
    static let title = Color(hex: "#222222")
    static let text = Color(hex: "#dddddd")
    static let widget = Color(hex: "#222222")
    static let selection = Color(hex: "#ffffff")
    static let running = Color(hex: "#00ff00")
    static let error = Color(hex: "#ff4444")
    static let bypass = Color(hex: "#9f40ff")

    /// ComfyUI's colours for link types.
    static func type(_ type: String) -> Color {
        switch type.split(separator: ",").first.map(String.init) ?? type {
        case "CLIP": Color(hex: "#FFD500")
        case "CLIP_VISION": Color(hex: "#A8DADC")
        case "CLIP_VISION_OUTPUT": Color(hex: "#ad7452")
        case "CONDITIONING": Color(hex: "#FFA931")
        case "CONTROL_NET": Color(hex: "#6EE7B7")
        case "IMAGE": Color(hex: "#64B5F6")
        case "LATENT": Color(hex: "#FF9CF9")
        case "MASK": Color(hex: "#81C784")
        case "MODEL": Color(hex: "#B39DDB")
        case "STYLE_MODEL": Color(hex: "#C2FFAE")
        case "VAE": Color(hex: "#FF6E6E")
        case "NOISE": Color(hex: "#B0B0B0")
        case "GUIDER": Color(hex: "#66FFFF")
        case "SAMPLER": Color(hex: "#ECB4B4")
        case "SIGMAS": Color(hex: "#CDFFCD")
        case "TAESD": Color(hex: "#DCC274")
        case "INT", "FLOAT", "BOOLEAN": Color(hex: "#7F9FBF")
        case "STRING": Color(hex: "#77BB77")
        default: Color(hex: "#99AA99")
        }
    }

    /// The colours ComfyUI offers in a node's menu: (name, title, body).
    static let palette: [(String, String, String)] = [
        ("Red", "#322", "#533"), ("Brown", "#332922", "#593930"), ("Green", "#232", "#353"),
        ("Blue", "#223", "#335"), ("Pale Blue", "#2a363b", "#3f5159"), ("Cyan", "#233", "#355"),
        ("Purple", "#323", "#535"), ("Yellow", "#432", "#653"), ("Black", "#222", "#000"),
    ]
}

extension Color {
    /// "#rgb", "#rrggbb" or "#rrggbbaa"; gray for anything else.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else {
            self = .gray
            return
        }
        let a = s.count == 8 ? Double(v & 0xff) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        self = Color(
            .sRGB, red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255, opacity: a)
    }
}

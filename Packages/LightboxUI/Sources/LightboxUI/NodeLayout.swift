import ComfyKit
import CoreGraphics

/// Where things are on a node in the node editor, in canvas units. Uses
/// LiteGraph's metrics so workflows look as they do in ComfyUI: a node's
/// `position` is the top left of its body; the title bar sits above it.
/// The sockets of inputs without a widget and the outputs share the rows
/// under the title; the widgets follow, one row each.
struct NodeLayout: Equatable {
    static let title = 30.0
    static let slot = 20.0
    static let widget = 20.0
    /// Space between widget rows.
    static let widgetGap = 4.0
    static let multiline = 80.0
    static let minWidth = 140.0
    /// How far a socket sits in from the node's edge, and how near a point
    /// must be to count as on it.
    static let socketInset = slot / 2
    static let socketRadius = slot / 2

    struct Row: Equatable {
        enum Kind: Equatable {
            case value
            /// The seed's control (fixed, randomize, …).
            case control
        }

        /// The input the widget sets.
        var name: String
        var kind: Kind
        var multiline: Bool
        var rect: CGRect
    }

    enum Hit: Equatable {
        case input(Int)
        case output(Int)
        case widget(String)
        case title
        case body
    }

    /// The body, without the title.
    let frame: CGRect
    let titleRect: CGRect
    /// By input index.
    let inputPoints: [CGPoint]
    let outputPoints: [CGPoint]
    let rows: [Row]
    /// The smallest height of the body that fits the sockets and widgets.
    let minHeight: Double

    /// The whole node, title included.
    var bounds: CGRect { frame.union(titleRect) }

    /// `spec` is the node's definition on the server; without one (a node
    /// it doesn't have) every input is a socket and there are no widgets.
    init(_ node: GraphNode, spec: NodeSpec?) {
        let (x, y) = (node.position.x, node.position.y)
        let width = max(node.size.width, Self.minWidth)
        titleRect = CGRect(x: x, y: y - Self.title, width: width, height: Self.title)
        if node.collapsed {
            // Links meet in the middle of the title's ends.
            let mid = y - Self.title / 2
            frame = CGRect(x: x, y: y, width: width, height: 0)
            inputPoints = node.inputs.map { _ in CGPoint(x: x, y: mid) }
            outputPoints = node.outputs.map { _ in CGPoint(x: x + width, y: mid) }
            rows = []
            minHeight = 0
            return
        }

        let widgets =
            spec.map { s in
                WidgetLayout.widgets(s).compactMap { w -> (String, Row.Kind, Bool)? in
                    switch w.kind {
                    case .value: (w.name, .value, w.spec?.multiline == true && w.spec?.type == "STRING")
                    case .control: (w.name, .control, false)
                    case .upload: nil
                    }
                }
            } ?? []
        let widgetNames = Set(widgets.map(\.0))
        func hasWidget(_ input: NodeInputSlot) -> Bool { widgetNames.contains(input.widget ?? input.name) }

        let sockets = node.inputs.indices.filter { !hasWidget(node.inputs[$0]) }
        let slotRows = max(sockets.count, node.outputs.count)
        func slotY(_ row: Int) -> Double { y + (Double(row) + 0.7) * Self.slot }

        var top = y + Double(slotRows) * Self.slot + Self.widgetGap
        let fixed = widgets.filter { !$0.2 }.count
        let multilineCount = widgets.count - fixed
        let needed =
            top - y + Double(fixed) * (Self.widget + Self.widgetGap)
            + Double(multilineCount) * (Self.multiline + Self.widgetGap) + Self.widgetGap
        let height = max(node.size.height, needed)
        // Text boxes share the room left over.
        let extra = multilineCount > 0 ? (height - needed) / Double(multilineCount) : 0

        var rows: [Row] = []
        for (name, kind, multiline) in widgets {
            let h = multiline ? Self.multiline + extra : Self.widget
            rows.append(
                Row(name: name, kind: kind, multiline: multiline, rect: CGRect(x: x, y: top, width: width, height: h)))
            top += h + Self.widgetGap
        }

        var points = [CGPoint](repeating: .zero, count: node.inputs.count)
        for (row, i) in sockets.enumerated() { points[i] = CGPoint(x: x + Self.socketInset, y: slotY(row)) }
        for i in node.inputs.indices where hasWidget(node.inputs[i]) {
            // A widget's socket sits at the start of its row.
            let name = node.inputs[i].widget ?? node.inputs[i].name
            let rect = rows.first { $0.name == name && $0.kind == .value }?.rect ?? .zero
            points[i] = CGPoint(x: x + Self.socketInset, y: rect.minY + Self.widget / 2)
        }
        inputPoints = points
        outputPoints = node.outputs.indices.map { CGPoint(x: x + width - Self.socketInset, y: slotY($0)) }
        frame = CGRect(x: x, y: y, width: width, height: height)
        self.rows = rows
        minHeight = needed
    }

    /// What is at `point`. Sockets come first: they reach a little past the
    /// rows they sit on.
    func hit(_ point: CGPoint) -> Hit? {
        func near(_ p: CGPoint) -> Bool { hypot(p.x - point.x, p.y - point.y) <= Self.socketRadius }
        if let i = outputPoints.firstIndex(where: near) { return .output(i) }
        if let i = inputPoints.firstIndex(where: near) { return .input(i) }
        if titleRect.contains(point) { return .title }
        if let row = rows.first(where: { $0.rect.contains(point) }) { return .widget(row.name) }
        return frame.contains(point) ? .body : nil
    }
}

// An API-format workflow ("Export (API)", or the prompt embedded in a
// picture) has no positions, sizes or slot lists. This makes a UI-format
// document of it: slots from `/object_info`, columns by how far a node is
// from the loaders.

import CoreGraphics
import Foundation

extension WorkflowDocument {
    /// Read an API-format file: {"<id>": {"class_type", "inputs"}}.
    public init(api data: Data, catalog: ComfyCatalog) throws(WorkflowDocumentError) {
        guard let json = JSONValue.parse(data) else { throw .notJSON }
        guard var root = json.object else { throw .notAWorkflow }
        if let inner = root["prompt"]?.object, root["class_type"] == nil { root = inner }
        let entries = root.compactMap { id, v -> (String, String, [String: JSONValue])? in
            guard let type = v["class_type"]?.string else { return nil }
            return (id, type, v["inputs"]?.object ?? [:])
        }
        guard !entries.isEmpty else { throw .notAWorkflow }
        self.init()
        // Ids may be "5:3"; number them anew in their order.
        let order = entries.map(\.0).sorted { a, b in
            let x = a.split(separator: ":").compactMap { Int($0) }
            let y = b.split(separator: ":").compactMap { Int($0) }
            return x.lexicographicallyPrecedes(y)
        }
        var number: [String: Int] = [:]
        for (i, id) in order.enumerated() { number[id] = Int(id) ?? (1000 + i) }
        if Set(number.values).count != number.count {
            for (i, id) in order.enumerated() { number[id] = i + 1 }
        }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0) })
        var g = NodeGraph()
        g.lastNodeID = number.values.max() ?? 0
        for id in order {
            guard let (_, type, inputs) = byID[id] else { continue }
            var n = GraphNode(id: number[id]!, type: type)
            n.properties["Node name for S&R"] = .string(type)
            if let spec = catalog.nodes[type] {
                for name in spec.inputOrder {
                    guard let input = spec.inputs[name] else { continue }
                    n.inputs.append(NodeInputSlot(name: name, type: input.type, widget: input.isWidget ? name : nil))
                }
                n.outputs = spec.outputs.map { NodeOutputSlot(name: $0.name, type: $0.type) }
                var values: [JSONValue] = []
                for w in WidgetLayout.widgets(spec) {
                    switch w.kind {
                    case .value:
                        let v = inputs[w.name].flatMap { Self.isLink($0) ? nil : $0 }
                        values.append(v ?? w.spec.map(WidgetLayout.defaultValue) ?? .null)
                    // The API format has no seed controls: keep the seed.
                    case .control: values.append(.string("fixed"))
                    case .upload: values.append(.string("image"))
                    }
                }
                if !values.isEmpty { n.widgetsValues = .array(values) }
            } else {
                // Not on this server: sockets for what is linked, the rest as values by name.
                var named: [String: JSONValue] = [:]
                for (name, v) in inputs.sorted(by: { $0.key < $1.key }) {
                    if Self.isLink(v) { n.inputs.append(NodeInputSlot(name: name, type: "*")) } else { named[name] = v }
                }
                if !named.isEmpty { n.widgetsValues = .object(named) }
            }
            g.nodes.append(n)
        }
        // Links. Unknown nodes get output slots as far as they are used.
        for id in order {
            guard let (_, _, inputs) = byID[id], let target = g.index(of: number[id]!) else { continue }
            for (name, v) in inputs.sorted(by: { $0.key < $1.key }) {
                guard Self.isLink(v), let a = v.array, let from = a[0].string ?? a[0].int.map(String.init),
                    let fromID = number[from], let slot = a[1].int, let o = g.index(of: fromID)
                else { continue }
                while g.nodes[o].outputs.count <= slot {
                    g.nodes[o].outputs.append(NodeOutputSlot(name: "*", type: "*"))
                }
                if !g.nodes[target].inputs.contains(where: { $0.name == name }) {
                    g.nodes[target].inputs.append(NodeInputSlot(name: name, type: g.nodes[o].outputs[slot].type))
                }
                let t = g.nodes[target].inputs.firstIndex { $0.name == name }!
                g.connect(from: fromID, slot, to: g.nodes[target].id, t)
            }
        }
        Self.layOut(&g, catalog: catalog)
        graph = g
    }

    static func isLink(_ v: JSONValue) -> Bool {
        guard let a = v.array, a.count == 2, a[1].int != nil else { return false }
        return a[0].string != nil || a[0].int != nil
    }

    /// Columns by distance from the nodes with nothing linked in.
    static func layOut(_ g: inout NodeGraph, catalog: ComfyCatalog) {
        var depth: [Int: Int] = [:]
        func depthOf(_ id: Int, _ seen: Set<Int>) -> Int {
            if let d = depth[id] { return d }
            guard let n = g.node(id), !seen.contains(id) else { return 0 }
            let parents = n.inputs.compactMap { $0.link.flatMap { g.link($0)?.origin } }
            let d = parents.map { depthOf($0, seen.union([id])) + 1 }.max() ?? 0
            depth[id] = d
            return d
        }
        var y: [Int: Double] = [:]
        for i in g.nodes.indices {
            let d = depthOf(g.nodes[i].id, [])
            let spec = catalog.nodes[g.nodes[i].type]
            let widgets = spec.map { WidgetLayout.widgets($0).filter { $0.kind != .upload }.count } ?? 0
            let rows = max(g.nodes[i].outputs.count, g.nodes[i].inputs.filter { $0.widget == nil }.count) + widgets
            let multiline = spec?.inputs.values.contains { $0.multiline } == true
            let height = 30 + Double(rows) * 24 + (multiline ? 120 : 10)
            g.nodes[i].size = CGSize(width: multiline ? 400 : 320, height: height)
            g.nodes[i].position = CGPoint(x: Double(d) * 440, y: y[d, default: 0])
            y[d, default: 0] += height + 60
        }
    }
}

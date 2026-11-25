// Changes the node editor makes to a graph. Links are stored twice in the
// format (the link list, and each slot's `link` / `links`); these keep both
// in step.

import CoreGraphics
import Foundation

extension NodeGraph {
    /// Add a node of a kind the server offers, with its default values.
    @discardableResult
    public mutating func addNode(_ type: String, spec: NodeSpec, at position: CGPoint) -> Int {
        lastNodeID += 1
        var n = GraphNode(id: lastNodeID, type: type, position: position)
        for name in spec.inputOrder {
            guard let input = spec.inputs[name] else { continue }
            // Like the current frontend, every widget is also a socket.
            n.inputs.append(NodeInputSlot(name: name, type: input.type, widget: input.isWidget ? name : nil))
        }
        n.outputs = spec.outputs.map { NodeOutputSlot(name: $0.name, type: $0.type) }
        if !WidgetLayout.widgets(spec).isEmpty { n.widgetsValues = .array(WidgetLayout.defaults(spec)) }
        n.properties["Node name for S&R"] = .string(type)
        nodes.append(n)
        return n.id
    }

    /// Add a node that isn't on the server (Note, Reroute, PrimitiveNode).
    @discardableResult
    public mutating func addNode(_ node: GraphNode) -> Int {
        var n = node
        lastNodeID += 1
        n.id = lastNodeID
        nodes.append(n)
        return n.id
    }

    /// Whether an output of type `from` can go into an input of type `to`.
    public static func accepts(_ to: String, from: String) -> Bool {
        if to == "*" || from == "*" || to.isEmpty || from.isEmpty { return true }
        // "IMAGE,MASK" lists several types.
        let a = Set(to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let b = Set(from.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return !a.isDisjoint(with: b)
    }

    /// Link an output to an input; replaces what was linked to the input.
    /// Returns nil if the types don't fit or it would link a node to itself.
    @discardableResult
    public mutating func connect(from origin: Int, _ originSlot: Int, to target: Int, _ targetSlot: Int) -> Int? {
        guard origin != target, let o = index(of: origin), let t = index(of: target),
            nodes[o].outputs.indices.contains(originSlot), nodes[t].inputs.indices.contains(targetSlot)
        else { return nil }
        let type = nodes[o].outputs[originSlot].type
        guard Self.accepts(nodes[t].inputs[targetSlot].type, from: type) else { return nil }
        disconnect(input: target, targetSlot)
        lastLinkID += 1
        let id = lastLinkID
        links.append(
            GraphLink(
                id: id, origin: origin, originSlot: originSlot, target: target, targetSlot: targetSlot, type: type))
        nodes[o].outputs[originSlot].links.append(id)
        nodes[t].inputs[targetSlot].link = id
        return id
    }

    /// Remove the link going into an input.
    public mutating func disconnect(input target: Int, _ slot: Int) {
        guard let t = index(of: target), nodes[t].inputs.indices.contains(slot), let id = nodes[t].inputs[slot].link
        else { return }
        removeLink(id)
    }

    public mutating func removeLink(_ id: Int) {
        guard let link = link(id) else { return }
        links.removeAll { $0.id == id }
        if let o = index(of: link.origin), nodes[o].outputs.indices.contains(link.originSlot) {
            nodes[o].outputs[link.originSlot].links.removeAll { $0 == id }
        }
        if let t = index(of: link.target), nodes[t].inputs.indices.contains(link.targetSlot),
            nodes[t].inputs[link.targetSlot].link == id
        {
            nodes[t].inputs[link.targetSlot].link = nil
        }
        for i in reroutes.indices { reroutes[i].linkIDs.removeAll { $0 == id } }
    }

    /// Remove nodes and their links.
    public mutating func removeNodes(_ ids: Set<Int>) {
        for link in links where ids.contains(link.origin) || ids.contains(link.target) { removeLink(link.id) }
        nodes.removeAll { ids.contains($0.id) }
    }

    /// Copies of `ids` with new ids, moved by `offset`; links between them
    /// are copied too. Returns the new ids.
    @discardableResult
    public mutating func duplicate(_ ids: Set<Int>, from source: NodeGraph? = nil, offset: CGVector) -> [Int] {
        let from = source ?? self
        var newID: [Int: Int] = [:]
        for var n in from.nodes where ids.contains(n.id) {
            let old = n.id
            n.position.x += offset.dx
            n.position.y += offset.dy
            for i in n.inputs.indices { n.inputs[i].link = nil }
            for i in n.outputs.indices { n.outputs[i].links = [] }
            newID[old] = addNode(n)
        }
        for l in from.links {
            guard let o = newID[l.origin], let t = newID[l.target] else { continue }
            connect(from: o, l.originSlot, to: t, l.targetSlot)
        }
        return from.nodes.compactMap { newID[$0.id] }
    }

    /// The nodes whose frame lies inside `rect` (to move a group's nodes with it).
    public func nodes(inside rect: CGRect) -> [Int] {
        nodes.filter { rect.contains(CGPoint(x: $0.frame.midX, y: $0.position.y)) }.map(\.id)
    }
}

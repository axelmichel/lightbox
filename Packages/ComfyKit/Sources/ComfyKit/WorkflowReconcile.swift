// Brings a node-editor document in line with the graph a request needs,
// without touching what the user arranged: nodes are matched by role, keep
// their place, and only get new values; nodes without a role stay as they
// are.

import CoreGraphics
import Foundation

extension WorkflowDocument {
    /// `self` with the managed nodes of `target` (a projection of
    /// `WorkflowBuilder.build`):
    /// - a node whose role is in both keeps its id, place and look, and
    ///   takes the target's widget values; if its kind changed (the negative
    ///   zeroed out), it is replaced in the same place;
    /// - a role only in `target` gets a new node, under the node it is fed by;
    /// - a role only in `self` (a LoRA taken out) loses its node; so do further
    ///   nodes with a role already taken;
    /// - links between managed nodes are made as in `target`, but a link into
    ///   a managed input from a node without a role is the user's and stays.
    public func reconciled(with target: WorkflowDocument) -> WorkflowDocument {
        var doc = self
        var g = doc.graph
        let wanted = Self.roleNodes(target.graph)

        // Managed nodes the target doesn't have, or that repeat a role.
        var current: [NodeRole: Int] = [:]
        var surplus: Set<Int> = []
        for n in g.nodes.sorted(by: { $0.id < $1.id }) {
            guard let role = Self.role(of: n) else { continue }
            if wanted[role] == nil || current[role] != nil { surplus.insert(n.id) } else { current[role] = n.id }
        }
        g.removeNodes(surplus)

        // Nodes, upstream first: the builder adds a node after those it is fed by.
        var mapping: [Int: Int] = [:]
        for t in target.graph.nodes.sorted(by: { $0.id < $1.id }) {
            guard let role = Self.role(of: t) else { continue }
            if let id = current[role], let i = g.index(of: id) {
                if g.nodes[i].type == t.type {
                    g.nodes[i].widgetsValues = t.widgetsValues
                } else {
                    let place = g.nodes[i].position
                    g.removeNodes([id])
                    g.nodes.append(Self.fresh(t, id: id, at: place))
                }
                mapping[t.id] = id
            } else {
                g.lastNodeID += 1
                let place = Self.place(t, in: target.graph, under: mapping, of: g)
                g.nodes.append(Self.fresh(t, id: g.lastNodeID, at: place))
                mapping[t.id] = g.lastNodeID
            }
        }

        // Links between managed nodes, as the target has them.
        struct End: Hashable {
            var node: Int
            var input: String
        }
        var links: [End: (origin: Int, slot: Int)] = [:]
        for l in target.graph.links {
            guard let from = mapping[l.origin], let to = mapping[l.target],
                let input = target.graph.node(l.target)?.inputs[safe: l.targetSlot]?.name
            else { continue }
            links[End(node: to, input: input)] = (from, l.originSlot)
        }
        let managed = Set(mapping.values)
        for l in g.links where managed.contains(l.origin) && managed.contains(l.target) {
            guard let input = g.node(l.target)?.inputs[safe: l.targetSlot]?.name else { continue }
            let want = links[End(node: l.target, input: input)]
            if want?.origin != l.origin || want?.slot != l.originSlot { g.removeLink(l.id) }
        }
        for (end, from) in links.sorted(by: { ($0.key.node, $0.key.input) < ($1.key.node, $1.key.input) }) {
            guard let t = g.index(of: end.node),
                let slot = g.nodes[t].inputs.firstIndex(where: { $0.name == end.input })
            else { continue }
            if let id = g.nodes[t].inputs[slot].link, let link = g.link(id) {
                if link.origin == from.origin && link.originSlot == from.slot { continue }
                // From a node the user added: theirs.
                if !managed.contains(link.origin) { continue }
            }
            g.connect(from: from.origin, from.slot, to: end.node, slot)
        }
        doc.graph = g
        return doc
    }

    static func role(of node: GraphNode) -> NodeRole? {
        node.properties[roleProperty]?.string.flatMap(NodeRole.init)
    }

    static func roleNodes(_ g: NodeGraph) -> [NodeRole: GraphNode] {
        var out: [NodeRole: GraphNode] = [:]
        for n in g.nodes.sorted(by: { $0.id < $1.id }) {
            if let role = role(of: n), out[role] == nil { out[role] = n }
        }
        return out
    }

    /// A copy of the target's node, unlinked, under `id` at `place`.
    static func fresh(_ t: GraphNode, id: Int, at place: CGPoint) -> GraphNode {
        var n = t
        n.id = id
        n.position = place
        for i in n.inputs.indices { n.inputs[i].link = nil }
        for i in n.outputs.indices { n.outputs[i].links = [] }
        return n
    }

    /// Under the first node that feeds `t` (where the target has it if
    /// nothing does), moved down past any node in the way.
    static func place(_ t: GraphNode, in target: NodeGraph, under mapping: [Int: Int], of g: NodeGraph) -> CGPoint {
        let feeder = t.inputs.lazy.compactMap { $0.link.flatMap { target.link($0) } }
            .compactMap { mapping[$0.origin].flatMap { g.node($0) } }.first
        // Bodies with their title bars (LiteGraph's position is below the title).
        func box(_ position: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: position.x, y: position.y - 30, width: size.width, height: size.height + 30)
        }
        var place =
            feeder.map { CGPoint(x: $0.position.x, y: $0.position.y + $0.size.height + 60) } ?? t.position
        for _ in 0..<200 {
            let blocker = g.nodes.first {
                box($0.position, $0.size).intersects(box(place, t.size).insetBy(dx: 0, dy: -10))
            }
            guard let blocker else { break }
            place.y = blocker.position.y + blocker.size.height + 60
        }
        return place
    }
}

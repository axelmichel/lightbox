import ComfyKit
import CoreGraphics

/// Selecting and moving nodes in the graph view, without the view.
enum NodeEditing {
    /// The node at `point` (canvas units); the one drawn last is on top.
    static func node(at point: CGPoint, in nodes: [GraphNode], layouts: [Int: NodeLayout]) -> Int? {
        nodes.last { layouts[$0.id]?.bounds.contains(point) == true }?.id
    }

    /// The selection after a click on `node` (`nil`: the background).
    /// `extend` (⇧ or ⌘) adds the node, or takes it out again.
    static func select(_ node: Int?, in selection: Set<Int>, extend: Bool) -> Set<Int> {
        guard let node else { return extend ? selection : [] }
        guard extend else { return [node] }
        return selection.symmetricDifference([node])
    }

    /// What a drag that starts on `node` moves: the selection if the node
    /// is in it, else the node alone.
    static func dragged(_ node: Int, selection: Set<Int>) -> Set<Int> {
        selection.contains(node) ? selection : [node]
    }

    /// `doc` with `nodes` moved by `delta` (canvas units), on whole points.
    static func moved(_ doc: WorkflowDocument, _ nodes: Set<Int>, by delta: CGSize) -> WorkflowDocument {
        var d = doc
        for i in d.graph.nodes.indices where nodes.contains(d.graph.nodes[i].id) {
            d.graph.nodes[i].position.x = (d.graph.nodes[i].position.x + delta.width).rounded()
            d.graph.nodes[i].position.y = (d.graph.nodes[i].position.y + delta.height).rounded()
        }
        return d
    }
}

// MARK: - Structure

extension NodeEditing {
    /// Why a link can't be made; `nil` when it can.
    static func linkProblem(
        _ doc: WorkflowDocument, from origin: Int, _ slot: Int, to target: Int, _ input: Int
    ) -> String? {
        guard origin != target else { return "A node can't feed itself." }
        guard let o = doc.graph.node(origin), let t = doc.graph.node(target), o.outputs.indices.contains(slot),
            t.inputs.indices.contains(input)
        else { return "That socket is gone." }
        guard NodeGraph.accepts(t.inputs[input].type, from: o.outputs[slot].type) else {
            return "\(o.outputs[slot].type) doesn't fit into \(t.inputs[input].type)."
        }
        let roles = doc.roles
        if roles[origin] != nil, roles[target] != nil {
            return "Lightbox links its own nodes; change them in the Generate panel."
        }
        return nil
    }

    enum Deletion: Equatable {
        /// Added in the graph: it goes.
        case remove
        /// One of Lightbox's that stands for a setting: deleting it switches that off.
        case switchOff(GraphChange)
        /// One the graph can't do without (loaders, sampler, …), or a part of one.
        case keep
    }

    /// What deleting a node means.
    static func deletion(_ node: Int, in doc: WorkflowDocument) -> Deletion {
        guard doc.graph.node(node) != nil else { return .keep }
        guard let role = doc.roles[node] else { return .remove }
        guard role.part == nil else { return .keep }
        switch role.kind {
        case .lora: return role.key.map { .switchOff(.loraOff($0)) } ?? .keep
        case .clipSkip: return .switchOff(.clipSkip(1))
        case .faceFix: return .switchOff(.faceFixOff)
        case .handFix: return .switchOff(.handFixOff)
        case .guide: return role.key.flatMap(Int.init).map { .switchOff(.guideOff($0)) } ?? .keep
        default: return .keep
        }
    }

    static func canDelete(_ node: Int, in doc: WorkflowDocument) -> Bool {
        deletion(node, in: doc) != .keep
    }

    /// LoRA loaders added in the graph and hung into the model chain: their
    /// model input is linked and their model output feeds one of Lightbox's
    /// nodes. Such a LoRA becomes an extra LoRA of the form.
    static func hookedLoras(_ doc: WorkflowDocument, catalog: ComfyCatalog) -> [(node: Int, change: GraphChange)] {
        let roles = doc.roles
        return doc.graph.nodes.compactMap { node in
            guard node.type == "LoraLoader", roles[node.id] == nil,
                node.inputs.first(where: { $0.name == "model" })?.link != nil,
                let out = node.outputs.first,
                out.links.contains(where: { id in
                    doc.graph.link(id).map { roles[$0.target] != nil } ?? false
                })
            else { return nil }
            let spec = catalog.nodes[node.type]
            guard let name = node.widgetValue("lora_name", spec: spec)?.string, !name.isEmpty else { return nil }
            let strength = node.widgetValue("strength_model", spec: spec)?.double ?? 1
            let clip = node.widgetValue("strength_clip", spec: spec)?.double ?? strength
            return (node.id, .addLora(name: name, strength: strength, clipStrength: clip))
        }
    }
}

extension WorkflowDocument {
    /// Nodes added in the graph that run (not notes or reroutes): such a
    /// workflow is generated through the graph.
    var addedNodes: [GraphNode] {
        let roles = roles
        return graph.nodes.filter { roles[$0.id] == nil && !WorkflowCompiler.virtualTypes.contains($0.type) }
    }
}

/// Finding a node to add: a few useful ones without a search term, every
/// node of the server with one.
enum NodeSearch {
    /// Shown before anything is typed, if the server has them.
    static let suggested = [
        "ImageScaleBy", "ImageScale", "UpscaleModelLoader", "ImageUpscaleWithModel", "ImageSharpen", "ImageBlur",
        "ImageInvert", "ImageCrop", "SaveImage", "PreviewImage",
    ]

    /// Node types for `query`, found by name, display name or category:
    /// those whose name starts with it first, then by name.
    static func results(_ query: String, in catalog: ComfyCatalog) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return suggested.filter { catalog.nodes[$0] != nil } }
        func names(_ type: String) -> [String] { [type, catalog.nodes[type]?.displayName ?? ""] }
        let found = catalog.nodes.filter { type, spec in
            names(type).contains { $0.localizedCaseInsensitiveContains(q) }
                || spec.category.localizedCaseInsensitiveContains(q)
        }
        return found.keys.sorted { a, b in
            let pa = names(a).contains { $0.lowercased().hasPrefix(q.lowercased()) }
            let pb = names(b).contains { $0.lowercased().hasPrefix(q.lowercased()) }
            if pa != pb { return pa }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}

extension NodeEditing {
    /// What kind of model a graph is built for, said for people: "a
    /// checkpoint model", "Flux", "Z-Image", … `nil` for a graph without
    /// Lightbox's loaders.
    static func modelKind(_ doc: WorkflowDocument, catalog: ComfyCatalog) -> String? {
        let roles = Set(doc.roles.values)
        if roles.contains(NodeRole(.checkpoint)) { return "a checkpoint model" }
        guard roles.contains(NodeRole(.diffusionModel)) else { return nil }
        switch ManagedGraph(doc, catalog: catalog).settings.clipType {
        case "flux": return "Flux"
        case "flux2": return "Flux 2"
        case "lumina2": return "Z-Image"
        case "stable_diffusion": return "Anima"
        case "krea2": return "Krea 2"
        case let other?: return other
        case nil: return "a diffusion model"
        }
    }
}

// MARK: - Copy, paste, mute, bypass

extension NodeEditing {
    /// The nodes a selection can copy, mute or bypass: those the user added.
    static func ownNodes(_ ids: Set<Int>, in doc: WorkflowDocument) -> Set<Int> {
        let roles = doc.roles
        return ids.filter { doc.graph.node($0) != nil && roles[$0] == nil }
    }

    /// The user's nodes of `ids` with the links between them, as a document
    /// of their own (for the pasteboard).
    static func clipboard(_ ids: Set<Int>, from doc: WorkflowDocument) -> WorkflowDocument? {
        let own = ownNodes(ids, in: doc)
        guard !own.isEmpty else { return nil }
        var copy = WorkflowDocument()
        copy.schema = doc.schema
        copy.graph = doc.graph
        copy.graph.removeNodes(Set(doc.graph.nodes.map(\.id)).subtracting(own))
        copy.graph.groups = []
        copy.graph.reroutes = []
        return copy
    }

    /// `clip`'s nodes put into `doc` with new ids, moved by `offset`; they
    /// are the user's, whatever they were. Returns the new ids too.
    static func pasted(_ clip: WorkflowDocument, into doc: WorkflowDocument, offset: CGVector)
        -> (doc: WorkflowDocument, ids: [Int])
    {
        var d = doc
        let ids = d.graph.duplicate(Set(clip.graph.nodes.map(\.id)), from: clip.graph, offset: offset)
        for i in d.graph.nodes.indices where ids.contains(d.graph.nodes[i].id) {
            d.graph.nodes[i].properties[WorkflowDocument.roleProperty] = nil
        }
        return (d, ids)
    }

    /// The user's nodes of `ids` muted (or bypassed); back to running if
    /// they all are already.
    static func toggled(_ mode: NodeMode, _ ids: Set<Int>, in doc: WorkflowDocument) -> WorkflowDocument {
        let own = ownNodes(ids, in: doc)
        var d = doc
        let all = !own.isEmpty && own.allSatisfy { d.graph.node($0)?.mode == mode }
        for i in d.graph.nodes.indices where own.contains(d.graph.nodes[i].id) {
            d.graph.nodes[i].mode = all ? .always : mode
        }
        return d
    }
}

// MARK: - Groups and reroutes

extension NodeEditing {
    /// The height of a group's title bar, as LiteGraph draws it.
    static func groupTitleHeight(_ group: GraphGroup) -> Double { (group.fontSize ?? 24) * 1.4 }

    /// The group whose title bar is at `point`; the one drawn last is on top.
    static func group(at point: CGPoint, in doc: WorkflowDocument) -> Int? {
        doc.graph.groups.last { g in
            CGRect(x: g.frame.minX, y: g.frame.minY, width: g.frame.width, height: groupTitleHeight(g)).contains(point)
        }?.id
    }

    /// What moving a group takes along: the nodes and reroutes inside it.
    static func groupContents(_ id: Int, in doc: WorkflowDocument) -> (nodes: Set<Int>, reroutes: Set<Int>) {
        guard let frame = doc.graph.groups.first(where: { $0.id == id })?.frame else { return ([], []) }
        return (
            Set(doc.graph.nodes(inside: frame)),
            Set(doc.graph.reroutes.filter { frame.contains($0.position) }.map(\.id))
        )
    }

    /// `doc` with the group, and what it took along, moved by `delta`.
    static func movedGroup(
        _ doc: WorkflowDocument, _ id: Int, nodes: Set<Int>, reroutes: Set<Int>, by delta: CGSize
    ) -> WorkflowDocument {
        var d = moved(doc, nodes, by: delta)
        for i in d.graph.groups.indices where d.graph.groups[i].id == id {
            d.graph.groups[i].frame.origin.x = (d.graph.groups[i].frame.origin.x + delta.width).rounded()
            d.graph.groups[i].frame.origin.y = (d.graph.groups[i].frame.origin.y + delta.height).rounded()
        }
        for i in d.graph.reroutes.indices where reroutes.contains(d.graph.reroutes[i].id) {
            d.graph.reroutes[i].position.x = (d.graph.reroutes[i].position.x + delta.width).rounded()
            d.graph.reroutes[i].position.y = (d.graph.reroutes[i].position.y + delta.height).rounded()
        }
        return d
    }

    /// A new group around `bounds` (the selected nodes, title bars
    /// included), with room for its own title. Returns its id too.
    static func grouping(_ doc: WorkflowDocument, around bounds: CGRect, title: String) -> (WorkflowDocument, Int) {
        var d = doc
        d.graph.lastGroupID = max(d.graph.lastGroupID, d.graph.groups.map(\.id).max() ?? 0) + 1
        var g = GraphGroup(id: d.graph.lastGroupID, title: title, frame: .zero)
        let pad = 10.0
        g.frame =
            CGRect(
                x: bounds.minX - pad, y: bounds.minY - pad - groupTitleHeight(g), width: bounds.width + 2 * pad,
                height: bounds.height + 2 * pad + groupTitleHeight(g)
            ).integral
        d.graph.groups.append(g)
        return (d, g.id)
    }

    /// The reroute whose dot is at `point`.
    static func reroute(at point: CGPoint, in g: NodeGraph, radius: Double = 8) -> Int? {
        g.reroutes.last { hypot($0.position.x - point.x, $0.position.y - point.y) <= radius }?.id
    }

    /// `doc` with reroute `id` moved by `delta`.
    static func movedReroute(_ doc: WorkflowDocument, _ id: Int, by delta: CGSize) -> WorkflowDocument {
        var d = doc
        for i in d.graph.reroutes.indices where d.graph.reroutes[i].id == id {
            d.graph.reroutes[i].position.x = (d.graph.reroutes[i].position.x + delta.width).rounded()
            d.graph.reroutes[i].position.y = (d.graph.reroutes[i].position.y + delta.height).rounded()
        }
        return d
    }

    /// A point on the curve a link is drawn with between `a` and `b`
    /// (LiteGraph's: level handles a quarter of the distance long).
    static func curvePoint(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let handle = hypot(b.x - a.x, b.y - a.y) * 0.25
        let c1 = CGPoint(x: a.x + handle, y: a.y)
        let c2 = CGPoint(x: b.x - handle, y: b.y)
        let u = 1 - t
        func mix(_ p: Double, _ q: Double, _ r: Double, _ s: Double) -> Double {
            u * u * u * p + 3 * u * u * t * q + 3 * u * t * t * r + t * t * t * s
        }
        return CGPoint(x: mix(a.x, c1.x, c2.x, b.x), y: mix(a.y, c1.y, c2.y, b.y))
    }

    /// The link drawn at `point`, and which piece of it (0: from the output
    /// to its first reroute): where a double-click puts a reroute.
    static func link(
        at point: CGPoint, in g: NodeGraph, layouts: [Int: NodeLayout], tolerance: Double = 6
    ) -> (link: Int, segment: Int)? {
        for link in g.links.reversed() {
            guard let from = layouts[link.origin]?.outputPoints, from.indices.contains(link.originSlot),
                let to = layouts[link.target]?.inputPoints, to.indices.contains(link.targetSlot)
            else { continue }
            let points = [from[link.originSlot]] + reroutePoints(link, in: g) + [to[link.targetSlot]]
            for (i, (a, b)) in zip(points, points.dropFirst()).enumerated() {
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                guard box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { continue }
                let steps = max(8, Int(hypot(b.x - a.x, b.y - a.y) / 4))
                let near = (0...steps).contains { n in
                    let p = curvePoint(a, b, Double(n) / Double(steps))
                    return hypot(p.x - point.x, p.y - point.y) <= tolerance
                }
                if near { return (link.id, i) }
            }
        }
        return nil
    }

    /// The native reroutes a link passes through, from its start to its end.
    static func reroutePoints(_ link: GraphLink, in g: NodeGraph) -> [CGPoint] {
        var points: [CGPoint] = []
        var next = link.parentReroute
        var seen: Set<Int> = []
        while let id = next, seen.insert(id).inserted, let r = g.reroutes.first(where: { $0.id == id }) {
            points.insert(r.position, at: 0)
            next = r.parent
        }
        return points
    }
}

// MARK: - Subgraphs

extension NodeEditing {
    /// The inside of subgraph `id` to show: its nodes, with its inputs and
    /// outputs as two nodes left and right of them. They have the ids the
    /// inside's links use for them (`GraphLink.subgraphInputID`, …), so the
    /// links draw as they are.
    static func inside(_ id: String, of doc: WorkflowDocument) -> WorkflowDocument? {
        guard let def = doc.subgraph(id) else { return nil }
        var d = WorkflowDocument()
        d.subgraphs = doc.subgraphs
        d.graph = def.graph
        let bounds = def.graph.nodes.reduce(CGRect.null) { $0.union($1.frame) }
        let b = bounds.isNull ? CGRect(x: 0, y: 0, width: 400, height: 200) : bounds
        var inputs = GraphNode(
            id: GraphLink.subgraphInputID, type: "Subgraph Inputs", position: CGPoint(x: b.minX - 300, y: b.minY),
            size: CGSize(width: 200, height: 40))
        inputs.title = "Inputs"
        inputs.outputs = def.inputs.map { NodeOutputSlot(name: $0.name, type: $0.type, links: $0.linkIDs) }
        var outputs = GraphNode(
            id: GraphLink.subgraphOutputID, type: "Subgraph Outputs", position: CGPoint(x: b.maxX + 100, y: b.minY),
            size: CGSize(width: 200, height: 40))
        outputs.title = "Outputs"
        outputs.inputs = def.outputs.map { NodeInputSlot(name: $0.name, type: $0.type, link: $0.linkIDs.first) }
        d.graph.nodes += [inputs, outputs]
        return d
    }
}

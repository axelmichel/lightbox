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

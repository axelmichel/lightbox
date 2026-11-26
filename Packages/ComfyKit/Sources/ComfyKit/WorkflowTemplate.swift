// A workflow made in ComfyUI as a template: the nodes Lightbox can fill in
// get the roles its own graphs have, found by following the links from the
// sampler. Everything else stays as it is. With the roles, reading values
// (`ManagedGraph`), editing and checking work as on Lightbox's graphs.

import CoreGraphics
import Foundation

extension WorkflowDocument {
    public struct TemplateMarking: Sendable {
        /// The workflow with roles on the nodes found.
        public var doc: WorkflowDocument
        /// What a template needs and wasn't found: `.checkpoint` (no model
        /// loader), `.positive`, `.sampler`, `.latent`, `.vaeDecode`, `.output`.
        public var missing: [NodeRole.Kind]
    }

    static let modelLoaderTypes: Set<String> = ["CheckpointLoaderSimple", "UNETLoader", "UnetLoaderGGUF"]
    static let clipLoaderTypes: Set<String> = [
        "CLIPLoader", "CLIPLoaderGGUF", "DualCLIPLoader", "DualCLIPLoaderGGUF", "TripleCLIPLoader",
    ]
    static let samplerTypes: Set<String> = ["KSampler", "KSamplerAdvanced", "SamplerCustomAdvanced"]

    /// `self` with roles on what Lightbox can fill in. Roles it had are
    /// replaced; muted and bypassed nodes get none.
    public func markedAsTemplate(catalog: ComfyCatalog) -> TemplateMarking {
        var doc = self
        let g = graph
        var roles: [Int: NodeRole] = [:]

        func active(_ n: GraphNode) -> Bool { n.mode != .never && n.mode != .bypass }
        func from(_ n: GraphNode, _ input: String) -> GraphNode? {
            n.inputs.first { $0.name == input }?.link.flatMap { g.link($0) }.flatMap { g.node($0.origin) }
                .flatMap { active($0) ? $0 : nil }
        }
        /// What feeds `n` with `type`: through the input named like the side
        /// being followed if it has one (a ControlNet's "negative"), else the first.
        func from(_ n: GraphNode, type: String, preferring name: String) -> GraphNode? {
            let inputs = n.inputs.filter { $0.type == type && $0.link != nil }
            guard let input = inputs.first(where: { $0.name == name }) ?? inputs.first else { return nil }
            return from(n, input.name)
        }
        // By the link list: older files don't list links on the outputs.
        func into(_ n: GraphNode, slot: Int) -> [GraphNode] {
            g.links.filter { $0.origin == n.id && $0.originSlot == slot }.compactMap { g.node($0.target) }
                .filter(active)
        }
        func mark(_ n: GraphNode?, _ role: NodeRole) {
            if let n, roles[n.id] == nil { roles[n.id] = role }
        }

        // The sampler whose picture is decoded; else the first.
        let samplers = g.nodes.filter { Self.samplerTypes.contains($0.type) && active($0) }.sorted { $0.id < $1.id }
        let sampler =
            samplers.first { s in into(s, slot: 0).contains { $0.type == "VAEDecode" } } ?? samplers.first
        var loader: GraphNode?
        if let sampler {
            mark(sampler, NodeRole(.sampler))
            // Flux 2 and others: the guider holds model and prompts.
            var conditioned = sampler
            if sampler.type == "SamplerCustomAdvanced" {
                mark(from(sampler, "noise"), NodeRole(.sampler, .noise))
                mark(from(sampler, "sampler"), NodeRole(.sampler, .select))
                mark(from(sampler, "sigmas"), NodeRole(.sampler, .scheduler))
                if let guider = from(sampler, "guider") {
                    mark(guider, NodeRole(.sampler, .guider))
                    conditioned = guider
                }
            }

            // Model: back to its loader, through LoRAs and patches.
            var node = from(conditioned, "model")
            var seen: Set<Int> = []
            while let n = node, seen.insert(n.id).inserted {
                if Self.modelLoaderTypes.contains(n.type) {
                    mark(n, NodeRole(n.type == "CheckpointLoaderSimple" ? .checkpoint : .diffusionModel))
                    loader = n
                    break
                }
                if n.type.hasPrefix("LoraLoader"),
                    let name = n.widgetValue("lora_name", spec: catalog.nodes[n.type])?.string
                {
                    mark(n, NodeRole(.lora, key: name))
                } else if n.type == "ModelSamplingAuraFlow" {
                    mark(n, NodeRole(.shift))
                }
                node = from(n, type: "MODEL", preferring: "model")
            }

            // Prompts: back to their text encoders.
            func prompt(_ side: String, _ kind: NodeRole.Kind) -> GraphNode? {
                var node = from(conditioned, side) ?? (side == "positive" ? from(conditioned, "conditioning") : nil)
                var seen: Set<Int> = []
                while let n = node, seen.insert(n.id).inserted {
                    if n.type == "CLIPTextEncode" || (kind == .negative && n.type == "ConditioningZeroOut") {
                        mark(n, NodeRole(kind))
                        return n
                    }
                    if n.type == "FluxGuidance" { mark(n, NodeRole(.guidance)) }
                    node = from(n, type: "CONDITIONING", preferring: side)
                }
                return nil
            }
            let positive = prompt("positive", .positive)
            _ = prompt("negative", .negative)

            // Text encoders: back from the prompt, through clip skip and LoRAs.
            var clip = positive.flatMap { from($0, "clip") }
            seen = []
            while let n = clip, seen.insert(n.id).inserted {
                if Self.clipLoaderTypes.contains(n.type) {
                    mark(n, NodeRole(.textEncoders))
                    break
                }
                if Self.modelLoaderTypes.contains(n.type) { break }
                if n.type == "CLIPSetLastLayer" { mark(n, NodeRole(.clipSkip)) }
                if n.type.hasPrefix("LoraLoader"),
                    let name = n.widgetValue("lora_name", spec: catalog.nodes[n.type])?.string
                {
                    mark(n, NodeRole(.lora, key: name))
                }
                clip = from(n, type: "CLIP", preferring: "clip")
            }

            if let latent = from(sampler, "latent_image"), latent.type.hasPrefix("Empty") {
                mark(latent, NodeRole(.latent))
            }

            // The picture: decoded, then the first output node after it.
            if let decode = into(sampler, slot: 0).first(where: { $0.type == "VAEDecode" }) {
                mark(decode, NodeRole(.vaeDecode))
                if let vae = from(decode, "vae"), vae.type == "VAELoader" { mark(vae, NodeRole(.vae)) }
                var queue = [decode]
                var visited: Set<Int> = [decode.id]
                search: while !queue.isEmpty {
                    let n = queue.removeFirst()
                    let pictures = g.links.filter { $0.origin == n.id && $0.type == "IMAGE" }
                    for link in pictures {
                        guard let next = g.node(link.target), active(next), visited.insert(next.id).inserted
                        else { continue }
                        if catalog.nodes[next.type]?.isOutputNode == true || next.type == "SaveImage"
                            || next.type == "PreviewImage"
                        {
                            mark(next, NodeRole(.output))
                            break search
                        }
                        queue.append(next)
                    }
                }
            }
        }

        for i in doc.graph.nodes.indices {
            doc.graph.nodes[i].properties[Self.roleProperty] = roles[doc.graph.nodes[i].id].map {
                .string($0.description)
            }
        }
        let found = Set(roles.values.map(\.kind))
        var missing: [NodeRole.Kind] = []
        if loader == nil { missing.append(.checkpoint) }
        for kind in [NodeRole.Kind.positive, .sampler, .latent, .vaeDecode, .output] where !found.contains(kind) {
            missing.append(kind)
        }
        return TemplateMarking(doc: doc, missing: missing)
    }
}

// MARK: - Filling

extension WorkflowDocument {
    /// The template (marked with `markedAsTemplate`) with `r`'s values on
    /// its marked nodes, and its LoRA chain made `r`'s. Everything else stays.
    /// Filling twice with the same request changes nothing.
    public func filled(with r: GenerationRequest, catalog: ComfyCatalog) -> WorkflowDocument {
        var doc = self
        doc.listOutputs(catalog: catalog)
        doc.fillLoras(r.loras, catalog: catalog)
        if !r.negative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.giveNegativeText(catalog: catalog)
        }
        let roles = doc.roles
        func set(_ kind: NodeRole.Kind, _ part: NodeRole.Part? = nil, _ values: [String: JSONValue?]) {
            for (id, role) in roles where role.kind == kind && role.part == part {
                guard let i = doc.graph.index(of: id) else { continue }
                let spec = catalog.nodes[doc.graph.nodes[i].type]
                for (input, value) in values {
                    guard let value, doc.graph.nodes[i].widgetValue(input, spec: spec) != nil else { continue }
                    doc.graph.nodes[i].setWidgetValue(input, value, spec: spec)
                }
            }
        }
        let split = r.split
        set(.checkpoint, nil, ["ckpt_name": r.checkpoint.isEmpty ? nil : .string(r.checkpoint)])
        set(.diffusionModel, nil, ["unet_name": split.map { .string($0.model) }])
        if let encoders = split?.textEncoders, !encoders.isEmpty {
            set(
                .textEncoders, nil,
                [
                    "clip_name": .string(encoders[0]), "clip_name1": .string(encoders[0]),
                    "clip_name2": encoders.count > 1 ? .string(encoders[1]) : nil,
                ])
        }
        let vae = split?.vae ?? r.vae
        set(.vae, nil, ["vae_name": vae.flatMap { $0.isEmpty ? nil : .string($0) }])
        set(.clipSkip, nil, ["stop_at_clip_layer": .int(-max(1, r.clipSkip))])
        set(.positive, nil, ["text": .string(r.positive)])
        set(.negative, nil, ["text": .string(r.negative)])
        set(.guidance, nil, ["guidance": split?.guidance.map { .double($0) }])
        set(.shift, nil, ["shift": split?.shift.map { .double($0) }])
        set(
            .latent, nil,
            ["width": .int(r.width), "height": .int(r.height), "batch_size": .int(max(1, r.batchSize))])
        let sampling: [String: JSONValue?] = [
            "seed": .int(r.seed), "noise_seed": .int(r.seed), "steps": .int(r.steps), "cfg": .double(r.cfg),
            "sampler_name": .string(r.sampler), "scheduler": .string(r.scheduler),
        ]
        set(.sampler, nil, sampling)
        set(.sampler, .noise, ["noise_seed": .int(r.seed)])
        set(.sampler, .guider, ["cfg": .double(r.cfg)])
        set(.sampler, .select, ["sampler_name": .string(r.sampler)])
        set(
            .sampler, .scheduler,
            [
                "steps": .int(r.steps), "scheduler": .string(r.scheduler), "width": .int(r.width),
                "height": .int(r.height),
            ])
        return doc
    }

    /// The LoRA loaders right after the model loader, made `loras`: their
    /// strengths set if they are those LoRAs already, else taken out (their
    /// links bridged) and a new chain put in.
    mutating func fillLoras(_ loras: [LoraRequest], catalog: ComfyCatalog) {
        let roles = self.roles
        let loraIDs = roles.filter { $0.value.kind == .lora }.map(\.key).sorted()
        let spec = catalog.nodes["LoraLoader"]
        let names = loraIDs.compactMap { roles[$0]?.key }
        if names == loras.map(\.name) {
            for (id, lora) in zip(loraIDs, loras) {
                guard let i = graph.index(of: id) else { continue }
                let s = catalog.nodes[graph.nodes[i].type]
                graph.nodes[i].setWidgetValue("strength_model", .double(lora.strength), spec: s)
                graph.nodes[i].setWidgetValue("strength_clip", .double(lora.clipStrength), spec: s)
            }
            return
        }
        // Out: whatever read a LoRA reads what fed it.
        for id in loraIDs { bridge(id) }
        graph.removeNodes(Set(loraIDs))
        guard !loras.isEmpty, let spec,
            let loader = roles.first(where: { [.checkpoint, .diffusionModel].contains($0.value.kind) })?.key,
            let loaderNode = graph.node(loader)
        else { return }
        // Where model and CLIP come from: the checkpoint, or the loaders of a split model.
        let model = (node: loader, slot: 0)
        let clip: (node: Int, slot: Int)? =
            roles[loader]?.kind == .checkpoint
            ? (loader, 1) : roles.first(where: { $0.value.kind == .textEncoders }).map { ($0.key, 0) }
        let modelReaders = graph.links.filter { $0.origin == model.node && $0.originSlot == model.slot }
        let clipReaders = clip.map { c in graph.links.filter { $0.origin == c.node && $0.originSlot == c.slot } } ?? []
        var lastModel = model
        var lastClip = clip
        for (n, lora) in loras.enumerated() {
            let place = CGPoint(
                x: loaderNode.position.x, y: loaderNode.position.y + loaderNode.size.height + 80 + Double(n) * 160)
            let id = graph.addNode("LoraLoader", spec: spec, at: place)
            guard let i = graph.index(of: id) else { continue }
            graph.nodes[i].setWidgetValue("lora_name", .string(lora.name), spec: spec)
            graph.nodes[i].setWidgetValue("strength_model", .double(lora.strength), spec: spec)
            graph.nodes[i].setWidgetValue("strength_clip", .double(lora.clipStrength), spec: spec)
            graph.nodes[i].properties[Self.roleProperty] = .string(NodeRole(.lora, key: lora.name).description)
            let inputs = graph.nodes[i].inputs
            if let m = inputs.firstIndex(where: { $0.name == "model" }) {
                graph.connect(from: lastModel.node, lastModel.slot, to: id, m)
            }
            if let c = inputs.firstIndex(where: { $0.name == "clip" }), let from = lastClip {
                graph.connect(from: from.node, from.slot, to: id, c)
            }
            lastModel = (id, 0)
            if lastClip != nil { lastClip = (id, 1) }
        }
        // What read the loader now reads the last LoRA.
        for l in modelReaders { graph.connect(from: lastModel.node, lastModel.slot, to: l.target, l.targetSlot) }
        if let lastClip {
            for l in clipReaders { graph.connect(from: lastClip.node, lastClip.slot, to: l.target, l.targetSlot) }
        }
    }

    /// A negative zeroed out (Flux 2, Krea 2) becomes a text encoder like the
    /// positive one, so a negative prompt (and the guard's terms) can go in.
    mutating func giveNegativeText(catalog: ComfyCatalog) {
        let roles = self.roles
        guard let negative = roles.first(where: { $0.value == NodeRole(.negative) })?.key,
            let zero = graph.node(negative), zero.type == "ConditioningZeroOut",
            let positive = roles.first(where: { $0.value == NodeRole(.positive) }).flatMap({ graph.node($0.key) }),
            let clip = positive.inputs.first(where: { $0.name == "clip" })?.link.flatMap({ graph.link($0) }),
            let spec = catalog.nodes["CLIPTextEncode"]
        else { return }
        let readers = graph.links.filter { $0.origin == negative }
        let id = graph.addNode("CLIPTextEncode", spec: spec, at: zero.position)
        guard let i = graph.index(of: id),
            let clipInput = graph.nodes[i].inputs.firstIndex(where: { $0.name == "clip" })
        else { return }
        graph.nodes[i].properties[Self.roleProperty] = .string(NodeRole(.negative).description)
        graph.connect(from: clip.origin, clip.originSlot, to: id, clipInput)
        for l in readers { graph.connect(from: id, 0, to: l.target, l.targetSlot) }
        graph.removeNodes([negative])
    }

    /// Links out of a node go to what fed its input of the same type
    /// instead, as if it were bypassed.
    mutating func bridge(_ id: Int) {
        guard let node = graph.node(id) else { return }
        for l in graph.links where l.origin == id {
            guard
                let feed = node.inputs.first(where: { $0.type == l.type && $0.link != nil })?.link
                    .flatMap({ graph.link($0) })
            else { continue }
            graph.connect(from: feed.origin, feed.originSlot, to: l.target, l.targetSlot)
        }
    }

    /// Older files leave the outputs off their nodes and keep the links only
    /// in the link list; give such nodes their outputs (from the server's
    /// definition), so they can be linked.
    mutating func listOutputs(catalog: ComfyCatalog) {
        for i in graph.nodes.indices where graph.nodes[i].outputs.isEmpty {
            guard let spec = catalog.nodes[graph.nodes[i].type], !spec.outputs.isEmpty else { continue }
            let id = graph.nodes[i].id
            graph.nodes[i].outputs = spec.outputs.enumerated().map { slot, output in
                NodeOutputSlot(
                    name: output.name, type: output.type,
                    links: graph.links.filter { $0.origin == id && $0.originSlot == slot }.map(\.id))
            }
        }
    }
}

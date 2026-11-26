// A workflow made in ComfyUI as a template: the nodes Lightbox can fill in
// get the roles its own graphs have, found by following the links from the
// sampler. Everything else stays as it is. With the roles, reading values
// (`ManagedGraph`), editing and checking work as on Lightbox's graphs.

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

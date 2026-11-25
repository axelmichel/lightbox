// Reading a ComfyUI workflow into a preset: the checkpoint (or the diffusion
// model with its text encoders), LoRAs, sampler, steps, CFG, Flux guidance,
// sampling shift, size, CLIP skip, VAE and prompts are taken over;
// everything else (upscalers, detailers, ControlNets) is listed as not
// taken over.
//
// Both of ComfyUI's formats are read:
// - API format ("Export (API)"): {"<id>": {"class_type", "inputs"}}, links
//   as ["<id>", slot];
// - UI format ("Save"): {"nodes": [{id, type, mode, inputs, widgets_values}],
//   "links": [[link, from, slot, to, slot, type]]}. Widget values are a
//   list in the node's widget order, which isn't in the file; `widgetNames`
//   has it for the nodes read here. Add new nodes there.

import Foundation

public enum WorkflowImportError: Error, CustomStringConvertible, Equatable, Sendable {
    case notJSON
    case notAWorkflow
    case noSampler
    case noCheckpoint

    public var description: String {
        switch self {
        case .notJSON: "The file isn't JSON."
        case .notAWorkflow: "The file isn't a ComfyUI workflow."
        case .noSampler: "The workflow has no KSampler, so there are no sampling settings to take over."
        case .noCheckpoint:
            "The workflow doesn't load its model with Load Checkpoint or Load Diffusion Model, so it can't be a preset."
        }
    }
}

public enum WorkflowImport {
    public struct Result: Sendable {
        public var preset: GenerationPreset
        /// The workflow's positive prompt, for the prompt field.
        public var prompt: String
        /// The LoRA and checkpoint files the workflow names.
        public var files: [String]
        /// The sampler's seed, if it has a fixed one.
        public var seed: Int?
    }

    /// Read `data` (a workflow file) into a new preset named after `name`.
    public static func read(_ data: Data, name: String = "") throws(WorkflowImportError) -> Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw .notJSON }
        let graph = try Graph(json)
        return try extract(graph, name: name)
    }

    // MARK: - Graph

    enum Value: Equatable {
        case link(String)
        case string(String)
        case number(Double)
        case bool(Bool)
        case other

        init(_ any: Any) {
            switch any {
            case let s as String: self = .string(s)
            case let n as NSNumber:
                self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            default: self = .other
            }
        }
    }

    struct Node {
        var id: String
        var type: String
        var inputs: [String: Value] = [:]
        /// Bypassed in the UI: passes its inputs through, does nothing.
        var bypassed = false
    }

    struct Graph {
        var nodes: [String: Node] = [:]

        init(nodes: [Node]) {
            for n in nodes { self.nodes[n.id] = n }
        }

        init(_ json: Any) throws(WorkflowImportError) {
            guard var dict = json as? [String: Any] else { throw .notAWorkflow }
            // Some tools wrap it: {"prompt": {...}} or {"workflow": {...}}.
            for key in ["workflow", "prompt"] {
                if let inner = dict[key] as? [String: Any], dict["nodes"] == nil, dict["class_type"] == nil {
                    dict = inner
                    break
                }
            }
            if let nodes = dict["nodes"] as? [[String: Any]] {
                self.init(ui: nodes, links: dict["links"] as? [Any] ?? [])
            } else {
                self.init(api: dict)
            }
            guard !self.nodes.isEmpty else { throw .notAWorkflow }
        }

        init(api: [String: Any]) {
            for (id, raw) in api {
                guard let node = raw as? [String: Any], let type = node["class_type"] as? String else { continue }
                var n = Node(id: id, type: type)
                for (key, value) in node["inputs"] as? [String: Any] ?? [:] {
                    if let pair = value as? [Any], pair.count == 2, pair[1] is NSNumber {
                        n.inputs[key] = .link("\(pair[0])")
                    } else {
                        n.inputs[key] = Value(value)
                    }
                }
                nodes[id] = n
            }
        }

        init(ui: [[String: Any]], links: [Any]) {
            // Link id → the node it comes from.
            var source: [Int: String] = [:]
            for case let link as [Any] in links where link.count >= 2 {
                if let id = (link[0] as? NSNumber)?.intValue { source[id] = "\(link[1])" }
            }
            for node in ui {
                guard let type = node["type"] as? String, let rawID = node["id"] else { continue }
                var n = Node(id: "\(rawID)", type: type)
                // Mode 2 = muted (never runs), 4 = bypassed.
                let mode = (node["mode"] as? NSNumber)?.intValue ?? 0
                if mode == 2 { continue }
                n.bypassed = mode == 4
                if let widgets = node["widgets_values"] as? [Any] {
                    for (name, value) in zip(WorkflowImport.widgetNames(type), widgets) where !name.isEmpty {
                        n.inputs[name] = Value(value)
                    }
                    if type.hasPrefix("Primitive"), let first = widgets.first { n.inputs["value"] = Value(first) }
                } else if let widgets = node["widgets_values"] as? [String: Any] {
                    for (name, value) in widgets { n.inputs[name] = Value(value) }
                }
                for case let input as [String: Any] in node["inputs"] as? [Any] ?? [] {
                    guard let name = input["name"] as? String, let link = (input["link"] as? NSNumber)?.intValue,
                        let from = source[link]
                    else { continue }
                    n.inputs[name] = .link(from)
                }
                nodes[n.id] = n
            }
        }

        func node(_ value: Value?) -> Node? {
            guard case .link(let id)? = value else { return nil }
            return nodes[id]
        }

        /// A literal input; one linked from a primitive or a reroute node
        /// is followed to its value.
        func value(_ node: Node, _ key: String) -> Value? {
            var current = node.inputs[key]
            var hops = 0
            while case .link = current, let from = self.node(current), hops < 8 {
                hops += 1
                if from.type == "Reroute" {
                    current = from.inputs.values.first
                } else if let v = from.inputs["value"] ?? from.inputs["string"] ?? from.inputs["text"] {
                    current = v
                } else {
                    return nil
                }
            }
            return current
        }

        func string(_ node: Node, _ key: String) -> String? {
            if case .string(let s)? = value(node, key) { return s }
            return nil
        }

        func number(_ node: Node, _ key: String) -> Double? {
            if case .number(let n)? = value(node, key) { return n }
            return nil
        }

        /// The node feeding `key`, skipping reroutes.
        func upstream(_ node: Node, _ key: String) -> Node? {
            var n = self.node(node.inputs[key])
            var hops = 0
            while let r = n, r.type == "Reroute", hops < 8 {
                hops += 1
                n = self.node(r.inputs.values.first)
            }
            return n
        }
    }

    /// Widget order of the nodes read from UI-format files. "" skips a
    /// widget that has no input of its own (ComfyUI's "control after
    /// generate" for seeds).
    static func widgetNames(_ type: String) -> [String] {
        switch type {
        case "CheckpointLoaderSimple": ["ckpt_name"]
        case "UNETLoader": ["unet_name", "weight_dtype"]
        case "UnetLoaderGGUF": ["unet_name"]
        case "CLIPLoader": ["clip_name", "type", "device"]
        case "CLIPLoaderGGUF": ["clip_name", "type"]
        case "DualCLIPLoader": ["clip_name1", "clip_name2", "type", "device"]
        case "DualCLIPLoaderGGUF": ["clip_name1", "clip_name2", "type"]
        case "FluxGuidance": ["guidance"]
        case "RandomNoise": ["noise_seed", ""]
        case "CFGGuider": ["cfg"]
        case "KSamplerSelect": ["sampler_name"]
        case "Flux2Scheduler": ["steps", "width", "height"]
        case "BasicScheduler": ["scheduler", "steps", "denoise"]
        case "EmptyFlux2LatentImage": ["width", "height", "batch_size"]
        case "ModelSamplingAuraFlow": ["shift", "sampling"]
        case "VAELoader": ["vae_name"]
        case "LoraLoader": ["lora_name", "strength_model", "strength_clip"]
        case "LoraLoaderModelOnly": ["lora_name", "strength_model"]
        case "CLIPSetLastLayer": ["stop_at_clip_layer"]
        case "CLIPTextEncode": ["text"]
        case "EmptyLatentImage", "EmptySD3LatentImage": ["width", "height", "batch_size"]
        case "KSampler": ["seed", "", "steps", "cfg", "sampler_name", "scheduler", "denoise"]
        case "KSamplerAdvanced":
            [
                "add_noise", "noise_seed", "", "steps", "cfg", "sampler_name", "scheduler", "start_at_step",
                "end_at_step", "return_with_leftover_noise",
            ]
        default: []
        }
    }

    static let samplers: Set<String> = ["KSampler", "KSamplerAdvanced"]
    static let loraLoaders: Set<String> = ["LoraLoader", "LoraLoaderModelOnly"]
    static let textEncoders: Set<String> = ["CLIPTextEncode"]
    static let modelLoaders: Set<String> = ["CheckpointLoaderSimple", "UNETLoader", "UnetLoaderGGUF"]
    static let clipLoaders: Set<String> = ["CLIPLoader", "CLIPLoaderGGUF", "DualCLIPLoader", "DualCLIPLoaderGGUF"]
    /// Nodes that are part of every txt2img graph and need no mention.
    static let plumbing: Set<String> = [
        "CheckpointLoaderSimple", "VAELoader", "CLIPSetLastLayer", "EmptyLatentImage", "EmptySD3LatentImage",
        "UNETLoader", "UnetLoaderGGUF", "CLIPLoader", "CLIPLoaderGGUF", "DualCLIPLoader", "DualCLIPLoaderGGUF",
        "ConditioningZeroOut", "RandomNoise", "CFGGuider", "BasicGuider", "KSamplerSelect", "Flux2Scheduler",
        "BasicScheduler", "EmptyFlux2LatentImage", "SamplerCustomAdvanced",
        "VAEDecode", "SaveImage", "PreviewImage", "Reroute", "Note", "MarkdownNote", "PrimitiveNode",
        "PrimitiveInt", "PrimitiveFloat", "PrimitiveString", "PrimitiveStringMultiline",
    ]

    // MARK: - Extract

    static func extract(_ graph: Graph, name: String) throws(WorkflowImportError) -> Result {
        var g = graph
        let all = g.nodes.values.sorted { (Int($0.id) ?? .max, $0.id) < (Int($1.id) ?? .max, $1.id) }
        var candidates = all.filter { samplers.contains($0.type) && !$0.bypassed }
        // Custom sampling (Flux 2 and others) is read as one sampler.
        for n in all where n.type == "SamplerCustomAdvanced" && !n.bypassed {
            let sampler = customSampler(n, in: g)
            g.nodes[n.id] = sampler
            candidates.append(sampler)
        }
        // The first pass starts from an empty latent; a hires-fix pass
        // starts from the first one's result.
        guard
            let sampler = candidates.first(where: { g.upstream($0, "latent_image")?.type.hasPrefix("Empty") == true })
                ?? candidates.first
        else { throw .noSampler }

        var used: Set<String> = [sampler.id]
        var notes: [String] = []
        var skipped: Set<String> = []

        // Model: back through the LoRA loaders to the checkpoint.
        var loras: [LoraSlot] = []
        var checkpoint: String?
        var splitModel = false
        var shift: Double?
        var current = g.upstream(sampler, "model")
        var hops = 0
        while let n = current, hops < 32 {
            hops += 1
            used.insert(n.id)
            if modelLoaders.contains(n.type) {
                splitModel = n.type != "CheckpointLoaderSimple"
                checkpoint = g.string(n, splitModel ? "unet_name" : "ckpt_name")
                break
            }
            if n.type == "ModelSamplingAuraFlow", !n.bypassed {
                shift = g.number(n, "shift")
                current = g.upstream(n, "model")
                continue
            }
            if loraLoaders.contains(n.type), !n.bypassed, let file = g.string(n, "lora_name") {
                let model = g.number(n, "strength_model") ?? 1
                let clip = n.type == "LoraLoader" ? g.number(n, "strength_clip") ?? model : 0
                loras.insert(LoraSlot(name: file, strength: model, clipStrength: clip == model ? nil : clip), at: 0)
            } else if !loraLoaders.contains(n.type), !n.bypassed {
                skipped.insert(n.type)
            }
            current = g.upstream(n, "model")
        }
        guard let checkpoint, !checkpoint.isEmpty else { throw .noCheckpoint }

        // Prompts: back through conditioning nodes (ControlNet, combine)
        // to the text encoder.
        var guidance: Double?
        var zeroedNegative = false
        func text(_ key: String) -> (String, Node)? {
            var n = g.upstream(sampler, key)
            var hops = 0
            while let c = n, hops < 32 {
                hops += 1
                used.insert(c.id)
                if textEncoders.contains(c.type) { return g.string(c, "text").map { ($0, c) } }
                // Flux has no negative: the prompt, zeroed out.
                if c.type == "ConditioningZeroOut", !c.bypassed {
                    zeroedNegative = true
                    return ("", c)
                }
                if c.type == "FluxGuidance", !c.bypassed {
                    guidance = g.number(c, "guidance") ?? guidance
                    n = g.upstream(c, "conditioning")
                    continue
                }
                if c.type == "CLIPTextEncodeSDXL" {
                    return (g.string(c, "text_g") ?? g.string(c, "text_l")).map { ($0, c) }
                }
                skipped.insert(c.type)
                n =
                    [key, "conditioning", "conditioning_to", "conditioning_1"].lazy.compactMap { g.upstream(c, $0) }
                    .first
            }
            return nil
        }
        let positive = text("positive")
        let negative = text("negative")

        // CLIP skip and the text encoders: along the positive encoder's clip input.
        var clipSkip = 1
        var encoders: [String] = []
        var clipType: String?
        var clipNode = positive.flatMap { g.upstream($0.1, "clip") }
        hops = 0
        while let n = clipNode, hops < 32 {
            hops += 1
            used.insert(n.id)
            if n.type == "CLIPSetLastLayer", let layer = g.number(n, "stop_at_clip_layer") {
                clipSkip = max(1, Int(-layer))
            }
            if clipLoaders.contains(n.type) {
                encoders = ["clip_name", "clip_name1", "clip_name2"].compactMap { g.string(n, $0) }
                clipType = g.string(n, "type")
                break
            }
            if n.type == "CheckpointLoaderSimple" { break }
            clipNode = g.upstream(n, "clip")
        }

        // Size: from the empty latent the sampler starts with.
        var size: (Int, Int)?
        if let latent = g.upstream(sampler, "latent_image") {
            used.insert(latent.id)
            if latent.type.hasPrefix("Empty"), let w = g.number(latent, "width"), let h = g.number(latent, "height") {
                size = (Int(w), Int(h))
            } else {
                skipped.insert(latent.type)
                notes.append("The workflow starts from a picture (\(latent.type)); Lightbox starts from an empty one.")
            }
        }

        let vae = all.first { $0.type == "VAELoader" && !$0.bypassed }.flatMap { g.string($0, "vae_name") }

        // Preset: what the checkpoint's name suggests, then the workflow's values.
        var detection = PresetDetector.detect(checkpoint: checkpoint, loras: loras.map(\.name))
        if splitModel, !detection.family.isSplit, let family = Self.family(clipType: clipType) {
            // A name the detector doesn't know; the text encoder's type tells.
            detection.family = family
            detection.notes.insert("\(family.label): its text encoder is loaded as “\(clipType!)”.", at: 0)
            if family == .zImage { detection.style = .photo }
        }
        let stem = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        var preset = detection.preset(checkpoint: checkpoint, name: stem.isEmpty ? nil : stem)
        notes.insert(contentsOf: detection.notes, at: 0)
        notes.append(
            splitModel
                ? "Diffusion model “\(checkpoint)” from the workflow’s \(sampler.type) model input."
                : "Checkpoint “\(checkpoint)” from the workflow’s \(sampler.type) model input.")
        if splitModel {
            preset.textEncoders = encoders
            if !encoders.isEmpty {
                notes.append(
                    "Text encoders \(encoders.map { "“\($0)”" }.joined(separator: " and ")) from the workflow.")
            }
            if let guidance {
                preset.guidance = guidance
                notes.append("Flux guidance \(guidance.formatted()) from FluxGuidance.")
            }
            if let shift {
                preset.shift = shift
                notes.append("Sampling shift \(shift.formatted()) from ModelSamplingAuraFlow.")
            }
        }

        var sampling: [String] = []
        if let s = g.string(sampler, "sampler_name") {
            preset.sampler = s
            sampling.append(s)
        }
        if let s = g.string(sampler, "scheduler") {
            preset.scheduler = s
            sampling.append(s)
        }
        if let steps = g.number(sampler, "steps") {
            preset.steps = Int(steps)
            sampling.append("\(Int(steps)) steps")
        }
        if let cfg = g.number(sampler, "cfg") {
            preset.cfg = cfg
            sampling.append("CFG \(cfg.formatted(.number.precision(.fractionLength(0...2))))")
        }
        if !sampling.isEmpty {
            notes.append("Sampling from \(sampler.type): \(sampling.joined(separator: ", ")).")
        }
        if let denoise = g.number(sampler, "denoise"), denoise < 1 {
            notes.append("The workflow's denoise of \(denoise.formatted()) isn't taken over; Lightbox uses 1.")
        }
        if candidates.count > 1 {
            notes.append("The workflow has \(candidates.count) samplers; the settings of the first pass were used.")
        }
        if let (w, h) = size {
            (preset.width, preset.height) = (w, h)
            notes.append("Size \(w) × \(h) from the empty latent image.")
        }
        preset.clipSkip = clipSkip
        if clipSkip > 1 { notes.append("CLIP skip \(clipSkip) from Set CLIP Last Layer.") }
        if let vae {
            preset.vae = vae
            notes.append("VAE “\(vae)” from Load VAE.")
        }
        preset.loras = loras
        for l in loras {
            notes.append("LoRA “\(l.name)” at \(l.strength.formatted(.number.precision(.fractionLength(0...2)))).")
        }
        if zeroedNegative {
            preset.negativePrompt = ""
            notes.append("No negative prompt: the workflow zeroes it out, as Flux needs.")
        } else if let negative {
            preset.negativePrompt = negative.0
            notes.append("Negative prompt from the workflow.")
        }
        if positive != nil {
            // The workflow's prompt already has its quality terms.
            preset.stylePrompt = ""
            notes.append("The workflow's prompt went into the prompt field, as it is; the style terms are left empty.")
        }

        for n in all where !used.contains(n.id) && !plumbing.contains(n.type) && !n.bypassed {
            if !loraLoaders.contains(n.type) && !textEncoders.contains(n.type) { skipped.insert(n.type) }
        }
        skipped.subtract(plumbing)
        if !skipped.isEmpty {
            notes.append("Not taken over: \(skipped.sorted().joined(separator: ", ")).")
        }
        preset.detectionNotes = notes
        let seed = (g.number(sampler, "seed") ?? g.number(sampler, "noise_seed")).map { Int($0) }
        return Result(
            preset: preset, prompt: positive?.0 ?? "", files: [checkpoint] + encoders + loras.map(\.name), seed: seed)
    }

    /// A `SamplerCustomAdvanced` with what its guider, sampler, scheduler
    /// and noise nodes say, as the inputs a KSampler would have them.
    static func customSampler(_ n: Node, in g: Graph) -> Node {
        var v = Node(id: n.id, type: n.type)
        v.inputs["latent_image"] = n.inputs["latent_image"]
        if let guider = g.upstream(n, "guider") {
            v.inputs["model"] = guider.inputs["model"]
            v.inputs["positive"] = guider.inputs["positive"] ?? guider.inputs["conditioning"]
            v.inputs["negative"] = guider.inputs["negative"]
            // BasicGuider has no CFG: it is 1.
            v.inputs["cfg"] = g.number(guider, "cfg").map(Value.number) ?? .number(1)
        }
        if let select = g.upstream(n, "sampler"), let name = g.string(select, "sampler_name") {
            v.inputs["sampler_name"] = .string(name)
        }
        if let sigmas = g.upstream(n, "sigmas") {
            if let steps = g.number(sigmas, "steps") { v.inputs["steps"] = .number(steps) }
            if let scheduler = g.string(sigmas, "scheduler") { v.inputs["scheduler"] = .string(scheduler) }
        }
        if let noise = g.upstream(n, "noise"), let seed = g.number(noise, "noise_seed") {
            v.inputs["seed"] = .number(seed)
        }
        return v
    }

    /// The family a split model's text encoder type stands for.
    static func family(clipType: String?) -> ModelFamily? {
        switch clipType {
        case "flux": .flux
        case "flux2": .flux2
        case "lumina2": .zImage
        case nil: nil
        default: .unsupported
        }
    }
}

// The values of the nodes Lightbox manages, read back from a node-editor
// document: by role, and as the settings of a request. Comparing those
// with what a request puts in its graph shows what was changed there.

import Foundation

/// What a request puts in the widgets of its graph. Pictures, prompts'
/// conventions and the kind of each guide are not in here: they are set
/// outside the graph.
public struct GraphSettings: Equatable, Sendable {
    public struct Guide: Equatable, Sendable {
        public var strength: Double
        public var start: Double
        public var end: Double

        public init(strength: Double, start: Double, end: Double) {
            self.strength = strength
            self.start = start
            self.end = end
        }
    }

    public struct Fix: Equatable, Sendable {
        public var detector: String
        public var denoise: Double
        public var guideSize: Int

        public init(detector: String, denoise: Double, guideSize: Int) {
            self.detector = detector
            self.denoise = denoise
            self.guideSize = guideSize
        }
    }

    public var checkpoint: String?
    public var diffusionModel: String?
    public var textEncoders: [String] = []
    public var clipType: String?
    /// A VAE loaded on its own.
    public var vae: String?
    /// In the order they are chained.
    public var loras: [LoraRequest] = []
    public var shift: Double?
    public var clipSkip = 1
    public var positive = ""
    /// `nil` when the negative is zeroed out (Flux).
    public var negative: String?
    public var guidance: Double?
    /// `nil` when inpainting, which takes the size of the picture.
    public var width: Int?
    public var height: Int?
    public var batchSize: Int?
    public var seed = 0
    public var steps = 0
    public var cfg = 0.0
    public var sampler = ""
    /// `nil` for Flux 2, whose schedule has no name.
    public var scheduler: String?
    public var denoise = 1.0
    /// By position in the request.
    public var guides: [Int: Guide] = [:]
    public var faceFix: Fix?
    public var handFix: Fix?

    public init() {}

    /// The settings `WorkflowBuilder.build` puts in the graph of `r`.
    public init(_ r: GenerationRequest) {
        let flux2 = r.split?.sampling == .flux2
        if let split = r.split {
            diffusionModel = split.model
            textEncoders =
                split.textEncoders.count >= 2 ? Array(split.textEncoders.prefix(2)) : [split.textEncoders.first ?? ""]
            clipType = split.clipType
            vae = split.vae
            shift = split.shift
            guidance = split.guidance
        } else {
            checkpoint = r.checkpoint
            vae = r.vae.flatMap { $0.isEmpty ? nil : $0 }
            clipSkip = max(1, r.clipSkip)
        }
        loras = r.loras
        positive = r.positive
        negative = r.split?.zeroNegative == true ? nil : r.negative
        if r.inpaint == nil || flux2 { (width, height) = (r.width, r.height) }
        if r.inpaint == nil { batchSize = max(1, r.batchSize) }
        (seed, steps, cfg, sampler) = (r.seed, r.steps, r.cfg, r.sampler)
        scheduler = flux2 ? nil : r.scheduler
        if let source = r.inpaint { denoise = min(max(source.denoise, 0.05), 1) }
        for (i, g) in r.guides.enumerated() {
            guides[i] = Guide(strength: g.strength, start: g.startPercent, end: g.endPercent)
        }
        if !flux2 {
            faceFix = r.faceFix.map { Fix(detector: $0.detector, denoise: $0.denoise, guideSize: $0.guideSize) }
            handFix = r.handFix.map { Fix(detector: $0.detector, denoise: $0.denoise, guideSize: $0.guideSize) }
        }
    }
}

/// The nodes of a document that have a role, with their values.
public struct ManagedGraph: Equatable, Sendable {
    /// Role → node id. If two nodes have the same role, the first counts.
    public var nodes: [NodeRole: Int] = [:]
    /// Role → widget values by input name.
    public var values: [NodeRole: [String: JSONValue]] = [:]
    /// Roles the graph can't run without, as it is built.
    public var missing: [NodeRole] = []
    public var settings = GraphSettings()

    public init(_ doc: WorkflowDocument, catalog: ComfyCatalog) {
        var types: [NodeRole: String] = [:]
        for n in doc.graph.nodes.sorted(by: { $0.id < $1.id }) {
            guard let text = n.properties[WorkflowDocument.roleProperty]?.string, let role = NodeRole(text),
                nodes[role] == nil
            else { continue }
            nodes[role] = n.id
            types[role] = n.type
            values[role] = Self.values(n, catalog: catalog)
        }
        missing = Self.missing(Set(nodes.keys), samplerType: types[NodeRole(.sampler)])
        settings = readSettings(types)
    }

    static func values(_ n: GraphNode, catalog: ComfyCatalog) -> [String: JSONValue] {
        switch n.widgetsValues {
        case .object(let named)?: return named
        case .array(let list)?:
            guard let spec = catalog.nodes[n.type] else { return [:] }
            return WidgetLayout.slots(spec, values: list).values.mapValues { list[$0] }
        default: return [:]
        }
    }

    /// The main roles every graph needs, and the parts each role needs.
    static func missing(_ roles: Set<NodeRole>, samplerType: String?) -> [NodeRole] {
        var needed: [NodeRole] = []
        if roles.contains(NodeRole(.diffusionModel)) {
            needed += [NodeRole(.textEncoders), NodeRole(.vae)]
        } else if !roles.contains(NodeRole(.checkpoint)) {
            needed.append(NodeRole(.checkpoint))
        }
        needed += [NodeRole(.positive), NodeRole(.negative), NodeRole(.sampler), NodeRole(.vaeDecode)]
        needed.append(NodeRole(.output))
        if !roles.contains(NodeRole(.inpaint)) { needed.append(NodeRole(.latent)) }
        if samplerType == "SamplerCustomAdvanced" {
            needed += [.noise, .guider, .select, .scheduler].map { NodeRole(.sampler, $0) }
        }
        let parts: [NodeRole.Kind: [NodeRole.Part]] = [
            .guide: [.image, .loader], .reference: [.image, .encode], .inpaint: [.image, .encode, .mask],
            .faceFix: [.detector], .handFix: [.detector],
        ]
        for role in roles where role.part == nil {
            for part in parts[role.kind] ?? [] { needed.append(NodeRole(role.kind, part, key: role.key)) }
        }
        return needed.filter { !roles.contains($0) }.sorted { $0.description < $1.description }
    }

    func value(_ role: NodeRole, _ input: String) -> JSONValue? { values[role]?[input] }

    func readSettings(_ types: [NodeRole: String]) -> GraphSettings {
        var s = GraphSettings()
        s.checkpoint = value(NodeRole(.checkpoint), "ckpt_name")?.string
        s.diffusionModel = value(NodeRole(.diffusionModel), "unet_name")?.string
        let encoders = NodeRole(.textEncoders)
        s.textEncoders = ["clip_name1", "clip_name2", "clip_name"].compactMap { value(encoders, $0)?.string }
        s.clipType = value(encoders, "type")?.string
        s.vae = value(NodeRole(.vae), "vae_name")?.string
        let loras = nodes.filter { $0.key.kind == .lora && $0.key.part == nil }.sorted { $0.value < $1.value }
        s.loras = loras.compactMap { role, _ in
            guard let name = value(role, "lora_name")?.string, let model = value(role, "strength_model")?.double
            else { return nil }
            return LoraRequest(name: name, strength: model, clipStrength: value(role, "strength_clip")?.double)
        }
        s.shift = value(NodeRole(.shift), "shift")?.double
        s.clipSkip = value(NodeRole(.clipSkip), "stop_at_clip_layer")?.int.map { -$0 } ?? 1
        s.positive = value(NodeRole(.positive), "text")?.string ?? ""
        s.negative =
            types[NodeRole(.negative)] == "ConditioningZeroOut"
            ? nil : value(NodeRole(.negative), "text")?.string ?? ""
        s.guidance = value(NodeRole(.guidance), "guidance")?.double

        let latent = NodeRole(.latent)
        let schedule = NodeRole(.sampler, .scheduler)
        s.width = (value(latent, "width") ?? value(schedule, "width"))?.int
        s.height = (value(latent, "height") ?? value(schedule, "height"))?.int
        s.batchSize = value(latent, "batch_size")?.int

        let sampler = NodeRole(.sampler)
        if types[sampler] == "SamplerCustomAdvanced" {
            s.seed = value(NodeRole(.sampler, .noise), "noise_seed")?.int ?? 0
            s.steps = value(schedule, "steps")?.int ?? 0
            s.cfg = value(NodeRole(.sampler, .guider), "cfg")?.double ?? 0
            s.sampler = value(NodeRole(.sampler, .select), "sampler_name")?.string ?? ""
            s.denoise = value(NodeRole(.sampler, .sigmas), "denoise")?.double ?? 1
        } else {
            s.seed = value(sampler, "seed")?.int ?? 0
            s.steps = value(sampler, "steps")?.int ?? 0
            s.cfg = value(sampler, "cfg")?.double ?? 0
            s.sampler = value(sampler, "sampler_name")?.string ?? ""
            s.scheduler = value(sampler, "scheduler")?.string
            s.denoise = value(sampler, "denoise")?.double ?? 1
        }

        for (role, _) in nodes where role.kind == .guide && role.part == nil {
            guard let i = role.key.flatMap({ Int($0) }) else { continue }
            // ControlNet or IP-Adapter.
            let names =
                types[role] == "IPAdapterAdvanced"
                ? ("weight", "start_at", "end_at") : ("strength", "start_percent", "end_percent")
            guard let strength = value(role, names.0)?.double, let start = value(role, names.1)?.double,
                let end = value(role, names.2)?.double
            else { continue }
            s.guides[i] = GraphSettings.Guide(strength: strength, start: start, end: end)
        }
        s.faceFix = fix(.faceFix)
        s.handFix = fix(.handFix)
        return s
    }

    func fix(_ kind: NodeRole.Kind) -> GraphSettings.Fix? {
        let role = NodeRole(kind)
        guard nodes[role] != nil, let denoise = value(role, "denoise")?.double else { return nil }
        return GraphSettings.Fix(
            detector: value(NodeRole(kind, .detector), "model_name")?.string ?? "", denoise: denoise,
            guideSize: value(role, "guide_size")?.int ?? 0)
    }
}

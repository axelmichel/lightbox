// ComfyUI workflows in API format: `{"<id>": {"class_type": ..., "inputs": {...}}}`,
// where a link to another node's output is `["<id>", <slot>]`.
//
// Graphs are built in code (as Krita AI Diffusion does) rather than from
// JSON templates: optional parts such as a LoRA chain, guides or the face
// fix rewire the graph instead of leaving dangling template slots.

import Foundation

public enum NodeInput: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case link(String, Int)
    /// Lists and objects some custom nodes take.
    case json(JSONValue)

    var json: Any {
        switch self {
        case .string(let s): s
        case .int(let i): i
        case .double(let d): d
        case .bool(let b): b
        case .link(let id, let slot): [id, slot] as [Any]
        case .json(let v): v.any
        }
    }
}

public struct WorkflowNode: Equatable, Sendable {
    public var classType: String
    public var inputs: [String: NodeInput]

    public init(classType: String, inputs: [String: NodeInput]) {
        self.classType = classType
        self.inputs = inputs
    }
}

/// An output of a node, used to wire the next one.
public struct Output: Hashable, Sendable {
    public var node: String
    public var slot: Int

    public init(node: String, slot: Int) {
        self.node = node
        self.slot = slot
    }

    var input: NodeInput { .link(node, slot) }
}

public struct WorkflowGraph: Equatable, Sendable {
    public private(set) var nodes: [String: WorkflowNode] = [:]
    private var nextID = 1

    public init() {}

    /// A graph with its node ids already chosen (from the node editor,
    /// where subgraph nodes have ids like "5:3").
    public init(nodes: [String: WorkflowNode]) {
        self.nodes = nodes
        nextID = (nodes.keys.compactMap { Int($0) }.max() ?? 0) + 1
    }

    /// Put a node in under an id of the caller's choosing.
    public mutating func set(_ id: String, _ node: WorkflowNode) {
        nodes[id] = node
        if let n = Int(id) { nextID = max(nextID, n + 1) }
    }

    /// Add a node and return its id.
    @discardableResult
    public mutating func add(_ classType: String, _ inputs: [String: NodeInput]) -> String {
        let id = String(nextID)
        nextID += 1
        nodes[id] = WorkflowNode(classType: classType, inputs: inputs)
        return id
    }

    /// Add a node, filling the required inputs not given with the server's
    /// defaults. Keeps nodes with many knobs (FaceDetailer) working across
    /// versions that add inputs.
    @discardableResult
    public mutating func add(_ classType: String, _ inputs: [String: NodeInput], defaultsFrom catalog: ComfyCatalog)
        -> String
    {
        var all = inputs
        if let spec = catalog.nodes[classType] {
            for name in spec.required where all[name] == nil {
                guard let input = spec.inputs[name], !input.isLink else { continue }
                if let value = input.defaultValue ?? input.options.first.map(NodeInput.string) {
                    all[name] = value
                }
            }
            // Sampler lists differ between nodes; fall back instead of failing.
            for name in ["sampler_name", "scheduler"] {
                if case .string(let value)? = all[name], let options = spec.inputs[name]?.options,
                    !options.isEmpty, !options.contains(value)
                {
                    all[name] = spec.inputs[name]?.defaultValue ?? .string(options[0])
                }
            }
        }
        return add(classType, all)
    }

    public func jsonObject() -> [String: Any] {
        nodes.mapValues { node in
            ["class_type": node.classType, "inputs": node.inputs.mapValues(\.json)] as [String: Any]
        }
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(), options: [.sortedKeys])
    }

    /// Ids of nodes with the given class, in creation order.
    public func ids(of classType: String) -> [String] {
        nodes.filter { $0.value.classType == classType }.map(\.key).sorted {
            $0.count != $1.count ? $0.count < $1.count : $0 < $1
        }
    }
}

public enum Preprocessor: Equatable, Hashable, Sendable {
    /// ComfyUI's built-in edge detector.
    case canny(low: Double, high: Double)
    /// A comfyui_controlnet_aux preprocessor, e.g. "LineArtPreprocessor".
    case aux(String, resolution: Int)
}

/// A guide image with its setup (see `ControlResolver`).
public struct GuideRequest: Equatable, Sendable {
    public var setup: ControlSetup
    /// The picture; uploaded by `ComfyClient.generate`.
    public var image: Data
    public var filename: String
    /// Name in ComfyUI's input folder, set after the upload.
    public var imageName: String = ""
    /// Run the setup's extractor (lines, depth, pose) on the picture first.
    public var extract: Bool
    public var strength: Double
    public var startPercent: Double
    public var endPercent: Double

    public init(
        setup: ControlSetup, image: Data, filename: String, extract: Bool = true, strength: Double = 0.7,
        startPercent: Double = 0, endPercent: Double = 1
    ) {
        self.setup = setup
        self.image = image
        self.filename = filename
        self.extract = extract
        self.strength = strength
        self.startPercent = startPercent
        self.endPercent = endPercent
    }
}

/// A second pass that finds faces (or hands) and redraws them at a higher
/// resolution, so small faces in wide shots get proper detail.
public struct DetailerRequest: Equatable, Sendable {
    /// Detector file, e.g. "bbox/face_yolov8m.pt".
    public var detector: String
    /// How much is redrawn: 0.3 keeps the face, 0.6 reinvents it.
    public var denoise: Double
    /// The size a detected region is redrawn at.
    public var guideSize: Int

    public init(detector: String, denoise: Double = 0.4, guideSize: Int = 768) {
        self.detector = detector
        self.denoise = denoise
        self.guideSize = guideSize
    }
}

public struct LoraRequest: Equatable, Sendable {
    public var name: String
    /// Effect on the image model.
    public var strength: Double
    /// Effect on the text encoder.
    public var clipStrength: Double

    public init(name: String, strength: Double, clipStrength: Double? = nil) {
        self.name = name
        self.strength = strength
        self.clipStrength = clipStrength ?? strength
    }
}

/// A picture an edit model works from (`ReferenceLatent`): it changes the
/// picture as the prompt says, instead of making a new one.
public struct ReferenceImage: Equatable, Sendable {
    /// PNG.
    public var image: Data
    /// Base of the file name in ComfyUI's input folder.
    public var filename: String
    /// The name after upload.
    public var imageName = ""

    public init(image: Data, filename: String) {
        self.image = image
        self.filename = filename
    }
}

/// Paint part of a picture again (inpainting): the picture is encoded
/// instead of starting from noise, and only the masked part is sampled.
public struct InpaintSource: Equatable, Sendable {
    /// PNG at the request's width × height.
    public var image: Data
    /// PNG of the same size; red 255 = paint again, 0 = keep.
    public var mask: Data
    /// How much the masked part may change (0…1).
    public var denoise: Double
    /// Base of the file names in ComfyUI's input folder.
    public var filename: String
    /// Names after upload.
    public var imageName = ""
    public var maskName = ""

    public init(image: Data, mask: Data, denoise: Double, filename: String) {
        self.image = image
        self.mask = mask
        self.denoise = denoise
        self.filename = filename
    }
}

/// A model that comes as separate files instead of one checkpoint (Flux,
/// Z-Image): the diffusion model, its text encoders and the VAE. GGUF
/// files (`.gguf`) are loaded with the ComfyUI-GGUF nodes.
public struct SplitModelRequest: Equatable, Sendable {
    /// In `diffusion_models` (or `unet`).
    public var model: String
    /// One (`CLIPLoader`) or two (`DualCLIPLoader`) files in `text_encoders`.
    public var textEncoders: [String]
    /// The loader's `type`: "flux", "lumina2" (Z-Image), …
    public var clipType: String
    public var vae: String
    /// `FluxGuidance` on the prompt; `nil` = none.
    public var guidance: Double?
    /// `ModelSamplingAuraFlow` shift; `nil` = none.
    public var shift: Double?
    /// The negative is the prompt zeroed out (Flux has no negative prompt).
    public var zeroNegative: Bool
    public var sampling: Sampling

    public enum Sampling: Equatable, Sendable {
        /// `KSampler` from an empty SD3-style latent (Flux.1, Z-Image).
        case standard
        /// Flux 2: `SamplerCustomAdvanced` with `Flux2Scheduler`, whose
        /// sigmas depend on the picture size, from `EmptyFlux2LatentImage`.
        case flux2
    }

    public init(
        model: String, textEncoders: [String], clipType: String, vae: String, guidance: Double? = nil,
        shift: Double? = nil, zeroNegative: Bool = false, sampling: Sampling = .standard
    ) {
        self.model = model
        self.textEncoders = textEncoders
        self.clipType = clipType
        self.vae = vae
        self.guidance = guidance
        self.shift = shift
        self.zeroNegative = zeroNegative
        self.sampling = sampling
    }

    static func isGGUF(_ file: String) -> Bool { file.lowercased().hasSuffix(".gguf") }

    /// The nodes this needs besides the core ones every graph has.
    public var requiredNodes: [String] {
        loaderNodes
            + (sampling == .flux2
                ? [
                    "EmptyFlux2LatentImage", "Flux2Scheduler", "RandomNoise", "CFGGuider", "KSamplerSelect",
                    "SamplerCustomAdvanced",
                ]
                : ["EmptySD3LatentImage"])
    }

    /// The loader nodes this needs.
    public var loaderNodes: [String] {
        let modelLoader = Self.isGGUF(model) ? "UnetLoaderGGUF" : "UNETLoader"
        let gguf = textEncoders.contains(where: Self.isGGUF)
        let clipLoader =
            textEncoders.count >= 2
            ? (gguf ? "DualCLIPLoaderGGUF" : "DualCLIPLoader") : (gguf ? "CLIPLoaderGGUF" : "CLIPLoader")
        return [modelLoader, clipLoader, "VAELoader"]
    }
}

/// One generation, in ComfyUI terms: text to image, or with `inpaint`
/// part of a picture painted again.
public struct GenerationRequest: Equatable, Sendable {
    /// Ignored when `split` is set.
    public var checkpoint: String
    public var vae: String?
    public var loras: [LoraRequest]
    public var positive: String
    public var negative: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var cfg: Double
    public var sampler: String
    public var scheduler: String
    public var seed: Int
    public var batchSize: Int
    /// 1 = off.
    public var clipSkip: Int
    public var guides: [GuideRequest]
    public var faceFix: DetailerRequest?
    public var handFix: DetailerRequest?
    /// Paint part of a picture again instead of a new one; one picture per run.
    public var inpaint: InpaintSource?
    /// Load the model from separate files instead of `checkpoint`.
    public var split: SplitModelRequest?
    /// Pictures to edit (edit models such as Flux 2): each is encoded and
    /// set as a reference on the prompt.
    public var references: [ReferenceImage] = []

    public init(
        checkpoint: String, vae: String? = nil, loras: [LoraRequest] = [], positive: String,
        negative: String, width: Int = 1024, height: Int = 1024, steps: Int = 25, cfg: Double = 6,
        sampler: String = "dpmpp_2m", scheduler: String = "karras", seed: Int, batchSize: Int = 1,
        clipSkip: Int = 1, guides: [GuideRequest] = [], faceFix: DetailerRequest? = nil,
        handFix: DetailerRequest? = nil, inpaint: InpaintSource? = nil, split: SplitModelRequest? = nil
    ) {
        self.checkpoint = checkpoint
        self.vae = vae
        self.loras = loras
        self.positive = positive
        self.negative = negative
        self.width = width
        self.height = height
        self.steps = steps
        self.cfg = cfg
        self.sampler = sampler
        self.scheduler = scheduler
        self.seed = seed
        self.batchSize = batchSize
        self.clipSkip = clipSkip
        self.guides = guides
        self.faceFix = faceFix
        self.handFix = handFix
        self.inpaint = inpaint
        self.split = split
    }
}

public enum WorkflowBuilder {
    /// Checkpoint (or split model) → LoRAs → (CLIP skip or sampling shift)
    /// → prompts (with Flux guidance) → IP-Adapters and ControlNets →
    /// KSampler → VAE decode → face/hand fix → PreviewImage.
    /// With `inpaint` the KSampler starts from the encoded picture, masked.
    /// Preview images live in ComfyUI's temp folder, so nothing piles up in
    /// its output folder.
    public static func txt2img(_ r: GenerationRequest, catalog: ComfyCatalog) -> WorkflowGraph {
        build(r, catalog: catalog).graph
    }

    /// The graph of `txt2img`, with the role of every node and the ends of
    /// its chains.
    public static func build(_ r: GenerationRequest, catalog: ComfyCatalog) -> BuiltWorkflow {
        var g = RoleRecorder()
        var model: Output
        var clip: Output
        var vae: Output
        if let split = r.split {
            let loaders = split.loaderNodes
            var unet: [String: NodeInput] = ["unet_name": .string(split.model)]
            if loaders[0] == "UNETLoader" { unet["weight_dtype"] = .string("default") }
            model = Output(node: g.add(NodeRole(.diffusionModel), loaders[0], unet), slot: 0)
            var encoders: [String: NodeInput] = ["type": .string(split.clipType)]
            if split.textEncoders.count >= 2 {
                encoders["clip_name1"] = .string(split.textEncoders[0])
                encoders["clip_name2"] = .string(split.textEncoders[1])
            } else {
                encoders["clip_name"] = .string(split.textEncoders.first ?? "")
            }
            clip = Output(node: g.add(NodeRole(.textEncoders), loaders[1], encoders), slot: 0)
            vae = Output(node: g.add(NodeRole(.vae), "VAELoader", ["vae_name": .string(split.vae)]), slot: 0)
        } else {
            let ckpt = g.add(NodeRole(.checkpoint), "CheckpointLoaderSimple", ["ckpt_name": .string(r.checkpoint)])
            model = Output(node: ckpt, slot: 0)
            clip = Output(node: ckpt, slot: 1)
            vae = Output(node: ckpt, slot: 2)
            if let name = r.vae, !name.isEmpty {
                vae = Output(node: g.add(NodeRole(.vae), "VAELoader", ["vae_name": .string(name)]), slot: 0)
            }
        }
        for lora in r.loras {
            let id = g.add(
                NodeRole(.lora, key: lora.name), "LoraLoader",
                [
                    "model": model.input, "clip": clip.input, "lora_name": .string(lora.name),
                    "strength_model": .double(lora.strength), "strength_clip": .double(lora.clipStrength),
                ])
            model = Output(node: id, slot: 0)
            clip = Output(node: id, slot: 1)
        }
        if let shift = r.split?.shift {
            let id = g.add(
                NodeRole(.shift), "ModelSamplingAuraFlow", ["model": model.input, "shift": .double(shift)])
            model = Output(node: id, slot: 0)
        }
        if r.clipSkip > 1, r.split == nil {
            let id = g.add(
                NodeRole(.clipSkip), "CLIPSetLastLayer",
                ["clip": clip.input, "stop_at_clip_layer": .int(-r.clipSkip)])
            clip = Output(node: id, slot: 0)
        }

        let encoded = Output(
            node: g.add(NodeRole(.positive), "CLIPTextEncode", ["text": .string(r.positive), "clip": clip.input]),
            slot: 0)
        var textPositive = encoded
        if let guidance = r.split?.guidance {
            let id = g.add(
                NodeRole(.guidance), "FluxGuidance", ["conditioning": encoded.input, "guidance": .double(guidance)])
            textPositive = Output(node: id, slot: 0)
        }
        // Edit models: the pictures to change, as references on the prompt.
        for (i, reference) in r.references.enumerated() {
            let key = String(i)
            let pixels = g.add(
                NodeRole(.reference, .image, key: key), "LoadImage", ["image": .string(reference.imageName)])
            let encoded = g.add(
                NodeRole(.reference, .encode, key: key), "VAEEncode", ["pixels": .link(pixels, 0), "vae": vae.input])
            let id = g.add(
                NodeRole(.reference, key: key), "ReferenceLatent",
                ["conditioning": textPositive.input, "latent": .link(encoded, 0)])
            textPositive = Output(node: id, slot: 0)
        }
        let textNegative =
            r.split?.zeroNegative == true
            ? Output(node: g.add(NodeRole(.negative), "ConditioningZeroOut", ["conditioning": encoded.input]), slot: 0)
            : Output(
                node: g.add(NodeRole(.negative), "CLIPTextEncode", ["text": .string(r.negative), "clip": clip.input]),
                slot: 0)
        // The fix passes use the character LoRAs but not the guides: a pose
        // or composition of the whole image means nothing for a face crop.
        let detailModel = model
        var positive = textPositive
        var negative = textNegative

        for (i, guide) in r.guides.enumerated() {
            let key = String(i)
            let loaded = Output(
                node: g.add(NodeRole(.guide, .image, key: key), "LoadImage", ["image": .string(guide.imageName)]),
                slot: 0)
            switch guide.setup {
            case .controlNet(let name, let unionType, let extractor):
                var image = loaded
                if guide.extract, let extractor {
                    image = preprocess(&g, NodeRole(.guide, .extract, key: key), image, extractor, catalog)
                }
                var controlNet = Output(
                    node: g.add(
                        NodeRole(.guide, .loader, key: key), "ControlNetLoader", ["control_net_name": .string(name)]),
                    slot: 0)
                if let unionType {
                    let id = g.add(
                        NodeRole(.guide, .unionType, key: key), "SetUnionControlNetType",
                        ["control_net": controlNet.input, "type": .string(unionType)])
                    controlNet = Output(node: id, slot: 0)
                }
                var inputs: [String: NodeInput] = [
                    "positive": positive.input, "negative": negative.input, "control_net": controlNet.input,
                    "image": image.input, "strength": .double(guide.strength),
                    "start_percent": .double(guide.startPercent), "end_percent": .double(guide.endPercent),
                ]
                if catalog.controlNetTakesVAE { inputs["vae"] = vae.input }
                let apply = g.add(NodeRole(.guide, key: key), "ControlNetApplyAdvanced", inputs)
                positive = Output(node: apply, slot: 0)
                negative = Output(node: apply, slot: 1)

            case .ipAdapter(let name, let clipVision, let weightType):
                let adapter = g.add(
                    NodeRole(.guide, .loader, key: key), "IPAdapterModelLoader", ["ipadapter_file": .string(name)])
                let vision = g.add(
                    NodeRole(.guide, .clipVision, key: key), "CLIPVisionLoader", ["clip_name": .string(clipVision)])
                let id = g.add(
                    NodeRole(.guide, key: key), "IPAdapterAdvanced",
                    [
                        "model": model.input, "ipadapter": .link(adapter, 0), "image": loaded.input,
                        "clip_vision": .link(vision, 0), "weight": .double(guide.strength),
                        "weight_type": .string(weightType), "start_at": .double(guide.startPercent),
                        "end_at": .double(guide.endPercent),
                    ], defaultsFrom: catalog)
                model = Output(node: id, slot: 0)
            }
        }

        let latent: Output
        var denoise = 1.0
        let flux2 = r.split?.sampling == .flux2
        if let source = r.inpaint {
            // The noise mask keeps the rest of the latent as it is, so any
            // checkpoint works and `denoise` below 1 keeps the shapes.
            let pixels = g.add(NodeRole(.inpaint, .image), "LoadImage", ["image": .string(source.imageName)])
            let encoded = g.add(
                NodeRole(.inpaint, .encode), "VAEEncode", ["pixels": .link(pixels, 0), "vae": vae.input])
            let mask = g.add(
                NodeRole(.inpaint, .mask), "LoadImageMask",
                ["image": .string(source.maskName), "channel": .string("red")])
            latent = Output(
                node: g.add(
                    NodeRole(.inpaint), "SetLatentNoiseMask", ["samples": .link(encoded, 0), "mask": .link(mask, 0)]),
                slot: 0)
            denoise = min(max(source.denoise, 0.05), 1)
        } else {
            // Flux and Z-Image have 16-channel latents, Flux 2 its own.
            let id = g.add(
                NodeRole(.latent),
                flux2 ? "EmptyFlux2LatentImage" : r.split == nil ? "EmptyLatentImage" : "EmptySD3LatentImage",
                ["width": .int(r.width), "height": .int(r.height), "batch_size": .int(max(1, r.batchSize))])
            latent = Output(node: id, slot: 0)
        }
        let sampled: Output
        if flux2 {
            let noise = g.add(NodeRole(.sampler, .noise), "RandomNoise", ["noise_seed": .int(r.seed)])
            let guider = g.add(
                NodeRole(.sampler, .guider), "CFGGuider",
                ["model": model.input, "positive": positive.input, "negative": negative.input, "cfg": .double(r.cfg)])
            let select = g.add(NodeRole(.sampler, .select), "KSamplerSelect", ["sampler_name": .string(r.sampler)])
            var sigmas = Output(
                node: g.add(
                    NodeRole(.sampler, .scheduler), "Flux2Scheduler",
                    ["steps": .int(r.steps), "width": .int(r.width), "height": .int(r.height)]),
                slot: 0)
            if denoise < 1 {
                // The low end of the schedule: only that much noise is added.
                let split = g.add(
                    NodeRole(.sampler, .sigmas), "SplitSigmasDenoise",
                    ["sigmas": sigmas.input, "denoise": .double(denoise)])
                sigmas = Output(node: split, slot: 1)
            }
            let id = g.add(
                NodeRole(.sampler), "SamplerCustomAdvanced",
                [
                    "noise": .link(noise, 0), "guider": .link(guider, 0), "sampler": .link(select, 0),
                    "sigmas": sigmas.input, "latent_image": latent.input,
                ])
            sampled = Output(node: id, slot: 0)
        } else {
            let id = g.add(
                NodeRole(.sampler), "KSampler",
                [
                    "model": model.input, "positive": positive.input, "negative": negative.input,
                    "latent_image": latent.input, "seed": .int(r.seed), "steps": .int(r.steps),
                    "cfg": .double(r.cfg), "sampler_name": .string(r.sampler), "scheduler": .string(r.scheduler),
                    "denoise": .double(denoise),
                ])
            sampled = Output(node: id, slot: 0)
        }
        var image = Output(
            node: g.add(NodeRole(.vaeDecode), "VAEDecode", ["samples": sampled.input, "vae": vae.input]), slot: 0)

        // FaceDetailer samples with a KSampler, which Flux 2's schedule doesn't fit.
        let fixes: [(NodeRole.Kind, DetailerRequest?)] = flux2 ? [] : [(.faceFix, r.faceFix), (.handFix, r.handFix)]
        for case (let kind, let fix?) in fixes {
            let detector = g.add(
                NodeRole(kind, .detector), "UltralyticsDetectorProvider", ["model_name": .string(fix.detector)])
            let id = g.add(
                NodeRole(kind), "FaceDetailer",
                [
                    "image": image.input, "model": detailModel.input, "clip": clip.input, "vae": vae.input,
                    "positive": textPositive.input, "negative": textNegative.input,
                    "bbox_detector": .link(detector, 0), "seed": .int(r.seed), "steps": .int(r.steps),
                    "cfg": .double(r.cfg), "sampler_name": .string(r.sampler), "scheduler": .string(r.scheduler),
                    "denoise": .double(fix.denoise), "guide_size": .double(Double(fix.guideSize)),
                    "max_size": .double(Double(max(1024, fix.guideSize))), "wildcard": .string(""),
                ], defaultsFrom: catalog)
            image = Output(node: id, slot: 0)
        }
        g.add(NodeRole(.output), "PreviewImage", ["images": image.input])
        return BuiltWorkflow(
            graph: g.graph, roles: g.roles,
            anchors: [
                .model: model, .clip: clip, .vae: vae, .positive: positive, .negative: negative, .latent: latent,
                .image: image,
            ])
    }

    static func preprocess(
        _ g: inout RoleRecorder, _ role: NodeRole, _ image: Output, _ p: Preprocessor, _ catalog: ComfyCatalog
    ) -> Output {
        switch p {
        case .canny(let low, let high):
            let id = g.add(
                role, "Canny", ["image": image.input, "low_threshold": .double(low), "high_threshold": .double(high)])
            return Output(node: id, slot: 0)
        case .aux(let name, let resolution):
            let node = catalog.auxPreprocessorNode ?? "AIO_Preprocessor"
            let id = g.add(
                role, node, ["image": image.input, "preprocessor": .string(name), "resolution": .int(resolution)])
            return Output(node: id, slot: 0)
        }
    }
}

import Foundation
import Testing

@testable import ComfyKit

/// Requests covering every way `WorkflowBuilder` builds a graph: both
/// loaders, LoRAs, guides, fix passes, inpainting and edit references.
private func requests() throws -> [(name: String, request: GenerationRequest)] {
    let c = try kritaCatalog()
    func guide(_ kind: ControlKind, _ file: String, arch: ModelArch = .illustrious, extract: Bool = true) throws
        -> GuideRequest
    {
        var g = GuideRequest(
            setup: try ControlResolver.resolve(kind, arch: arch, catalog: c).get(), image: Data(),
            filename: file, extract: extract, strength: 0.6, endPercent: 0.8)
        g.imageName = "lightbox/\(file)"
        return g
    }
    let face = DetailerRequest(detector: "bbox/face_yolov8m.pt", denoise: 0.35)
    let hand = DetailerRequest(detector: "bbox/hand_yolov8s.pt", denoise: 0.3, guideSize: 512)
    var inpaint = InpaintSource(image: Data([1]), mask: Data([2]), denoise: 0.6, filename: "edit")
    inpaint.imageName = "lightbox/edit.png"
    inpaint.maskName = "lightbox/edit-mask.png"
    var reference = ReferenceImage(image: Data([1]), filename: "ref")
    reference.imageName = "lightbox/ref.png"

    let base = GenerationRequest(
        checkpoint: "Sample_Illustrious_v1.safetensors",
        loras: [
            LoraRequest(name: "a.safetensors", strength: 0.8),
            LoraRequest(name: "styles/b.safetensors", strength: -0.5, clipStrength: 0),
        ],
        positive: "1girl, comic", negative: "lowres", width: 832, height: 1216, seed: 42, batchSize: 2, clipSkip: 2)
    var checkpoint = base
    checkpoint.vae = "sdxl-vae.safetensors"

    var guided = base
    guided.guides = [
        try guide(.depth, "a.png"), try guide(.scribble, "b.png", extract: false), try guide(.style, "c.png"),
    ]
    guided.faceFix = face
    guided.handFix = hand

    // A union ControlNet (SDXL on this server) with a canny pass.
    var union = base
    union.guides = [try guide(.depth, "a.png", arch: .sdxl), try guide(.canny, "b.png")]

    var inpainted = base
    inpainted.inpaint = inpaint
    inpainted.faceFix = face

    var flux = base
    flux.cfg = 1
    flux.faceFix = face
    flux.split = SplitModelRequest(
        model: "flux1-krea-Q4.gguf", textEncoders: ["t5-xxl-encoder-Q4.gguf", "clip_l.safetensors"],
        clipType: "flux", vae: "ae.safetensors", guidance: 4.5, zeroNegative: true)

    var zImage = base
    zImage.loras = [LoraRequest(name: "a.safetensors", strength: 0.8)]
    zImage.split = SplitModelRequest(
        model: "z_image_turbo-Q4.gguf", textEncoders: ["qwen3-4b-encoder-Q4.gguf"], clipType: "lumina2",
        vae: "ae.safetensors", shift: 3)

    var flux2 = base
    flux2.loras = []
    (flux2.steps, flux2.cfg, flux2.sampler) = (4, 1, "euler")
    flux2.faceFix = face
    flux2.split = SplitModelRequest(
        model: "flux-2-klein-9b-Q4.gguf", textEncoders: ["qwen_3_8b.safetensors"], clipType: "flux2",
        vae: "flux2-vae.safetensors", zeroNegative: true, sampling: .flux2)
    var flux2Edit = flux2
    flux2Edit.references = [reference]
    var flux2Inpaint = flux2
    flux2Inpaint.inpaint = inpaint

    return [
        ("checkpoint", checkpoint), ("checkpoint_guides_fixes", guided), ("checkpoint_union", union),
        ("checkpoint_inpaint", inpainted),
        ("flux", flux), ("zimage", zImage), ("flux2", flux2), ("flux2_edit", flux2Edit),
        ("flux2_inpaint", flux2Inpaint),
    ]
}

/// The API graphs `txt2img` gave before roles were added
/// (`Fixtures/built`). `RECORD_BUILT=1 swift test` writes them anew.
@Test func builtGraphsStayTheSame() throws {
    let c = try kritaCatalog()
    let record = ProcessInfo.processInfo.environment["RECORD_BUILT"] != nil
    for (name, r) in try requests() {
        let data = try WorkflowBuilder.txt2img(r, catalog: c).jsonData()
        if record {
            let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/built")
            try data.write(to: folder.appending(path: "\(name).json"))
        } else {
            let url = try #require(
                Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/built"), "\(name)")
            #expect(try Data(contentsOf: url) == data, "\(name)")
        }
    }
}

@Test func everyNodeHasItsOwnRole() throws {
    let c = try kritaCatalog()
    for (name, r) in try requests() {
        let built = WorkflowBuilder.build(r, catalog: c)
        #expect(Set(built.roles.keys) == Set(built.graph.nodes.keys), "\(name)")
        #expect(Set(built.roles.values).count == built.roles.count, "\(name): a role used twice")
    }
}

@Test func anchorsAreWhatTheSamplerAndOutputTake() throws {
    let c = try kritaCatalog()
    for (name, r) in try requests() {
        let built = WorkflowBuilder.build(r, catalog: c)
        let g = built.graph
        func node(_ role: NodeRole) throws -> WorkflowNode {
            try #require(built.ids(role).first.flatMap { g.nodes[$0] }, "\(name): no \(role)")
        }
        func anchor(_ a: Anchor) -> NodeInput? { built.anchors[a].map { .link($0.node, $0.slot) } }
        let conditioning =
            try r.split?.sampling == .flux2 ? node(NodeRole(.sampler, .guider)) : node(NodeRole(.sampler))
        #expect(conditioning.inputs["model"] == anchor(.model), "\(name)")
        #expect(conditioning.inputs["positive"] == anchor(.positive), "\(name)")
        #expect(conditioning.inputs["negative"] == anchor(.negative), "\(name)")
        #expect(try node(NodeRole(.sampler)).inputs["latent_image"] == anchor(.latent), "\(name)")
        #expect(try node(NodeRole(.vaeDecode)).inputs["vae"] == anchor(.vae), "\(name)")
        #expect(try node(NodeRole(.positive)).inputs["clip"] == anchor(.clip), "\(name)")
        #expect(try node(NodeRole(.output)).inputs["images"] == anchor(.image), "\(name)")
    }
}

@Test func rolesNameTheParts() throws {
    let c = try kritaCatalog()
    let all = Dictionary(
        uniqueKeysWithValues: try requests().map { ($0.name, WorkflowBuilder.build($0.request, catalog: c)) })
    func classes(_ name: String, _ role: NodeRole) -> [String] {
        let built = all[name]!
        return built.ids(role).compactMap { built.graph.nodes[$0]?.classType }
    }

    #expect(classes("checkpoint", NodeRole(.checkpoint)) == ["CheckpointLoaderSimple"])
    #expect(classes("checkpoint", NodeRole(.vae)) == ["VAELoader"])
    #expect(classes("checkpoint", NodeRole(.lora, key: "styles/b.safetensors")) == ["LoraLoader"])
    #expect(classes("checkpoint", NodeRole(.clipSkip)) == ["CLIPSetLastLayer"])
    #expect(classes("checkpoint", NodeRole(.negative)) == ["CLIPTextEncode"])

    let guided = "checkpoint_guides_fixes"
    #expect(classes(guided, NodeRole(.guide, key: "0")) == ["ControlNetApplyAdvanced"])
    #expect(classes(guided, NodeRole(.guide, .extract, key: "0")) == ["AIO_Preprocessor"])
    #expect(classes(guided, NodeRole(.guide, .extract, key: "1")).isEmpty)
    #expect(classes(guided, NodeRole(.guide, .image, key: "1")) == ["LoadImage"])
    #expect(classes(guided, NodeRole(.guide, key: "2")) == ["IPAdapterAdvanced"])
    #expect(classes(guided, NodeRole(.guide, .clipVision, key: "2")) == ["CLIPVisionLoader"])
    #expect(classes(guided, NodeRole(.faceFix)) == ["FaceDetailer"])
    #expect(classes(guided, NodeRole(.handFix, .detector)) == ["UltralyticsDetectorProvider"])

    #expect(classes("checkpoint_union", NodeRole(.guide, .unionType, key: "0")) == ["SetUnionControlNetType"])
    #expect(classes("checkpoint_union", NodeRole(.guide, .loader, key: "0")) == ["ControlNetLoader"])
    #expect(!classes("checkpoint_union", NodeRole(.guide, .extract, key: "1")).isEmpty)

    #expect(classes("checkpoint_inpaint", NodeRole(.inpaint)) == ["SetLatentNoiseMask"])
    #expect(classes("checkpoint_inpaint", NodeRole(.inpaint, .mask)) == ["LoadImageMask"])
    #expect(classes("checkpoint_inpaint", NodeRole(.latent)).isEmpty)

    #expect(classes("flux", NodeRole(.diffusionModel)) == ["UnetLoaderGGUF"])
    #expect(classes("flux", NodeRole(.textEncoders)) == ["DualCLIPLoaderGGUF"])
    #expect(classes("flux", NodeRole(.guidance)) == ["FluxGuidance"])
    #expect(classes("flux", NodeRole(.negative)) == ["ConditioningZeroOut"])
    #expect(classes("zimage", NodeRole(.shift)) == ["ModelSamplingAuraFlow"])

    #expect(classes("flux2", NodeRole(.sampler)) == ["SamplerCustomAdvanced"])
    #expect(classes("flux2", NodeRole(.sampler, .scheduler)) == ["Flux2Scheduler"])
    #expect(classes("flux2", NodeRole(.faceFix)).isEmpty)  // skipped for Flux 2
    #expect(classes("flux2_edit", NodeRole(.reference, key: "0")) == ["ReferenceLatent"])
    #expect(classes("flux2_inpaint", NodeRole(.sampler, .sigmas)) == ["SplitSigmasDenoise"])
}

@Test func rolesReadBackFromText() {
    for role in [
        NodeRole(.sampler), NodeRole(.guide, .loader, key: "0"), NodeRole(.lora, key: "styles/b.v2:x.safetensors"),
        NodeRole(.faceFix, .detector), NodeRole(.lora, key: ""),
    ] {
        #expect(NodeRole(role.description) == role, "\(role)")
    }
    #expect(NodeRole("guide.loader:0") == NodeRole(.guide, .loader, key: "0"))
    for bad in ["", "bogus", "lora.nope:x", "guide.loader.image:0", ".image"] {
        #expect(NodeRole(bad) == nil, "\(bad)")
    }
}

/// Projected and compiled again, a request gives the graph `txt2img`
/// sends, so both ways of sending stay the same. The document holds a
/// value for every widget, so the compiled graph also has the optional
/// inputs the builder leaves out, at the server's default.
@Test func projectionCompilesToTheBuiltGraph() throws {
    let c = try kritaCatalog()
    for (name, r) in try requests() {
        let built = WorkflowBuilder.build(r, catalog: c)
        let compiled = WorkflowCompiler.compile(try WorkflowDocument(built, catalog: c), catalog: c)
        #expect(compiled.problems.isEmpty, "\(name): \(compiled.problems)")
        #expect(Set(compiled.graph.nodes.keys) == Set(built.graph.nodes.keys), "\(name)")
        for (id, node) in built.graph.nodes {
            let out = try #require(compiled.graph.nodes[id], "\(name) \(id)")
            #expect(out.classType == node.classType, "\(name) \(id)")
            for (input, value) in out.inputs {
                if let sent = node.inputs[input] {
                    #expect(value == sent, "\(name) \(id) \(node.classType).\(input)")
                } else {
                    let spec = try #require(c.nodes[node.classType])
                    let declared = try #require(spec.inputs[input], "\(name) \(node.classType).\(input)")
                    #expect(spec.optional.contains(input), "\(name) \(node.classType).\(input) is required")
                    #expect(
                        value == WorkflowCompiler.Compiler.input(WidgetLayout.defaultValue(declared), declared),
                        "\(name) \(node.classType).\(input)")
                }
            }
            #expect(Set(node.inputs.keys).isSubset(of: out.inputs.keys), "\(name) \(id) \(node.classType)")
        }
    }
}

@Test func projectionKeepsRolesThroughASave() throws {
    let c = try kritaCatalog()
    for (name, r) in try requests() {
        let built = WorkflowBuilder.build(r, catalog: c)
        let doc = try WorkflowDocument(built, catalog: c)
        let expected = Dictionary(uniqueKeysWithValues: built.roles.map { (Int($0.key)!, $0.value) })
        #expect(doc.roles == expected, "\(name)")
        let loaded = try WorkflowDocument(data: doc.data())
        #expect(loaded.roles == expected, "\(name)")
        #expect(
            WorkflowCompiler.compile(loaded, catalog: c).graph == WorkflowCompiler.compile(doc, catalog: c).graph,
            "\(name)")
    }
}

@Test func projectionLayoutIsTheSameEachTime() throws {
    let c = try kritaCatalog()
    for (name, r) in try requests() {
        let built = WorkflowBuilder.build(r, catalog: c)
        let a = try WorkflowDocument(built, catalog: c)
        let b = try WorkflowDocument(WorkflowBuilder.build(r, catalog: c), catalog: c)
        #expect(a == b, "\(name)")
        // Loaders left of the sampler, the output furthest right.
        func x(_ role: NodeRole) throws -> Double {
            let id = try #require(built.ids(role).first.flatMap { Int($0) }, "\(name): \(role)")
            return try #require(a.graph.node(id)).position.x
        }
        let loader = r.split == nil ? NodeRole(.checkpoint) : NodeRole(.diffusionModel)
        #expect(try x(loader) < x(NodeRole(.sampler)), "\(name)")
        #expect(try x(NodeRole(.sampler)) < x(NodeRole(.output)), "\(name)")
    }
}

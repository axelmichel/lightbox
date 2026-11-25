import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ComfyKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func normalizesServerAddresses() throws {
    #expect(try ComfyServer.normalizedURL(from: "192.168.1.20:8188").absoluteString == "http://192.168.1.20:8188")
    #expect(try ComfyServer.normalizedURL(from: " http://gpu-pc:8188/ ").absoluteString == "http://gpu-pc:8188")
    #expect(
        try ComfyServer.normalizedURL(from: "https://comfy.example.com").absoluteString == "https://comfy.example.com")
    #expect(throws: ComfyError.self) { try ComfyServer.normalizedURL(from: "ftp://x") }
    #expect(throws: ComfyError.self) { try ComfyServer.normalizedURL(from: "") }
}

@Test func parsesLegacyCatalog() throws {
    // Older comfyui_controlnet_aux named the all-in-one node AIO_Aux_Preprocessor.
    let c = try ComfyCatalog(objectInfo: try fixture("object_info_legacy"))
    #expect(c.checkpoints == ["illustriousXL_v01.safetensors", "sd15/dreamshaper_8.safetensors"])
    #expect(c.loras == ["characters/mia_v1.safetensors", "style/ink_lines.safetensors"])  // COMBO form
    #expect(c.auxPreprocessorNode == "AIO_Aux_Preprocessor")
    #expect(c.auxPreprocessors.first == "LineArtPreprocessor")
    #expect(c.hasCanny)
    #expect(c.controlNetTakesVAE)
}

/// Node definitions as served by the real (Krita-style) ComfyUI install.
func kritaCatalog() throws -> ComfyCatalog {
    try ComfyCatalog(objectInfo: try fixture("object_info"))
}

@Test func parsesRealCatalog() throws {
    let c = try kritaCatalog()
    #expect(c.auxPreprocessorNode == "AIO_Preprocessor")
    #expect(c.auxPreprocessors.contains("DWPreprocessor"))
    #expect(c.hasIPAdapter)
    #expect(c.hasDetailer)
    #expect(c.faceDetector == "bbox/face_yolov8m.pt")
    #expect(c.handDetector == "bbox/hand_yolov8s.pt")
    #expect(c.unionTypes.contains("openpose"))
    let detailer = try #require(c.nodes["FaceDetailer"])
    #expect(detailer.required.first == "image")  // server order kept
    #expect(detailer.inputs["denoise"]?.defaultValue == .double(0.5))
    #expect(detailer.inputs["guide_size_for"]?.defaultValue == .bool(true))
    #expect(detailer.inputs["bbox_detector"]?.isLink == true)
}

@Test func resolvesGuidesByPurpose() throws {
    let c = try kritaCatalog()
    // Illustrious: the dedicated NoobAI ControlNets.
    #expect(
        ControlResolver.resolve(.pose, arch: .illustrious, catalog: c)
            == .success(
                .controlNet(
                    model: "noobaiXLControlnet_openposeModel.safetensors", unionType: nil,
                    extractor: .aux("DWPreprocessor", resolution: 1024))))
    #expect(
        ControlResolver.resolve(.lineart, arch: .illustrious, catalog: c)
            == .success(
                .controlNet(
                    model: "noob-sdxl-controlnet-lineart_anime.fp16.safetensors", unionType: nil,
                    extractor: .aux("AnimeLineArtPreprocessor", resolution: 1024))))
    // Realistic SDXL: the union ControlNet with the right type.
    #expect(
        ControlResolver.resolve(.depth, arch: .sdxl, catalog: c)
            == .success(
                .controlNet(
                    model: "xinsir-controlnet-union-sdxl-1.0-promax.safetensors", unionType: "depth",
                    extractor: .aux("DepthAnythingV2Preprocessor", resolution: 1024))))
    // Image prompts: NoobAI's IP-Adapter needs ViT-bigG, the SDXL one ViT-H.
    #expect(
        ControlResolver.resolve(.style, arch: .illustrious, catalog: c)
            == .success(
                .ipAdapter(
                    model: "noobIPAMARK1_mark1.safetensors", clipVision: "clip-vision_vit-g.safetensors",
                    weightType: "style transfer")))
    #expect(
        ControlResolver.resolve(.composition, arch: .sdxl, catalog: c)
            == .success(
                .ipAdapter(
                    model: "ip-adapter_sdxl_vit-h.safetensors", clipVision: "clip-vision_vit-h.safetensors",
                    weightType: "composition")))
    // Nothing for SD 1.5 on this server: say what is missing.
    guard case .failure(let missing) = ControlResolver.resolve(.depth, arch: .sd15, catalog: c) else {
        Issue.record("expected a missing model")
        return
    }
    #expect(missing.need == "a depth ControlNet for SD 1.5")
    #expect(missing.examples == ["control_v11f1p_sd15_depth"])
}

private func request(guides: [GuideRequest] = [], faceFix: DetailerRequest? = nil) -> GenerationRequest {
    GenerationRequest(
        checkpoint: "Sample_Illustrious_v1.safetensors",
        loras: [
            LoraRequest(name: "a.safetensors", strength: 0.8),
            LoraRequest(name: "b.safetensors", strength: -0.5, clipStrength: 0),
        ],
        positive: "1girl, comic", negative: "lowres", width: 832, height: 1216, seed: 42, batchSize: 2, clipSkip: 2,
        guides: guides, faceFix: faceFix)
}

private func link(_ input: NodeInput?) -> String? {
    if case .link(let id, _)? = input { return id }
    return nil
}

@Test func buildsTxt2ImgWithLoraChainAndClipSkip() throws {
    let g = WorkflowBuilder.txt2img(request(), catalog: try kritaCatalog())
    let ckpt = try #require(g.ids(of: "CheckpointLoaderSimple").first)
    let loras = g.ids(of: "LoraLoader")
    #expect(loras.count == 2)
    // The chain: checkpoint → first LoRA → second LoRA → CLIP skip.
    #expect(link(g.nodes[loras[0]]?.inputs["model"]) == ckpt)
    #expect(link(g.nodes[loras[1]]?.inputs["model"]) == loras[0])
    #expect(g.nodes[loras[0]]?.inputs["strength_clip"] == .double(0.8))
    #expect(g.nodes[loras[1]]?.inputs["strength_model"] == .double(-0.5))  // slider LoRAs go negative
    #expect(g.nodes[loras[1]]?.inputs["strength_clip"] == .double(0))
    let skip = try #require(g.ids(of: "CLIPSetLastLayer").first)
    #expect(g.nodes[skip]?.inputs["stop_at_clip_layer"] == .int(-2))
    #expect(link(g.nodes[skip]?.inputs["clip"]) == loras[1])
    let sampler = try #require(g.ids(of: "KSampler").first.flatMap { g.nodes[$0] })
    #expect(link(sampler.inputs["model"]) == loras[1])
    #expect(sampler.inputs["seed"] == .int(42))
    let latent = try #require(g.ids(of: "EmptyLatentImage").first.flatMap { g.nodes[$0] })
    #expect(latent.inputs["batch_size"] == .int(2))
    #expect(g.ids(of: "PreviewImage").count == 1)
    #expect(g.ids(of: "ControlNetApplyAdvanced").isEmpty)
    // Serializes to the API format.
    let json = try #require(try JSONSerialization.jsonObject(with: g.jsonData()) as? [String: [String: Any]])
    #expect(json[ckpt]?["class_type"] as? String == "CheckpointLoaderSimple")
}

/// Every node's inputs are ones the server reports.
private func expectKnownInputs(_ g: WorkflowGraph, _ c: ComfyCatalog) throws {
    for (id, node) in g.nodes {
        let spec = try #require(c.nodes[node.classType], "\(node.classType) #\(id) unknown")
        #expect(Set(node.inputs.keys).isSubset(of: Set(spec.inputs.keys)), "\(node.classType)")
    }
}

@Test func buildsFluxFromSeparateGGUFFiles() throws {
    let c = try kritaCatalog()
    #expect(c.diffusionModels.contains("flux1-krea-Q4.gguf"))
    #expect(c.textEncoders.contains("t5-xxl-encoder-Q4.gguf"))
    let split = SplitModelRequest(
        model: "flux1-krea-Q4.gguf", textEncoders: ["t5-xxl-encoder-Q4.gguf", "clip_l.safetensors"],
        clipType: "flux", vae: "ae.safetensors", guidance: 4.5, zeroNegative: true)
    #expect(c.canLoad(split))
    var r = request()
    r.split = split
    r.cfg = 1
    let g = WorkflowBuilder.txt2img(r, catalog: c)
    #expect(g.ids(of: "CheckpointLoaderSimple").isEmpty)
    #expect(g.ids(of: "CLIPSetLastLayer").isEmpty)  // no CLIP skip for split models
    let unet = try #require(g.ids(of: "UnetLoaderGGUF").first)
    let clip = try #require(g.ids(of: "DualCLIPLoaderGGUF").first.flatMap { g.nodes[$0] })
    #expect(clip.inputs["clip_name1"] == .string("t5-xxl-encoder-Q4.gguf"))
    #expect(clip.inputs["type"] == .string("flux"))
    let loras = g.ids(of: "LoraLoader")
    #expect(link(g.nodes[loras[0]]?.inputs["model"]) == unet)
    let guidance = try #require(g.ids(of: "FluxGuidance").first)
    let sampler = try #require(g.ids(of: "KSampler").first.flatMap { g.nodes[$0] })
    #expect(link(sampler.inputs["positive"]) == guidance)
    #expect(link(sampler.inputs["negative"]) == g.ids(of: "ConditioningZeroOut").first)
    #expect(g.ids(of: "CLIPTextEncode").count == 1)
    let latent = try #require(g.ids(of: "EmptySD3LatentImage").first)
    #expect(link(sampler.inputs["latent_image"]) == latent)
    #expect(g.ids(of: "VAELoader").count == 1)
    try expectKnownInputs(g, c)
}

@Test func buildsZImageWithItsSamplingShift() throws {
    let c = try kritaCatalog()
    var r = request()
    r.loras = []
    r.split = SplitModelRequest(
        model: "z_image_turbo-Q4.gguf", textEncoders: ["qwen3-4b-encoder-Q4.gguf"], clipType: "lumina2",
        vae: "ae.safetensors", shift: 3)
    let g = WorkflowBuilder.txt2img(r, catalog: c)
    let unet = try #require(g.ids(of: "UnetLoaderGGUF").first)
    let clip = try #require(g.ids(of: "CLIPLoaderGGUF").first.flatMap { g.nodes[$0] })
    #expect(clip.inputs["clip_name"] == .string("qwen3-4b-encoder-Q4.gguf"))
    #expect(clip.inputs["type"] == .string("lumina2"))
    let shift = try #require(g.ids(of: "ModelSamplingAuraFlow").first)
    #expect(link(g.nodes[shift]?.inputs["model"]) == unet)
    #expect(g.nodes[shift]?.inputs["shift"] == .double(3))
    let sampler = try #require(g.ids(of: "KSampler").first.flatMap { g.nodes[$0] })
    #expect(link(sampler.inputs["model"]) == shift)
    #expect(g.ids(of: "FluxGuidance").isEmpty && g.ids(of: "ConditioningZeroOut").isEmpty)
    #expect(g.ids(of: "CLIPTextEncode").count == 2)
    try expectKnownInputs(g, c)
}

@Test func buildsFlux2WithItsOwnSampling() throws {
    let c = try kritaCatalog()
    #expect(c.diffusionModels.contains("flux-2-klein-9b-Q4.gguf"))
    let split = SplitModelRequest(
        model: "flux-2-klein-9b-Q4.gguf", textEncoders: ["qwen_3_8b.safetensors"], clipType: "flux2",
        vae: "flux2-vae.safetensors", zeroNegative: true, sampling: .flux2)
    #expect(split.loaderNodes == ["UnetLoaderGGUF", "CLIPLoader", "VAELoader"])
    #expect(c.canLoad(split))
    var r = request(faceFix: DetailerRequest(detector: "bbox/face_yolov8m.pt"))
    r.split = split
    r.loras = []
    (r.steps, r.cfg, r.sampler, r.width, r.height) = (4, 1, "euler", 1216, 832)
    let g = WorkflowBuilder.txt2img(r, catalog: c)
    #expect(g.ids(of: "KSampler").isEmpty && g.ids(of: "FaceDetailer").isEmpty)
    let latent = try #require(g.ids(of: "EmptyFlux2LatentImage").first)
    let scheduler = try #require(g.ids(of: "Flux2Scheduler").first.flatMap { g.nodes[$0] })
    #expect(scheduler.inputs["steps"] == .int(4) && scheduler.inputs["width"] == .int(1216))
    let guider = try #require(g.ids(of: "CFGGuider").first.flatMap { g.nodes[$0] })
    #expect(guider.inputs["cfg"] == .double(1))
    #expect(link(guider.inputs["negative"]) == g.ids(of: "ConditioningZeroOut").first)
    #expect(link(guider.inputs["model"]) == g.ids(of: "UnetLoaderGGUF").first)
    let sampler = try #require(g.ids(of: "SamplerCustomAdvanced").first)
    #expect(link(g.nodes[sampler]?.inputs["latent_image"]) == latent)
    #expect(g.nodes[g.ids(of: "RandomNoise")[0]]?.inputs["noise_seed"] == .int(42))
    #expect(link(g.nodes[g.ids(of: "VAEDecode")[0]]?.inputs["samples"]) == sampler)
    #expect(g.ids(of: "SplitSigmasDenoise").isEmpty)
    try expectKnownInputs(g, c)

    // Inpainting: only the low end of the schedule.
    r.inpaint = InpaintSource(image: Data(), mask: Data(), denoise: 0.6, filename: "x")
    let inpaint = WorkflowBuilder.txt2img(r, catalog: c)
    let split2 = try #require(inpaint.ids(of: "SplitSigmasDenoise").first)
    let custom = try #require(inpaint.ids(of: "SamplerCustomAdvanced").first.flatMap { inpaint.nodes[$0] })
    #expect(custom.inputs["sigmas"] == .link(split2, 1))
    #expect(link(custom.inputs["latent_image"]) == inpaint.ids(of: "SetLatentNoiseMask").first)
    try expectKnownInputs(inpaint, c)
}

@Test func editsAPictureWithAReference() throws {
    let c = try kritaCatalog()
    #expect(c.canEditWithReference)
    var r = request()
    r.loras = []
    r.split = SplitModelRequest(
        model: "flux-2-klein-9b-Q4.gguf", textEncoders: ["qwen_3_8b.safetensors"], clipType: "flux2",
        vae: "flux2-vae.safetensors", zeroNegative: true, sampling: .flux2)
    r.references = [ReferenceImage(image: Data([1]), filename: "edit")]
    r.references[0].imageName = "lightbox/edit.png"
    let g = WorkflowBuilder.txt2img(r, catalog: c)
    let load = try #require(g.ids(of: "LoadImage").first)
    #expect(g.nodes[load]?.inputs["image"] == .string("lightbox/edit.png"))
    let encode = try #require(g.ids(of: "VAEEncode").first)
    let reference = try #require(g.ids(of: "ReferenceLatent").first.flatMap { g.nodes[$0] })
    #expect(link(reference.inputs["latent"]) == encode)
    #expect(link(reference.inputs["conditioning"]) == g.ids(of: "CLIPTextEncode").first)
    let guider = try #require(g.ids(of: "CFGGuider").first.flatMap { g.nodes[$0] })
    #expect(link(guider.inputs["positive"]) == g.ids(of: "ReferenceLatent").first)
    // A new picture of the same size comes out, not an inpainted one.
    #expect(!g.ids(of: "EmptyFlux2LatentImage").isEmpty)
    try expectKnownInputs(g, c)
}

@Test func safetensorsSplitModelsUseTheCoreLoaders() {
    let split = SplitModelRequest(
        model: "flux1-dev-fp8.safetensors", textEncoders: ["t5xxl_fp8.safetensors", "clip_l.safetensors"],
        clipType: "flux", vae: "ae.safetensors")
    #expect(split.loaderNodes == ["UNETLoader", "DualCLIPLoader", "VAELoader"])
    #expect(!ComfyCatalog().canLoad(split))
}

@Test func inpaintingStartsFromTheMaskedPicture() throws {
    let c = try kritaCatalog()
    #expect(c.canInpaint)
    #expect(!ComfyCatalog().canInpaint)
    var r = request()
    r.inpaint = InpaintSource(image: Data([1]), mask: Data([2]), denoise: 0.6, filename: "edit")
    r.inpaint?.imageName = "lightbox/edit.png"
    r.inpaint?.maskName = "lightbox/edit-mask.png"
    let g = WorkflowBuilder.txt2img(r, catalog: c)
    #expect(g.ids(of: "EmptyLatentImage").isEmpty)
    let load = try #require(g.ids(of: "LoadImage").first)
    #expect(g.nodes[load]?.inputs["image"] == .string("lightbox/edit.png"))
    let mask = try #require(g.ids(of: "LoadImageMask").first.flatMap { g.nodes[$0] })
    #expect(mask.inputs["image"] == .string("lightbox/edit-mask.png"))
    #expect(mask.inputs["channel"] == .string("red"))
    let encode = try #require(g.ids(of: "VAEEncode").first)
    #expect(link(g.nodes[encode]?.inputs["pixels"]) == load)
    let noise = try #require(g.ids(of: "SetLatentNoiseMask").first)
    #expect(link(g.nodes[noise]?.inputs["samples"]) == encode)
    let sampler = try #require(g.ids(of: "KSampler").first.flatMap { g.nodes[$0] })
    #expect(link(sampler.inputs["latent_image"]) == noise)
    #expect(sampler.inputs["denoise"] == .double(0.6))
    // Only inputs the server knows.
    for id in [load, encode, noise] + g.ids(of: "LoadImageMask") {
        let node = try #require(g.nodes[id])
        let known = try #require(c.nodes[node.classType]).inputs.keys
        #expect(Set(node.inputs.keys).isSubset(of: Set(known)), "\(node.classType)")
    }
}

@Test func buildsGuidesAndChainsThem() throws {
    let c = try kritaCatalog()
    let pose = try ControlResolver.resolve(.depth, arch: .sdxl, catalog: c).get()  // union
    let style = try ControlResolver.resolve(.style, arch: .illustrious, catalog: c).get()
    var guides = [
        GuideRequest(setup: pose, image: Data(), filename: "a.png", strength: 0.6, endPercent: 0.8),
        GuideRequest(setup: style, image: Data(), filename: "b.png", strength: 0.9),
    ]
    guides[0].imageName = "lightbox/a.png"
    guides[1].imageName = "lightbox/b.png"
    let g = WorkflowBuilder.txt2img(request(guides: guides), catalog: c)

    // ControlNet: picture → depth extraction → union type → apply (with VAE on this server).
    let pre = try #require(g.ids(of: "AIO_Preprocessor").first.flatMap { g.nodes[$0] })
    #expect(pre.inputs["preprocessor"] == .string("DepthAnythingV2Preprocessor"))
    let union = try #require(g.ids(of: "SetUnionControlNetType").first.flatMap { g.nodes[$0] })
    #expect(union.inputs["type"] == .string("depth"))
    let applyID = try #require(g.ids(of: "ControlNetApplyAdvanced").first)
    let apply = try #require(g.nodes[applyID])
    #expect(apply.inputs["end_percent"] == .double(0.8))
    #expect(apply.inputs["vae"] != nil)
    // IP-Adapter: patches the model, with the server's defaults filled in.
    let ipaID = try #require(g.ids(of: "IPAdapterAdvanced").first)
    let ipa = try #require(g.nodes[ipaID])
    #expect(ipa.inputs["weight_type"] == .string("style transfer"))
    #expect(ipa.inputs["combine_embeds"] == .string("concat"))
    #expect(ipa.inputs["embeds_scaling"] == .string("V only"))
    // The sampler gets both.
    let sampler = try #require(g.ids(of: "KSampler").first.flatMap { g.nodes[$0] })
    #expect(sampler.inputs["positive"] == .link(applyID, 0))
    #expect(sampler.inputs["model"] == .link(ipaID, 0))
}

@Test func guideWithoutExtractionUsesThePictureAsIs() throws {
    let c = try kritaCatalog()
    let setup = try ControlResolver.resolve(.scribble, arch: .illustrious, catalog: c).get()
    var guide = GuideRequest(setup: setup, image: Data(), filename: "sketch.png", extract: false)
    guide.imageName = "sketch.png"
    let g = WorkflowBuilder.txt2img(request(guides: [guide]), catalog: c)
    #expect(g.ids(of: "AIO_Preprocessor").isEmpty)
    let apply = try #require(g.ids(of: "ControlNetApplyAdvanced").first.flatMap { g.nodes[$0] })
    #expect(link(apply.inputs["image"]) == g.ids(of: "LoadImage").first)
}

@Test func faceFixRedrawsFacesWithTheLoraModelAndAllRequiredInputs() throws {
    let c = try kritaCatalog()
    let style = try ControlResolver.resolve(.style, arch: .illustrious, catalog: c).get()
    var guide = GuideRequest(setup: style, image: Data(), filename: "b.png")
    guide.imageName = "b.png"
    var r = request(guides: [guide], faceFix: DetailerRequest(detector: "bbox/face_yolov8m.pt", denoise: 0.35))
    r.scheduler = "karras"
    let g = WorkflowBuilder.txt2img(r, catalog: c)
    let fixID = try #require(g.ids(of: "FaceDetailer").first)
    let fix = try #require(g.nodes[fixID])
    // Every required input of the server's FaceDetailer is set.
    let spec = try #require(c.nodes["FaceDetailer"])
    #expect(spec.required.filter { fix.inputs[$0] == nil } == [])
    #expect(fix.inputs["denoise"] == .double(0.35))
    #expect(fix.inputs["sam_detection_hint"] == .string("center-1"))  // combo without default: first option
    // Face crops use the LoRA model, not the one patched by the IP-Adapter.
    #expect(link(fix.inputs["model"]) == g.ids(of: "LoraLoader").last)
    // The preview shows the fixed image.
    let preview = try #require(g.ids(of: "PreviewImage").first.flatMap { g.nodes[$0] })
    #expect(preview.inputs["images"] == .link(fixID, 0))
}

@Test func unknownSamplerFallsBackOnlyForSamplerInputs() throws {
    var g = WorkflowGraph()
    let id = g.add(
        "FaceDetailer", ["sampler_name": .string("no_such_sampler"), "scheduler": .string("karras")],
        defaultsFrom: try kritaCatalog())
    #expect(g.nodes[id]?.inputs["sampler_name"] == .string("euler"))
    #expect(g.nodes[id]?.inputs["scheduler"] == .string("karras"))
}

@Test func parsesSocketMessages() {
    #expect(
        ServerMessage.parse(text: #"{"type":"progress","data":{"value":3,"max":25,"prompt_id":"p1","node":"9"}}"#)
            == .progress(promptID: "p1", value: 3, max: 25))
    #expect(
        ServerMessage.parse(text: #"{"type":"executing","data":{"node":null,"prompt_id":"p1"}}"#)
            == .executing(promptID: "p1", node: nil))
    #expect(
        ServerMessage.parse(text: #"{"type":"execution_success","data":{"prompt_id":"p1"}}"#)
            == .success(promptID: "p1"))
    #expect(
        ServerMessage.parse(
            text:
                #"{"type":"execution_error","data":{"prompt_id":"p1","node_id":"4","node_type":"KSampler","exception_message":"CUDA out of memory\n"}}"#
        ) == .error(promptID: "p1", node: "KSampler #4", message: "CUDA out of memory"))
    #expect(
        ServerMessage.parse(text: #"{"type":"status","data":{"status":{"exec_info":{"queue_remaining":2}}}}"#)
            == .status(queueRemaining: 2))
}

@Test func parsesBinaryPreviews() {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    #expect(ServerMessage.parse(binary: Data([0, 0, 0, 1, 0, 0, 0, 1]) + jpeg) == .preview(jpeg))
    let meta = Data(#"{"node_id":"9"}"#.utf8)
    let framed = Data([0, 0, 0, 4, 0, 0, 0, UInt8(meta.count)]) + meta + jpeg
    #expect(ServerMessage.parse(binary: framed) == .preview(jpeg))
    #expect(ServerMessage.parse(binary: Data([0, 0])) == nil)
}

@Test func summarizesWorkflowErrors() {
    let body = Data(
        #"{"error":{"type":"prompt_outputs_failed_validation","message":"Prompt outputs failed validation","details":""},"node_errors":{"1":{"errors":[{"type":"value_not_in_list","message":"Value not in list","details":"ckpt_name: 'gone.safetensors' not in [...]"}],"class_type":"CheckpointLoaderSimple"}}}"#
            .utf8)
    #expect(
        ComfyClient.workflowError(body)
            == "Prompt outputs failed validation\nCheckpointLoaderSimple #1: Value not in list: ckpt_name: 'gone.safetensors' not in [...]"
    )
}

// MARK: - HTTP against a stub

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest, Data) -> (Int, Data) = { _, _ in (404, Data()) }
    nonisolated(unsafe) static var seen: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.seen.append((request, body))
        let (status, data) = Self.respond(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct ClientTests {
    let client: ComfyClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return ComfyClient(baseURL: URL(string: "http://gpu-pc:8188")!, session: URLSession(configuration: config))
    }()

    @Test func queuesWithClientID() async throws {
        StubProtocol.seen = []
        StubProtocol.respond = { _, _ in (200, Data(#"{"prompt_id":"abc","number":1,"node_errors":{}}"#.utf8)) }
        let id = try await client.queue(WorkflowBuilder.txt2img(request(), catalog: try kritaCatalog()), clientID: "me")
        #expect(id == "abc")
        let (req, body) = try #require(StubProtocol.seen.last)
        #expect(req.url?.path() == "/prompt")
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["client_id"] as? String == "me")
        #expect((obj["prompt"] as? [String: Any])?.isEmpty == false)
    }

    @Test func rejectedWorkflowIsReadable() async throws {
        StubProtocol.respond = { _, _ in
            (400, Data(#"{"error":{"message":"Prompt outputs failed validation","details":""},"node_errors":{}}"#.utf8))
        }
        await #expect(throws: ComfyError.invalidWorkflow("Prompt outputs failed validation")) {
            try await client.queue(WorkflowBuilder.txt2img(request(), catalog: ComfyCatalog()), clientID: "me")
        }
    }

    @Test func uploadsMultipartAndReturnsSubfolderPath() async throws {
        StubProtocol.seen = []
        StubProtocol.respond = { _, _ in
            (200, Data(#"{"name":"sketch.png","subfolder":"lightbox","type":"input"}"#.utf8))
        }
        let name = try await client.upload(image: Data([1, 2, 3]), filename: "sketch.png")
        #expect(name == "lightbox/sketch.png")
        let (req, body) = try #require(StubProtocol.seen.last)
        #expect(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#"name="image"; filename="sketch.png""#))
        #expect(text.contains(#"name="overwrite""#))
        #expect(text.contains("name=\"subfolder\"\r\n\r\nlightbox\r\n"))
    }

    @Test func readsModelMetadata() async throws {
        StubProtocol.seen = []
        StubProtocol.respond = { _, _ in
            (200, Data(#"{"modelspec.architecture":"stable-diffusion-xl-v1-base","ss_steps":1200}"#.utf8))
        }
        let meta = try await client.modelMetadata(filename: "sub/model.safetensors")
        #expect(meta?["modelspec.architecture"] == "stable-diffusion-xl-v1-base")
        #expect(meta?["ss_steps"] == "1200")
        let (req, _) = try #require(StubProtocol.seen.last)
        #expect(req.url?.path() == "/view_metadata/checkpoints")
        #expect(req.url?.query()?.contains("filename=sub/model.safetensors") == true)

        StubProtocol.respond = { _, _ in (404, Data()) }
        #expect(try await client.modelMetadata(filename: "old.ckpt") == nil)
    }

    @Test func readsHistoryOutputs() async throws {
        StubProtocol.respond = { _, _ in
            (
                200,
                Data(
                    #"{"abc":{"outputs":{"12":{"images":[{"filename":"ComfyUI_temp_0001.png","subfolder":"","type":"temp"}]}},"status":{"status_str":"success","completed":true}}}"#
                        .utf8)
            )
        }
        let refs = try await client.outputs(promptID: "abc")
        #expect(refs == [ImageRef(filename: "ComfyUI_temp_0001.png", subfolder: "", type: "temp")])
        StubProtocol.respond = { _, _ in (200, Data("{}".utf8)) }
        #expect(try await client.outputs(promptID: "abc") == nil)
    }
}

// MARK: - Against a real server

/// `COMFY_URL=http://<pc>:8188 COMFY_CHECKPOINT=<file> swift test`
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(5)))
func generatesAgainstRealServer() async throws {
    let env = ProcessInfo.processInfo.environment
    let client = ComfyClient(baseURL: try ComfyServer.normalizedURL(from: env["COMFY_URL"]!))
    let stats = try await client.systemStats()
    print("ComfyUI \(stats.system.comfyuiVersion ?? "?") on \(stats.gpuSummary)")
    let catalog = try await client.catalog()
    #expect(!catalog.samplers.isEmpty)
    let checkpoint = try #require(env["COMFY_CHECKPOINT"] ?? catalog.checkpoints.first, "no checkpoint on the server")
    let request = GenerationRequest(
        checkpoint: checkpoint, positive: "a lighthouse on a cliff, comic style", negative: "lowres",
        width: 512, height: 512, steps: 8, sampler: "euler", scheduler: "normal", seed: 1)
    var images: [GeneratedImage] = []
    var steps: [Int] = []
    for try await event in client.generate(request, catalog: catalog) {
        if case .finished(let result) = event { images = result }
        if case .progress(let step, _) = event { steps.append(step) }
    }
    #expect(images.count == 1)
    // Progress arrives step by step (it used to be dropped when the start
    // event was missed).
    #expect(steps.last == request.steps)
    #expect(images.first.map { $0.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) } == true)  // PNG
}

/// A structure guide, an image prompt, a LoRA and the face fix, as far as the
/// server has them.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(5)))
func generatesWithGuidesAndFaceFix() async throws {
    let env = ProcessInfo.processInfo.environment
    let client = ComfyClient(baseURL: try ComfyServer.normalizedURL(from: env["COMFY_URL"]!))
    let catalog = try await client.catalog()
    let checkpoint = try #require(env["COMFY_CHECKPOINT"] ?? catalog.checkpoints.first)
    let lower = checkpoint.lowercased()
    let arch: ModelArch = lower.contains("illustrious") || lower.contains("noob") ? .illustrious : .sdxl
    let picture = try testPicture()
    let guides = [ControlKind.pose, .style].compactMap { kind in
        (try? ControlResolver.resolve(kind, arch: arch, catalog: catalog).get()).map {
            GuideRequest(setup: $0, image: picture, filename: "guide-\(kind.rawValue).png", strength: 0.5)
        }
    }
    let request = GenerationRequest(
        checkpoint: checkpoint, loras: catalog.loras.prefix(1).map { LoraRequest(name: $0, strength: 0.3) },
        positive: "a cat on a fence, comic style", negative: "lowres", width: 512, height: 512, steps: 8,
        sampler: "euler", scheduler: "normal", seed: 2, guides: guides,
        faceFix: catalog.faceDetector.map { DetailerRequest(detector: $0) })
    var events: [GenerationEvent] = []
    for try await event in client.generate(request, catalog: catalog) {
        events.append(event)
    }
    if !guides.isEmpty { #expect(events.first == .uploading) }
    guard case .finished(let images)? = events.last else {
        Issue.record("did not finish: \(events.last.map(String.init(describing:)) ?? "no events")")
        return
    }
    #expect(images.count == 1)
}

/// Painting part of a picture again: the picture and its mask are uploaded first.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(5)))
func inpaintsAgainstRealServer() async throws {
    let env = ProcessInfo.processInfo.environment
    let client = ComfyClient(baseURL: try ComfyServer.normalizedURL(from: env["COMFY_URL"]!))
    let catalog = try await client.catalog()
    try #require(catalog.canInpaint, "the server lacks the inpainting nodes")
    let checkpoint = try #require(env["COMFY_CHECKPOINT"] ?? catalog.checkpoints.first)
    let picture = try testPicture()
    let request = GenerationRequest(
        checkpoint: checkpoint, positive: "a red ball", negative: "lowres", width: 512, height: 512, steps: 8,
        sampler: "euler", scheduler: "normal", seed: 4,
        inpaint: InpaintSource(image: picture, mask: picture, denoise: 0.7, filename: "inpaint-test"))
    var events: [GenerationEvent] = []
    for try await event in client.generate(request, catalog: catalog) {
        events.append(event)
    }
    #expect(events.first == .uploading)
    guard case .finished(let images)? = events.last else {
        Issue.record("did not finish: \(events.last.map(String.init(describing:)) ?? "no events")")
        return
    }
    #expect(images.count == 1)
}

/// A split model (Flux or Z-Image) from the server's files:
/// `COMFY_SPLIT_MODEL=<file>`, else the first diffusion model.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(10)))
func generatesWithASplitModel() async throws {
    let env = ProcessInfo.processInfo.environment
    let client = ComfyClient(baseURL: try ComfyServer.normalizedURL(from: env["COMFY_URL"]!))
    let catalog = try await client.catalog()
    let model = try #require(env["COMFY_SPLIT_MODEL"] ?? catalog.diffusionModels.first, "no diffusion model")
    let zImage = model.lowercased().contains("z_image") || model.lowercased().contains("zimage")
    let flux2 = model.lowercased().contains("klein") || model.lowercased().contains("flux-2")
    let encoders = catalog.textEncoders
    let split =
        flux2
        ? SplitModelRequest(
            model: model, textEncoders: [try #require(encoders.first { $0.lowercased().contains("qwen_3_8b") })],
            clipType: "flux2", vae: "flux2-vae.safetensors", zeroNegative: true, sampling: .flux2)
        : zImage
            ? SplitModelRequest(
                model: model, textEncoders: [try #require(encoders.first { $0.lowercased().contains("qwen") })],
                clipType: "lumina2", vae: "ae.safetensors", shift: 3)
            : SplitModelRequest(
                model: model,
                textEncoders: [
                    try #require(encoders.first { $0.lowercased().contains("t5") }),
                    try #require(encoders.first { $0.lowercased().contains("clip_l") }),
                ], clipType: "flux", vae: "ae.safetensors", guidance: 3.5, zeroNegative: true)
    try #require(catalog.canLoad(split))
    var request = GenerationRequest(
        checkpoint: "", positive: "a lighthouse on a cliff at dusk", negative: "", width: 512, height: 512,
        steps: flux2 ? 4 : zImage ? 8 : 12, cfg: 1, sampler: "euler", scheduler: "simple", seed: 5, split: split)
    // Flux 2 can also edit a picture: `COMFY_EDIT=1` sends one as a reference.
    if flux2, env["COMFY_EDIT"] != nil {
        request.positive = "make it night, with a starry sky"
        request.references = [ReferenceImage(image: try testPicture(), filename: "edit-test")]
    }
    var images: [GeneratedImage] = []
    for try await event in client.generate(request, catalog: catalog) {
        if case .finished(let result) = event { images = result }
    }
    #expect(images.count == 1)
}

/// Cancelling the consuming task ends the stream and stops the prompt.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(2)))
func cancelsAGeneration() async throws {
    let env = ProcessInfo.processInfo.environment
    let client = ComfyClient(baseURL: try ComfyServer.normalizedURL(from: env["COMFY_URL"]!))
    let catalog = try await client.catalog()
    let checkpoint = try #require(env["COMFY_CHECKPOINT"] ?? catalog.checkpoints.first)
    let request = GenerationRequest(
        checkpoint: checkpoint, positive: "a long walk", negative: "", width: 512, height: 512, steps: 40,
        sampler: "euler", scheduler: "normal", seed: 3)
    let task = Task {
        var finished = false
        for try await event in client.generate(request, catalog: catalog) {
            if case .finished = event { finished = true }
        }
        return finished
    }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()
    #expect(try await task.value == false)
    // The client stops the prompt on the server after the stream ended.
    try await Task.sleep(for: .milliseconds(500))
}

/// A 512² PNG with a few shapes, as a stand-in guide picture.
func testPicture() throws -> Data {
    let ctx = try #require(
        CGContext(
            data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.setFillColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    ctx.setFillColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1)
    ctx.fillEllipse(in: CGRect(x: 196, y: 330, width: 120, height: 120))
    ctx.fill(CGRect(x: 216, y: 80, width: 80, height: 240))
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return data as Data
}

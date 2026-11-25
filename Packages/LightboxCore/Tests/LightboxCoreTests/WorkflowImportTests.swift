import Foundation
import Testing

@testable import LightboxCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test(arguments: ["workflow_api", "workflow_ui"])
func readsTxt2ImgWorkflow(_ file: String) throws {
    let r = try WorkflowImport.read(try fixture(file), name: "Snow.json")
    let p = r.preset
    #expect(p.name == "Snow")
    #expect(p.checkpoint == "Sample_Illustrious_v1.safetensors")
    #expect(p.family == .illustrious)
    #expect(p.dialect == .tags)
    #expect((p.sampler, p.scheduler, p.steps, p.cfg) == ("euler_ancestral", "normal", 28, 5.5))
    #expect((p.width, p.height, p.clipSkip) == (832, 1216, 2))
    #expect(p.loras == [LoraSlot(id: p.loras[0].id, name: "ink_style.safetensors", strength: 0.8, clipStrength: 0.6)])
    #expect(p.negativePrompt == "lowres, bad hands, watermark")
    #expect(p.stylePrompt == "")
    #expect(r.prompt == "masterpiece, best quality, 1girl, red scarf, snowy forest")
    #expect(r.files == ["Sample_Illustrious_v1.safetensors", "ink_style.safetensors"])
    #expect(p.detectionNotes.contains("Not taken over: UpscaleModelLoader."))
    #expect(p.detectionNotes.contains { $0.hasPrefix("Sampling from KSampler") })
    #expect(!p.detectionNotes.joined().contains("muted"))
}

@Test func followsConditioningThroughControlNet() throws {
    let json = """
        {
          "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "PhotoReal-XL-v11.safetensors"}},
          "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "a lighthouse at dusk", "clip": ["1", 1]}},
          "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "blurry", "clip": ["1", 1]}},
          "4": {"class_type": "ControlNetApplyAdvanced",
                "inputs": {"positive": ["2", 0], "negative": ["3", 0], "strength": 0.7}},
          "5": {"class_type": "LoadImage", "inputs": {"image": "x.png"}},
          "6": {"class_type": "VAEEncode", "inputs": {"pixels": ["5", 0], "vae": ["1", 2]}},
          "7": {"class_type": "KSampler", "inputs": {"model": ["1", 0], "positive": ["4", 0], "negative": ["4", 1],
                "latent_image": ["6", 0], "steps": 30, "cfg": 4.5, "sampler_name": "dpmpp_2m_sde",
                "scheduler": "karras", "seed": 1, "denoise": 0.6}}
        }
        """
    let r = try WorkflowImport.read(Data(json.utf8))
    #expect(r.prompt == "a lighthouse at dusk")
    #expect(r.preset.negativePrompt == "blurry")
    #expect(r.preset.style == .photo)
    #expect(r.preset.loras.isEmpty)
    let notes = r.preset.detectionNotes
    #expect(notes.contains { $0.contains("starts from a picture") })
    #expect(notes.contains { $0.contains("denoise") })
    #expect(notes.contains("Not taken over: ControlNetApplyAdvanced, LoadImage, VAEEncode."))
}

@Test func refusesWhatIsntAWorkflow() {
    #expect(throws: WorkflowImportError.notJSON) { try WorkflowImport.read(Data("nope".utf8)) }
    #expect(throws: WorkflowImportError.notAWorkflow) { try WorkflowImport.read(Data("[1, 2]".utf8)) }
    #expect(throws: WorkflowImportError.notAWorkflow) { try WorkflowImport.read(Data(#"{"a": 1}"#.utf8)) }
    #expect(throws: WorkflowImportError.noSampler) {
        try WorkflowImport.read(Data(#"{"1": {"class_type": "SaveImage", "inputs": {}}}"#.utf8))
    }
    #expect(throws: WorkflowImportError.noCheckpoint) {
        try WorkflowImport.read(Data(#"{"1": {"class_type": "KSampler", "inputs": {"steps": 20}}}"#.utf8))
    }
}

@Test func importsTheZImageWorkflow() throws {
    let r = try WorkflowImport.read(try fixture("workflow_zimage_ui"), name: "z_image_turbo.json")
    let p = r.preset
    #expect(p.family == .zImage)
    #expect(p.checkpoint == "z_image_turbo-Q4.gguf")
    #expect(p.textEncoders == ["qwen3-4b-encoder-Q4.gguf"])
    #expect(p.vae == "ae.safetensors")
    #expect(p.shift == 3)
    #expect((p.sampler, p.scheduler, p.steps, p.cfg) == ("euler", "simple", 9, 1))
    #expect((p.width, p.height) == (1024, 1024))
    #expect(r.prompt.hasPrefix("Candid photo of an elderly fisherman"))
    #expect(p.negativePrompt.isEmpty)
    #expect(!p.detectionNotes.contains { $0.hasPrefix("Not taken over") })
    #expect(r.files.contains("qwen3-4b-encoder-Q4.gguf"))
}

@Test func importsTheFluxWorkflow() throws {
    let r = try WorkflowImport.read(try fixture("workflow_flux_ui"), name: "flux1_krea.json")
    let p = r.preset
    #expect(p.family == .flux)
    #expect(p.checkpoint == "flux1-krea-Q4.gguf")
    #expect(p.textEncoders == ["t5-xxl-encoder-Q4.gguf", "clip_l.safetensors"])
    #expect(p.guidance == 4.5)
    #expect((p.steps, p.cfg) == (24, 1))
    // The negative is the prompt zeroed out, not the prompt.
    #expect(p.negativePrompt.isEmpty)
    #expect(r.prompt.contains("Lisbon"))
    #expect(p.detectionNotes.contains { $0.contains("zeroes it out") })
    #expect(!p.detectionNotes.contains { $0.hasPrefix("Not taken over") })
}

@Test func unknownSplitModelsAreToldByTheirTextEncoder() throws {
    let json = """
        {"1": {"class_type": "UNETLoader", "inputs": {"unet_name": "mystery.safetensors", "weight_dtype": "default"}},
         "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen_3_4b.safetensors", "type": "lumina2"}},
         "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "a cat", "clip": ["2", 0]}},
         "4": {"class_type": "KSampler", "inputs": {"model": ["1", 0], "positive": ["3", 0], "negative": ["3", 0],
               "steps": 8, "cfg": 1, "sampler_name": "euler", "scheduler": "simple", "seed": 1}}}
        """
    let p = try WorkflowImport.read(Data(json.utf8)).preset
    #expect(p.family == .zImage)
    #expect(p.textEncoders == ["qwen_3_4b.safetensors"])
}

@Test func importsAnAnimaWorkflowByItsTextEncoder() throws {
    // The diffusion model's name doesn't say Anima; the Qwen3 encoder
    // loaded as "stable_diffusion" does.
    let r = try WorkflowImport.read(try fixture("workflow_anima_ui"), name: "western.json")
    let p = r.preset
    #expect(p.family == .anima, "\(p.detectionNotes)")
    #expect(p.style == .anime)
    #expect(p.checkpoint == "WesternSample_v1.safetensors")
    #expect(p.textEncoders == ["qwen3-0.6b-made-up.safetensors"])
    #expect(p.vae == "qwen-image-vae-made-up.safetensors")
    #expect((p.steps, p.cfg, p.sampler, p.scheduler) == (30, 4, "euler", "simple"))
    #expect((p.width, p.height) == (1024, 1024))
    #expect(r.seed == 7)
    #expect(r.prompt.hasPrefix("comic illustration, a lighthouse keeper"))
    #expect(!p.detectionNotes.contains { $0.hasPrefix("Not taken over") }, "\(p.detectionNotes)")
}

@Test func importsTheFlux2KleinWorkflow() throws {
    let r = try WorkflowImport.read(try fixture("workflow_flux2_ui"), name: "flux2_klein.json")
    let p = r.preset
    #expect(p.family == .flux2)
    #expect(p.checkpoint == "flux-2-klein-9b-Q4.gguf")
    #expect(p.textEncoders == ["qwen_3_8b.safetensors"])
    #expect(p.vae == "flux2-vae.safetensors")
    #expect((p.steps, p.cfg, p.sampler) == (4, 1, "euler"))
    #expect((p.width, p.height) == (1024, 1024))  // from the primitives
    #expect(p.negativePrompt.isEmpty)
    #expect(r.seed == 42)
    #expect(r.prompt.hasPrefix("Candid photo of an elderly fisherman"))
    #expect(!p.detectionNotes.contains { $0.hasPrefix("Not taken over") }, "\(p.detectionNotes)")
}

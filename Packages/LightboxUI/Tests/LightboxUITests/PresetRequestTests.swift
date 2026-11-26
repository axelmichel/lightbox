import ComfyKit
import LightboxCore
import Testing

@testable import LightboxUI

private let prompt = ComposedPrompt(
    positive: "a fox in the snow", negative: "lowres",
    loras: [LoraUse(name: "ink-style.safetensors", weight: 0.6, clipWeight: 0.4)])

@Test func checkpointPresetBecomesARequest() {
    let preset = GenerationPreset(
        name: "Photo", checkpoint: "photo-xl.safetensors", vae: "sdxl-vae.safetensors", sampler: "euler",
        scheduler: "normal", steps: 30, cfg: 5, width: 832, height: 1216, clipSkip: 2)
    let r = preset.request(prompt, seed: 7, batchSize: 0)
    #expect(r.checkpoint == "photo-xl.safetensors")
    #expect(r.vae == "sdxl-vae.safetensors")
    #expect(r.loras == [LoraRequest(name: "ink-style.safetensors", strength: 0.6, clipStrength: 0.4)])
    #expect(r.positive == "a fox in the snow")
    #expect(r.negative == "lowres")
    #expect((r.width, r.height) == (832, 1216))
    #expect((r.steps, r.cfg, r.sampler, r.scheduler) == (30, 5, "euler", "normal"))
    #expect((r.seed, r.batchSize, r.clipSkip) == (7, 1, 2))
    #expect(r.split == nil)
}

@Test func sizeCanBeGivenPerRequest() {
    let preset = GenerationPreset(name: "Photo", checkpoint: "photo-xl.safetensors")
    let r = preset.request(prompt, seed: 1, width: 640, height: 480)
    #expect((r.width, r.height) == (640, 480))
}

@Test func splitPresetsLoadTheirParts() {
    let flux = GenerationPreset(
        name: "Flux", family: .flux, checkpoint: "flux1-made-up-Q4.gguf", vae: "ae.safetensors",
        textEncoders: ["t5-made-up.gguf", "clip_l.safetensors", "extra.safetensors"], guidance: 2.5)
    let empty = ComposedPrompt(positive: "a fox", negative: " ", loras: [])
    #expect(
        flux.request(empty, seed: 1).split
            == SplitModelRequest(
                model: "flux1-made-up-Q4.gguf", textEncoders: ["t5-made-up.gguf", "clip_l.safetensors"],
                clipType: "flux", vae: "ae.safetensors", guidance: 2.5, zeroNegative: true))
    // A negative typed for Flux is still used.
    #expect(flux.request(prompt, seed: 1).split?.zeroNegative == false)

    let zImage = GenerationPreset(
        name: "Z", family: .zImage, checkpoint: "z_image_turbo-Q4.gguf", vae: "ae.safetensors",
        textEncoders: ["qwen-made-up.gguf"], shift: 3)
    #expect(
        zImage.request(empty, seed: 1).split
            == SplitModelRequest(
                model: "z_image_turbo-Q4.gguf", textEncoders: ["qwen-made-up.gguf"], clipType: "lumina2",
                vae: "ae.safetensors", shift: 3))

    let anima = GenerationPreset(
        name: "Anima", family: .anima, checkpoint: "anima-made-up.safetensors",
        vae: "qwen-image-vae-made-up.safetensors", textEncoders: ["qwen3-0.6b-made-up.safetensors"])
    #expect(
        anima.request(prompt, seed: 1).split
            == SplitModelRequest(
                model: "anima-made-up.safetensors", textEncoders: ["qwen3-0.6b-made-up.safetensors"],
                clipType: "stable_diffusion", vae: "qwen-image-vae-made-up.safetensors",
                emptyLatent: "EmptyLatentImage"))

    let krea2 = GenerationPreset(
        name: "Krea 2", family: .krea2, checkpoint: "krea2-made-up.safetensors",
        vae: "qwen-image-vae-made-up.safetensors", textEncoders: ["qwen3vl-4b-made-up.safetensors"])
    var noNegative = empty
    noNegative.negative = ""
    #expect(
        krea2.request(noNegative, seed: 1).split
            == SplitModelRequest(
                model: "krea2-made-up.safetensors", textEncoders: ["qwen3vl-4b-made-up.safetensors"],
                clipType: "krea2", vae: "qwen-image-vae-made-up.safetensors", zeroNegative: true,
                emptyLatent: "EmptyLatentImage"))

    let flux2 = GenerationPreset(
        name: "Klein", family: .flux2, checkpoint: "flux-2-klein-9b-Q4.gguf", vae: "flux2-vae.safetensors",
        textEncoders: ["qwen-8b-made-up.safetensors"])
    let split = flux2.request(empty, seed: 1).split
    #expect(split?.clipType == "flux2")
    #expect(split?.sampling == .flux2)
    #expect(split?.zeroNegative == true)
    #expect(split?.guidance == nil)
}

@Test func problemsSayWhatIsMissing() {
    let catalog = ComfyCatalog()
    #expect(GenerationPreset(name: "New").problem(with: catalog)?.contains("has no model") == true)
    #expect(GenerationPreset(name: "Photo", checkpoint: "photo-xl.safetensors").problem(with: catalog) == nil)

    var flux = GenerationPreset(
        name: "Flux", family: .flux, checkpoint: "flux1-made-up-Q4.gguf", textEncoders: ["t5-made-up.gguf"])
    #expect(flux.problem(with: catalog)?.contains("two text encoders") == true)
    flux.textEncoders.append("clip_l.safetensors")
    #expect(flux.problem(with: catalog)?.contains("needs a VAE") == true)
    flux.vae = "ae.safetensors"
    // An empty catalog (not connected yet) doesn't report missing nodes.
    #expect(flux.problem(with: catalog) == nil)
}

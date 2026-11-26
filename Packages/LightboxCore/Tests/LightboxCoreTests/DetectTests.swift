import Foundation
import Testing

@testable import LightboxCore

private func detect(_ name: String, metadata: [String: String]? = nil, loras: [String] = []) -> Detection {
    PresetDetector.detect(checkpoint: name, metadata: metadata, loras: loras)
}

// The two checkpoints of the real test server.
@Test func detectsIllustriousAnime() {
    let d = detect("Sample_Illustrious_v1.safetensors")
    #expect(d.family == .illustrious)
    #expect(d.style == .anime)
    #expect(d.dialect == .tags)
    let p = d.preset(checkpoint: "Sample_Illustrious_v1.safetensors")
    #expect(p.name == "Sample Illustrious v1")
    #expect(p.clipSkip == 2)
    #expect(p.stylePrompt.contains("masterpiece"))
    #expect((p.width, p.height) == (832, 1216))
}

@Test func detectsSDXLPhoto() {
    let d = detect("PhotoReal-XL-v11.safetensors")
    #expect(d.family == .sdxl)
    #expect(d.style == .photo)
    #expect(d.dialect == .natural)
    let p = d.preset(checkpoint: "PhotoReal-XL-v11.safetensors")
    #expect(p.sampler == "dpmpp_2m_sde")
    #expect(p.cfg < 6)
    #expect(p.negativePrompt.contains("anime"))
}

@Test(arguments: [
    ("ponyDiffusionV6XL_v6.safetensors", ModelFamily.pony, PictureStyle.anime),
    ("ponyRealism_v22.safetensors", .pony, .photo),
    ("sdxl/RealVisXL_V4.0.safetensors", .sdxl, .photo),
    ("animagine-xl-3.1.safetensors", .sdxl, .anime),
    ("dreamshaperXL_v21.safetensors", .sdxl, .illustration),
    ("sd_xl_base_1.0.safetensors", .sdxl, .illustration),
    ("sd15/dreamshaper_8.safetensors", .sd15, .illustration),
    ("realisticVisionV60B1_v51VAE.safetensors", .sd15, .photo),
    ("anything-v5.safetensors", .sd15, .anime),
    ("noobaiXLNAIXL_vPred10.safetensors", .illustrious, .anime),
    ("flux1-dev-fp8.safetensors", .flux, .illustration),
    ("flux1-krea-Q4.gguf", .flux, .photo),
    ("z_image_turbo-Q4.gguf", .zImage, .photo),
    ("sd3.5_large.safetensors", .unsupported, .illustration),
    ("flux-2-klein-9b-Q4.gguf", .flux2, .illustration),
    ("flux2-dev.safetensors", .flux2, .illustration),
    ("anima-2b-made-up.safetensors", .anima, .anime),
    ("krea2_turbo_made-up.safetensors", .krea2, .photo),
    ("animagine-made-up-xl.safetensors", .sdxl, .anime),
])
func detectsFamilyAndStyle(_ name: String, _ family: ModelFamily, _ style: PictureStyle) {
    let d = detect(name)
    #expect(d.family == family, "\(name): \(d.notes)")
    #expect(d.style == style, "\(name): \(d.notes)")
}

@Test func ponyPresetUsesScoreTags() {
    let p = detect("ponyDiffusionV6XL.safetensors").preset(checkpoint: "ponyDiffusionV6XL.safetensors")
    #expect(p.stylePrompt.hasPrefix("score_9, score_8_up"))
    #expect(p.stylePrompt.contains("source_anime"))
    #expect(p.negativePrompt.hasPrefix("score_4"))
}

@Test func shortFragmentsMatchWholeWordsOnly() {
    // "art" in "smart", "real" in "surreal" and "ill" in "still" say nothing.
    let d = detect("smartSurreal_still.safetensors")
    #expect(d.family == .sdxl)
    #expect(d.style == .illustration)
}

@Test func metadataArchitectureBeatsTheName() {
    let d = detect("mymodel.safetensors", metadata: ["modelspec.architecture": "stable-diffusion-v1"])
    #expect(d.family == .sd15)
    #expect(d.notes.first?.contains("stable-diffusion-v1") == true)
    let flux = detect("mymodel.safetensors", metadata: ["modelspec.architecture": "Flux.1-dev"])
    #expect(flux.family == .flux)
    let sd3 = detect("mymodel.safetensors", metadata: ["modelspec.architecture": "stable-diffusion-v3-medium"])
    #expect(sd3.family == .unsupported)
}

@Test func metadataBaseModelRevealsIllustrious() {
    let d = detect(
        "mix_v3.safetensors",
        metadata: ["ss_base_model_version": "sdxl_base_v1-0", "ss_sd_model_name": "Illustrious-XL-v0.1.safetensors"])
    #expect(d.family == .illustrious)
    #expect(d.style == .anime)
}

@Test func trainingTagsRevealTheStyle() {
    let booru = #"{"10_data": {"1girl": 300, "solo": 250, "smile": 80}}"#
    #expect(detect("custom_v1.safetensors", metadata: ["ss_tag_frequency": booru]).style == .anime)
    let photo = #"{"img": {"photo": 120, "woman": 90}}"#
    #expect(detect("custom_v1.safetensors", metadata: ["ss_tag_frequency": photo]).style == .photo)
}

@Test func detectsSpeedVariants() {
    let lightning = detect("photoXL_v9Lightning.safetensors")
    #expect(lightning.speed == .lightning)
    let p = lightning.preset(checkpoint: "x")
    #expect(p.steps <= 8)
    #expect(p.cfg <= 2)
    #expect(p.style == .photo)

    #expect(detect("sdxl_lcm_model.safetensors").speed == .lcm)
    #expect(detect("dreamshaperXL_turboDPMSDE.safetensors").speed == .turbo)
}

@Test func speedLoraSetsStepsAndKeepsCFG() {
    // The real server's only LoRA.
    let d = detect("Sample_Illustrious_v1.safetensors", loras: ["Hyper-XL-8steps-CFG-lora.safetensors"])
    #expect(d.speed == .hyper)
    #expect(d.namedSteps == 8)
    #expect(d.keepsCFG)
    let p = d.preset(checkpoint: "x")
    #expect(p.steps == 8)
    #expect(p.cfg > 1 && p.cfg <= 5)

    let plain = detect("model.safetensors", loras: ["Hyper-SDXL-4steps-lora.safetensors"]).preset(checkpoint: "x")
    #expect(plain.steps == 4)
    #expect(plain.cfg == 1)
}

@Test func applyKeepsNameCheckpointAndLoras() {
    var p = GenerationPreset(name: "Mine", checkpoint: "PhotoReal-XL-v11.safetensors", vae: "sdxl_vae.safetensors")
    p.loras = [LoraSlot(name: "detail.safetensors")]
    detect(p.checkpoint).apply(to: &p)
    #expect(p.name == "Mine")
    #expect(p.vae == "sdxl_vae.safetensors")
    #expect(p.loras.count == 1)
    #expect(p.style == .photo)
    #expect(!p.detectionNotes.isEmpty)
}

@Test func splitsNames() {
    #expect(Name("RealVisXL_V4.0").tokens == ["real", "vis", "xl", "v", "4", "0"])
    #expect(Name("ponyDiffusionV6XL").tokens == ["pony", "diffusion", "v", "6", "xl"])
    #expect(Name("Hyper-XL-8steps").steps == 8)
}

@Test func newCheckpointsAreThoseNeverOffered() throws {
    var library = Library(presets: [GenerationPreset(name: "A", checkpoint: "a.safetensors")])
    let server = ["a.safetensors", "b.safetensors", "c.safetensors"]
    #expect(library.newCheckpoints(server) == ["b.safetensors", "c.safetensors"])
    // b was offered and its preset deleted: it doesn't come back.
    library.knownCheckpoints = ["b.safetensors"]
    #expect(library.newCheckpoints(server) == ["c.safetensors"])

    let old = Data(#"{"presets": [], "rating": "allAges"}"#.utf8)
    #expect(try JSONDecoder().decode(Library.self, from: old).knownCheckpoints.isEmpty)
}

// The two split models of the real test server.
@Test func fluxKreaGetsGuidanceAndNoNegative() {
    let p = detect("flux1-krea-Q4.gguf").preset(checkpoint: "flux1-krea-Q4.gguf")
    #expect(p.family == .flux)
    #expect(p.dialect == .natural)
    #expect((p.sampler, p.scheduler, p.steps, p.cfg) == ("euler", "simple", 24, 1))
    #expect(p.guidance == 4.5)
    #expect(p.negativePrompt.isEmpty && p.stylePrompt.isEmpty)
    #expect(p.clipSkip == 1)
    #expect(p.detectionNotes.contains { $0.contains("separate files") })
}

@Test func zImageTurboRunsInNineStepsWithoutCFG() {
    let d = detect("z_image_turbo-Q4.gguf")
    #expect(d.speed == .turbo)
    let p = d.preset(checkpoint: "z_image_turbo-Q4.gguf")
    #expect((p.sampler, p.scheduler, p.steps, p.cfg, p.shift) == ("euler", "simple", 9, 1, 3))
    #expect(p.dialect == .natural)
    #expect(p.width * p.height > 1_000_000)
}

@Test func animaSamplesLikeItsWorkflows() {
    let p = detect("anima-2b-made-up.safetensors").preset(checkpoint: "anima-2b-made-up.safetensors")
    #expect((p.sampler, p.scheduler, p.steps, p.cfg) == ("euler", "simple", 30, 4))
    #expect(p.negativePrompt.contains("score_1"))
    #expect(p.family.isSplit && p.family.textEncoderCount == 1)
}

@Test func krea2TurboSamplesInEightStepsWithoutCFG() {
    let d = detect("krea2_turbo_made-up.safetensors")
    #expect(d.speed == .turbo)
    let p = d.preset(checkpoint: "krea2_turbo_made-up.safetensors")
    #expect((p.sampler, p.scheduler, p.steps, p.cfg) == ("euler", "simple", 8, 1))
    #expect(p.negativePrompt.isEmpty && p.dialect == .natural)
    #expect(p.family.isSplit && p.family.textEncoderCount == 1)
    // Flux Krea stays Flux.
    #expect(detect("flux1-krea-Q4.gguf").family == .flux)
}

@Test func unknownDiffusionModelsSayHowToPickTheFamily() {
    let d = PresetDetector.detect(checkpoint: "WesternSample_v1.safetensors", diffusionModel: true)
    #expect(d.family == .unsupported)
    #expect(d.notes.contains { $0.contains("Anima") })
    // Picked by hand in the preset, it stays, with Anima's settings.
    let picked = PresetDetector.detect(
        checkpoint: "WesternSample_v1.safetensors", diffusionModel: true, chosen: .anima)
    #expect((picked.family, picked.style) == (.anima, .anime))
    #expect(picked.preset(checkpoint: "WesternSample_v1.safetensors").cfg == 4)
    // A name that says what it is wins over the pick.
    #expect(
        PresetDetector.detect(checkpoint: "z_image_turbo-Q4.gguf", diffusionModel: true, chosen: .anima).family
            == .zImage)
    // Checkpoints aren't affected.
    #expect(PresetDetector.detect(checkpoint: "WesternSample_v1.safetensors", chosen: .anima).family == .sdxl)
}

@Test func fluxSchnellIsFast() {
    let p = detect("flux1-schnell-fp8.safetensors").preset(checkpoint: "flux1-schnell-fp8.safetensors")
    #expect(p.steps == 4)
    #expect(p.guidance == 3.5)
}

@Test func splitModelsFindTheirTextEncodersAndVAE() {
    let encoders = ["qwen3-4b-encoder-Q4.gguf", "clip_l.safetensors", "t5-xxl-encoder-Q4.gguf"]
    let vaes = ["ae.safetensors", "pixel_space"]
    let flux = SplitParts.choose(for: .flux, textEncoders: encoders, vaes: vaes)
    #expect(flux.textEncoders == ["t5-xxl-encoder-Q4.gguf", "clip_l.safetensors"])
    #expect(flux.vae == "ae.safetensors")
    #expect(flux.notes.count == 3)
    let z = SplitParts.choose(for: .zImage, textEncoders: encoders, vaes: vaes)
    #expect(z.textEncoders == ["qwen3-4b-encoder-Q4.gguf"])
    #expect(z.vae == "ae.safetensors")

    let missing = SplitParts.choose(for: .flux, textEncoders: ["clip_l.safetensors"], vaes: ["pixel_space"])
    #expect(missing.textEncoders == ["clip_l.safetensors"])
    #expect(missing.vae == nil)
    #expect(missing.notes.contains { $0.contains("t5xxl") })
    #expect(SplitParts.choose(for: .sdxl, textEncoders: encoders, vaes: vaes).textEncoders.isEmpty)

    // Anima takes the 0.6B Qwen3 only, and the Qwen-Image VAE.
    let anima = SplitParts.choose(
        for: .anima, textEncoders: encoders + ["qwen3-0.6b-made-up.safetensors"],
        vaes: vaes + ["qwen-image-vae-made-up.safetensors"])
    #expect(anima.textEncoders == ["qwen3-0.6b-made-up.safetensors"])
    #expect(anima.vae == "qwen-image-vae-made-up.safetensors")
    let krea2 = SplitParts.choose(
        for: .krea2, textEncoders: encoders + ["qwen3vl-4b-made-up.safetensors"],
        vaes: vaes + ["qwen-image-vae-made-up.safetensors"])
    #expect(krea2.textEncoders == ["qwen3vl-4b-made-up.safetensors"])
    #expect(krea2.vae == "qwen-image-vae-made-up.safetensors")
    let none = SplitParts.choose(for: .anima, textEncoders: encoders, vaes: vaes)
    #expect(none.textEncoders.isEmpty && none.vae == nil)
}

@Test func splitFamiliesHaveNoGuidesAndOwnLoRAs() {
    #expect(ModelFamily.flux.isSplit && !ModelFamily.flux.supportsGuides)
    #expect(ModelFamily.sdxl.supportsGuides)
    let info = LoraInfo(family: .flux, kind: .style, triggers: [], suggestions: [], strength: 1, notes: [])
    #expect(info.mismatch(with: .sdxl)?.contains("won't work") == true)
    #expect(info.mismatch(with: .flux) == nil)
}

@Test func oldPresetsLoadWithoutSplitFields() throws {
    let old = try JSONEncoder().encode(GenerationPreset(name: "Old"))
    var json = try JSONSerialization.jsonObject(with: old) as! [String: Any]
    for key in ["textEncoders", "guidance", "shift"] { json[key] = nil }
    let p = try JSONDecoder().decode(GenerationPreset.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(p.textEncoders.isEmpty && p.guidance == 3.5 && p.shift == 3)
}

@Test func unknownDiffusionModelsAreNotTakenForSDXL() {
    #expect(
        PresetDetector.detect(checkpoint: "wan2.1_t2v_14B.safetensors", diffusionModel: true).family == .unsupported)
    #expect(PresetDetector.detect(checkpoint: "flux1-dev.safetensors", diffusionModel: true).family == .flux)
}

@Test func flux2KleinRunsInFourStepsWithItsOwnParts() {
    let p = detect("flux-2-klein-9b-Q4.gguf").preset(checkpoint: "flux-2-klein-9b-Q4.gguf")
    #expect(p.family == .flux2 && p.dialect == .natural)
    #expect((p.steps, p.cfg, p.sampler) == (4, 1, "euler"))
    #expect(p.negativePrompt.isEmpty)
    let base = detect("flux-2-klein-base-9b.safetensors").preset(checkpoint: "flux-2-klein-base-9b.safetensors")
    #expect((base.steps, base.cfg) == (28, 4))

    let encoders = ["qwen3-4b-encoder-Q4.gguf", "clip_l.safetensors", "qwen_3_8b.safetensors"]
    let vaes = ["ae.safetensors", "flux2-vae.safetensors", "pixel_space"]
    let nine = SplitParts.choose(
        for: .flux2, model: "flux-2-klein-9b-Q4.gguf", textEncoders: encoders, vaes: vaes)
    #expect(nine.textEncoders == ["qwen_3_8b.safetensors"])
    #expect(nine.vae == "flux2-vae.safetensors")
    let four = SplitParts.choose(for: .flux2, model: "flux-2-klein-4b.safetensors", textEncoders: encoders, vaes: vaes)
    #expect(four.textEncoders == ["qwen3-4b-encoder-Q4.gguf"])
    #expect(ModelFamily.flux2.isSplit && !ModelFamily.flux2.supportsGuides)
}

@Test func presetsKeepTheirPicture() throws {
    var p = GenerationPreset(name: "Photo", checkpoint: "photo-xl.safetensors")
    p.picture = UUID()
    let again = try JSONDecoder().decode(GenerationPreset.self, from: JSONEncoder().encode(p))
    #expect(again.picture == p.picture)
    // Presets saved before pictures had them still load.
    let old = try JSONDecoder().decode(GenerationPreset.self, from: Data(#"{"name":"Old"}"#.utf8))
    #expect(old.picture == nil)
}

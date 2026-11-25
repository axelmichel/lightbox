import ComfyKit
import Foundation
import LightboxCore
import Testing

@testable import LightboxUI

private let preset = GenerationPreset(
    name: "Photo", checkpoint: "photo-xl.safetensors", sampler: "euler", scheduler: "normal", steps: 30, cfg: 5,
    width: 832, height: 1216, clipSkip: 2,
    loras: [LoraSlot(name: "ink-style.safetensors", strength: 0.6, triggers: "ink wash")])

private func target() -> GraphTarget {
    var t = GraphTarget(preset: preset)
    t.seedText = "7"
    t.extraLoras = [LoraSlot(name: "grain.safetensors", strength: 0.5)]
    t.guides = [GraphTarget.GuideReach(strength: 0.6, start: 0, end: 0.8)]
    t.finish = FinishSettings(fixFaces: true, faceStrength: 0.4)
    return t
}

/// What the form sends for `t`, as the graph shows it: composed, the
/// preset with the workflow's changes, the guides and the finish.
private func settings(_ t: GraphTarget) throws -> GraphSettings {
    let p = t.effectivePreset
    let prompt = try compose(PromptInput(preset: p, prompt: "a fox", extraLoras: t.extraLoras, rating: .allAges))
    let guides = t.guides.map {
        GuideRequest(
            setup: .controlNet(model: "depth.safetensors", unionType: nil, extractor: nil), image: Data(),
            filename: "g.png", strength: $0.strength, startPercent: $0.start, endPercent: $0.end)
    }
    let request = p.request(
        prompt, seed: Int(t.seedText) ?? 0, width: t.size?.width, height: t.size?.height, guides: guides,
        faceFix: t.finish.fixFaces ? DetailerRequest(detector: "face.pt", denoise: t.finish.faceStrength) : nil)
    return GraphSettings(request)
}

/// Each change, put into the form, comes back as that change from the graph.
@Test(arguments: [
    GraphChange.steps(12), .cfg(3.5), .sampler("dpmpp_2m"), .scheduler("karras"), .clipSkip(1),
    .checkpoint("photo-xl-v2.safetensors"), .vae("sdxl-vae.safetensors"), .size(width: 1024, height: 1024),
    .seed(99), .lora(name: "grain.safetensors", strength: 0.9, clipStrength: 0.9),
    .lora(name: "ink-style.safetensors", strength: 0.3, clipStrength: 0.1),
    .guide(index: 0, strength: 0.4, start: 0.1, end: 0.7), .faceFix(0.55),
])
func changesComeBackFromTheGraph(_ change: GraphChange) throws {
    let before = target()
    var after = before
    after.apply(change)
    #expect(GraphChange.changes(from: try settings(before), to: try settings(after)) == [change])
    // The preset itself never changes.
    #expect(after.preset == preset)
}

@Test func presetValuesBecomeOverrides() {
    var t = target()
    t.apply(.steps(12))
    t.apply(.sampler("dpmpp_2m"))
    #expect(t.overrides.steps == 12 && t.overrides.sampler == "dpmpp_2m")
    #expect(t.effectivePreset.steps == 12 && t.effectivePreset.stylePrompt == preset.stylePrompt)
    // Back to the preset's value: no longer an override.
    t.apply(.steps(30))
    #expect(t.overrides.steps == nil)
    t.apply(.size(width: 832, height: 1216))
    #expect(t.size == nil)
}

@Test func aPresetLoraAtAnotherStrengthBecomesAnExtraOne() {
    var t = target()
    t.apply(.lora(name: "ink-style.safetensors", strength: 0.3, clipStrength: 0.3))
    let extra = t.extraLoras.last
    #expect(extra?.name == "ink-style.safetensors")
    #expect(extra?.strength == 0.3 && extra?.clipStrength == nil)
    #expect(extra?.triggers == "ink wash")
    // Changed again, the same slot changes.
    t.apply(.lora(name: "ink-style.safetensors", strength: 0.2, clipStrength: 0.1))
    #expect(t.extraLoras.count == 2)
    #expect(t.extraLoras.last?.clipStrength == 0.1)
}

@Test func lockedPartsAreNoChanges() throws {
    var a = try settings(target())
    var b = a
    b.positive = "something else"
    b.negative = nil
    b.batchSize = 4
    #expect(GraphChange.changes(from: a, to: b).isEmpty)
    // A LoRA that came or went is a structure change (later), not a value.
    a.loras.removeLast()
    #expect(GraphChange.changes(from: a, to: try settings(target())).isEmpty)
}

@Test func overridesReadWithThePresetsValues() {
    var o = PresetOverrides()
    o.steps = 12
    o.cfg = 3.5
    o.checkpoint = "sdxl/photo-xl-v2.safetensors"
    #expect(
        o.lines(for: preset) == [
            "Model: photo-xl-v2.safetensors (preset photo-xl.safetensors)", "Steps: 12 (preset 30)",
            "CFG: 3.5 (preset 5)",
        ])
    #expect(PresetOverrides().lines(for: preset).isEmpty)
}

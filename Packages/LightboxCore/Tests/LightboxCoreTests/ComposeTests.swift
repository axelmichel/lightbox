import Testing

@testable import LightboxCore

private let preset = GenerationPreset(
    name: "Anime", stylePrompt: "masterpiece, best quality", negativePrompt: "lowres, bad hands",
    loras: [LoraSlot(name: "style.safetensors", strength: 0.6, triggers: "ink style")])

@Test func composesStyleTriggersAndPrompt() throws {
    let c = try compose(PromptInput(preset: preset, prompt: "a fox in the snow, best quality", rating: .allAges))
    #expect(c.positive == "masterpiece, best quality, ink style, a fox in the snow")
    #expect(c.negative.hasPrefix("lowres, bad hands"))
    #expect(c.negative.contains("nsfw"))
    #expect(c.loras == [LoraUse(name: "style.safetensors", weight: 0.6)])
}

@Test func extraLoraOverridesThePresetsStrength() throws {
    let c = try compose(
        PromptInput(
            preset: preset, prompt: "fox", extraLoras: [LoraSlot(name: "style.safetensors", strength: 1.0)],
            rating: .mature))
    #expect(c.loras == [LoraUse(name: "style.safetensors", weight: 1.0)])
}

@Test func unbalancedWeightsDontSpillIntoNegatives() throws {
    let c = try compose(PromptInput(preset: preset, prompt: "fox", negative: "[[[blurry", rating: .allAges))
    #expect(!c.negative.contains("["))
    #expect(c.negative.contains("nsfw"))
}

@Test func guardRunsOnThePrompt() {
    #expect(throws: GuardError.self) {
        try compose(PromptInput(preset: preset, prompt: "a little girl in lingerie", rating: .mature))
    }
    #expect(throws: GuardError.self) {
        try compose(PromptInput(preset: preset, prompt: "nude", rating: .allAges))
    }
}

@Test func childrenInNormalScenesCompose() throws {
    let c = try compose(PromptInput(preset: preset, prompt: "two kids flying a kite on the beach", rating: .mature))
    #expect(c.minorSignal != nil)
    #expect(c.negative.contains("nude"))
}

@Test func sexualTriggerWordWithChildIsBlocked() {
    var p = preset
    p.loras = [LoraSlot(name: "x.safetensors", triggers: "seductive")]
    #expect(throws: GuardError.self) {
        try compose(PromptInput(preset: p, prompt: "a child at the park", rating: .mature))
    }
}

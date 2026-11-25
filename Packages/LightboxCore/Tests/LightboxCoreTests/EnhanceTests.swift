import Testing

@testable import LightboxCore

@Test func illustriousGetsDanbooruTags() {
    let p = GenerationPreset(
        name: "Anime Sample", family: .illustrious, style: .anime, dialect: .tags,
        stylePrompt: "masterpiece, best quality")
    let text = PromptEnhancer.instructions(preset: p, triggers: ["ink style"])
    #expect(text.contains("Danbooru tags"))
    #expect(text.contains("masterpiece, best quality, ink style"))
    #expect(!text.contains("sentences"))
}

@Test func sdxlPhotoGetsSentences() throws {
    let film = try #require(StyleModifier.builtIns.first { $0.category == .film })
    var p = GenerationPreset(name: "Photo Sample", family: .sdxl, style: .photo, dialect: .natural)
    p.enhanceHint = "Prefer outdoor scenes."
    let text = PromptEnhancer.instructions(preset: p, modifiers: [film], direction: "make it rainy")
    #expect(text.contains("sentences"))
    #expect(text.contains("photograph"))
    #expect(text.contains(film.positive))
    #expect(text.contains("For this model: Prefer outdoor scenes."))
    #expect(text.contains("The user also wants: make it rainy"))
}

@Test func sd15TagsAreNotDanbooru() {
    let p = GenerationPreset(name: "SD", family: .sd15, style: .illustration, dialect: .tags)
    let text = PromptEnhancer.instructions(preset: p)
    #expect(text.contains("comma-separated tags"))
    #expect(!text.contains("Danbooru"))
    #expect(!text.contains("added automatically"))
}

@Test func instructionsAlwaysProtectMinors() {
    for style in PictureStyle.allCases {
        let text = PromptEnhancer.instructions(preset: GenerationPreset(name: "P", style: style))
        #expect(text.contains("Never describe a child or minor in a sexual"))
    }
}

@Test func cleanStripsTheClutter() {
    #expect(PromptEnhancer.clean("Prompt: a fox in the snow") == "a fox in the snow")
    #expect(PromptEnhancer.clean("**Improved prompt:** a fox") == "a fox")
    #expect(PromptEnhancer.clean("\"1girl, red scarf\"\n") == "1girl, red scarf")
    #expect(PromptEnhancer.clean("```\nfox, snow\n```") == "fox, snow")
    #expect(PromptEnhancer.clean("<think>hmm, foxes</think>\n“a red fox”") == "a red fox")
    #expect(PromptEnhancer.clean("a fox's den") == "a fox's den")
}

import Foundation
import Testing

@testable import LightboxCore

private let photo = GenerationPreset(
    name: "Photo", style: .photo, stylePrompt: "photograph, sharp focus", negativePrompt: "cartoon")

private func builtIn(_ name: String) throws -> StyleModifier {
    try #require(StyleModifier.builtIns.first { $0.name == name })
}

@Test func modifiersGoAfterThePrompt() throws {
    let film = try builtIn("Portra 400")
    let light = try builtIn("Golden Hour")
    let c = try compose(
        PromptInput(preset: photo, prompt: "a fisherman mending nets", modifiers: [light, film], rating: .allAges))
    #expect(c.positive.hasPrefix("photograph, sharp focus, a fisherman mending nets, golden hour"))
    #expect(c.positive.hasSuffix("warm natural skin tones"))
}

@Test func modifierNegativesAndDuplicatesAreMerged() throws {
    let bw = try builtIn("HP5 Black and White")
    let c = try compose(
        PromptInput(
            preset: photo, prompt: "old man, film grain", negative: "Color", modifiers: [bw], rating: .allAges))
    #expect(c.negative.hasPrefix("cartoon, Color"))
    #expect(!c.negative.contains("color,"))
    #expect(c.positive.components(separatedBy: "film grain").count == 2)
}

@Test func categoriesFollowThePresetsStyle() {
    #expect(ModifierCategory.active(for: .photo) == [.camera, .light, .film])
    #expect(ModifierCategory.active(for: .anime) == [.comic])
    #expect(ModifierCategory.active(for: .illustration) == [.comic])
}

@Test func guardChecksModifierText() {
    let bad = StyleModifier(name: "Pin-up", category: .film, positive: "seductive pose, lingerie")
    #expect(throws: GuardError.self) {
        try compose(PromptInput(preset: photo, prompt: "a child at the beach", modifiers: [bad], rating: .mature))
    }
}

@Test func kidsWithAFilmLookCompose() throws {
    let film = try builtIn("Polaroid")
    let c = try compose(
        PromptInput(preset: photo, prompt: "kids building a sandcastle", modifiers: [film], rating: .allAges))
    #expect(c.minorSignal != nil)
    #expect(c.positive.contains("polaroid photo"))
}

@Test func builtInIDsAreUniqueAndStable() {
    let ids = StyleModifier.builtIns.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.first?.uuidString == "5A7E0000-0000-4000-8000-000000000001")
    #expect(ModifierCategory.allCases.allSatisfy { c in StyleModifier.builtIns.contains { $0.category == c } })
}

// MARK: - Library

@Test func oldLibraryGetsTheBuiltInStyles() throws {
    let old = Data(#"{"presets": [], "rating": "teen"}"#.utf8)
    let lib = try JSONDecoder().decode(Library.self, from: old)
    #expect(lib.rating == .teen)
    #expect(lib.modifiers == StyleModifier.builtIns)
    #expect(lib.loraNotes.isEmpty)
}

@Test func editedBuiltInsAndOwnStylesSurviveARoundTrip() throws {
    var lib = Library()
    lib.modifiers[0].positive = "28mm lens"
    lib.modifiers.append(StyleModifier(name: "Mine", category: .comic, positive: "crayon"))
    lib.loraNotes["a.safetensors"] = LoraNote(
        name: "a.safetensors", triggers: "ink", notes: "Good at 0.7", edited: true)
    let back = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(lib))
    #expect(back == lib)
    #expect(back.modifiers[0].positive == "28mm lens")
    #expect(back.modifiers[0].original?.positive != "28mm lens")
}

@Test func presetsWithoutEnhanceHintLoad() throws {
    var object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) as? [String: Any])
    object["enhanceHint"] = nil
    let p = try JSONDecoder().decode(GenerationPreset.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(p.enhanceHint == "")
    #expect(p.stylePrompt == photo.stylePrompt)
}

@Test func loraNoteStartsFromTheDetector() {
    let info = LoraInfo(
        family: .illustrious, kind: .style, triggers: ["ink style", "inkwash"], suggestions: [], strength: 0.8,
        notes: [])
    let note = LoraNote(detected: info, name: "ink.safetensors")
    #expect(note.triggers == "ink style, inkwash")
    #expect(note.strength == 0.8)
    #expect(note.family == .illustrious)
    #expect(!note.edited)
}

import Foundation
import Testing

@testable import LightboxCore

/// Header metadata of real LoRAs, cut down to the fields the detector reads
/// and the 60 most frequent tags (`Fixtures/lora_metadata.json`).
private let fixture: [String: [String: String]] = {
    let url = Bundle.module.url(forResource: "lora_metadata", withExtension: "json", subdirectory: "Fixtures")!
    return try! JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
}()

private func detect(_ name: String) -> LoraInfo {
    LoraDetector.detect(name: name, metadata: fixture[name])
}

@Test(arguments: [
    // A made-up word in every training picture.
    ("illustrious/New_toon_midjourney.safetensors", "toon4on"),
    // A character's name tag; the character's features are only suggestions.
    ("illustrious/heroineMR-sample-Illust-LoraV202.safetensors", "qvarra"),
    ("illustrious/characterSheetZyx_illus.safetensors", "charactersheetxzyx"),
    // kohya folder "20_cinematic film style".
    ("illustrious/cinematic film detailed illu xl v5.safetensors", "cinematic film style"),
    ("illustrious/Product_Design_Sketch_IL.safetensors", "product design sketch"),
    // Hyphenated style tags at lower shares; the more frequent one first.
    ("illustrious/Toon_style.safetensors", "g-cartoon"),
    ("illustrious/Toon_illustrious_style.safetensors", "s-cartoon"),
    // Quality tags in every picture are skipped; the style word is not.
    ("illustrious/hyperrealism_Sample_Style.safetensors", "hyperrealism"),
])
func findsTriggerWords(name: String, trigger: String) {
    let info = detect(name)
    #expect(info.triggers.first == trigger, "\(info.notes)")
}

@Test func otherStyleVariantsAreSuggested() {
    #expect(detect("illustrious/Toon_style.safetensors").suggestions.contains("s-cartoon"))
    let emma = detect("illustrious/heroineMR-sample-Illust-LoraV202.safetensors")
    #expect(emma.triggers == ["qvarra"])
    #expect(!emma.suggestions.contains("blonde hair"))
}

@Test(arguments: [
    "illustrious/PhotoRealTouch_IL-000008.safetensors",
    "illustrious/pose_helper.safetensors",
    "illustrious/background-detail-enhancer-illustrious.safetensors",
    "illustrious/Hero Character - XL IL V1.0.safetensors",
    "Hyper-XL-8steps-CFG-lora.safetensors",
])
func noTriggerWhenNothingStandsOut(name: String) {
    #expect(detect(name).triggers.isEmpty)
}

@Test func familyFromTrainingBaseThenName() {
    // Trained on Pony, though the name says "IL".
    #expect(detect("illustrious/Hero Character - XL IL V1.0.safetensors").family == .pony)
    #expect(detect("illustrious/Product_Design_Sketch_IL.safetensors").family == .illustrious)
    // Base "200000.safetensors" says nothing; the folder does.
    #expect(detect("illustrious/Toon_style.safetensors").family == .illustrious)
    // Its modelspec says SD 1.5, its base version and name say SDXL/Illustrious.
    #expect(detect("illustrious/Perspective_IllustXL_Slider_v1.0.safetensors").family == .illustrious)
    #expect(detect("Hyper-XL-8steps-CFG-lora.safetensors").family == .sdxl)
    #expect(
        LoraDetector.detect(name: "add_detail.safetensors", metadata: ["ss_base_model_version": "sd_v1"]).family
            == .sd15)
    #expect(LoraDetector.detect(name: "thing.safetensors").family == nil)
}

@Test func hyperrealismIsNotAHyperLoRA() {
    #expect(detect("illustrious/hyperrealism_Sample_Style.safetensors").kind == .style)
    let preset = PresetDetector.detect(
        checkpoint: "Sample_Illustrious_v1.safetensors", loras: ["illustrious/hyperrealism_Sample_Style.safetensors"])
    #expect(preset.speed == .standard)
    #expect(
        PresetDetector.detect(checkpoint: "x.safetensors", loras: ["Hyper-XL-8steps-CFG-lora.safetensors"]).speed
            == .hyper)
}

@Test func kindSetsTheStartingStrength() {
    let hyper = detect("Hyper-XL-8steps-CFG-lora.safetensors")
    #expect(hyper.kind == .speed && hyper.strength == 1)
    #expect(detect("illustrious/Detail_Boost_v1.0.safetensors").kind == .detail)
    #expect(detect("illustrious/background-detail-enhancer-illustrious.safetensors").strength == 0.6)
    #expect(detect("illustrious/Color slider - Illustrious_alpha1.0_rank4_noxattn_last.safetensors").kind == .slider)
    #expect(detect("illustrious/detailed hands focus style illustriousXL v1.safetensors").kind == .style)
    #expect(detect("illustrious/Toon_style.safetensors").strength == 0.8)
    let named = LoraDetector.detect(
        name: "x.safetensors", metadata: ["modelspec.description": "Best at weight 0.65 with Illustrious."])
    #expect(named.strength == 0.65)
    #expect(LoraDetector.recommendedWeight("use 0.7 strength") == 0.7)
    #expect(LoraDetector.recommendedWeight("trained for 3000 steps") == nil)
}

@Test func triggerPhraseInTheFileWins() {
    let info = LoraDetector.detect(
        name: "x.safetensors", metadata: ["modelspec.trigger_phrase": "zzstyle, ink wash", "ss_tag_frequency": "{}"])
    #expect(info.triggers == ["zzstyle", "ink wash"])
}

@Test func warnsWhenTheFamilyDoesNotFit() {
    let sd15 = LoraInfo(family: .sd15, kind: .other, triggers: [], suggestions: [], strength: 1, notes: [])
    #expect(sd15.mismatch(with: .illustrious)?.contains("won't work") == true)
    #expect(sd15.mismatch(with: .sd15) == nil)
    let pony = LoraInfo(family: .pony, kind: .other, triggers: [], suggestions: [], strength: 1, notes: [])
    #expect(pony.mismatch(with: .illustrious)?.contains("often") == true)
}

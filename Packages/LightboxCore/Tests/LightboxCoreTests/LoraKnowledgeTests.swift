import Foundation
import Testing

@testable import LightboxCore

@Test func hyperSDXLCFGGetsItsPublishedSettings() {
    let info = LoraDetector.detect(name: "Hyper-SD-XL-8steps-CFG-lora.safetensors")
    let page = info.about.joined(separator: "\n")
    #expect(page.contains("8 steps"))
    #expect(page.contains("CFG 5–8"))
    #expect(info.strength == 1)
    #expect(info.link == "https://huggingface.co/ByteDance/Hyper-SD")
    let note = LoraNote(detected: info, name: "Hyper-SD-XL-8steps-CFG-lora.safetensors")
    #expect(note.notes.contains("Hyper-SD (ByteDance)"))
    #expect(note.link == info.link)
}

@Test(arguments: [
    ("sdxl_lightning_4step_lora.safetensors", "4 steps, CFG 1"),
    ("lcm-lora-sdxl.safetensors", "sampler lcm"),
    ("dmd2_sdxl_4step_lora.safetensors", "4 steps, CFG 1"),
    ("add_detail.safetensors", "Detail Tweaker"),
])
func wellKnownLorasAreRecognized(_ name: String, _ expected: String) {
    #expect(LoraDetector.detect(name: name).about.joined(separator: "\n").contains(expected))
}

@Test func unknownLorasGetAdviceForTheirKind() {
    let info = LoraDetector.detect(name: "Color slider - Illustrious.safetensors")
    #expect(info.about.contains { $0.hasPrefix("Slider:") })
}

@Test func metadataBecomesASummaryAndASamplePrompt() {
    let meta = [
        "modelspec.title": "Ink Wash", "modelspec.author": "someone", "ss_sd_model_name": "illustriousXL_v01",
        "ss_num_train_images": "40", "ss_num_epochs": "10", "ss_resolution": "(1024, 1024)", "ss_network_dim": "16",
        "ss_dataset_dirs": #"{"10_inkwash": {"n_repeats": 10, "img_count": 40}}"#,
        "ss_tag_frequency":
            #"{"10_inkwash": {"inkwash": 40, "1girl": 30, "masterpiece": 40, "monochrome": 25, "nude": 20, "mountain": 18}}"#,
    ]
    let info = LoraDetector.detect(name: "ink.safetensors", metadata: meta)
    #expect(info.about.contains("Title: Ink Wash"))
    #expect(info.about.contains("By someone"))
    #expect(info.about.contains("Trained from “illustriousXL_v01”, 40 pictures, 10 epochs, at 1024,1024, rank 16."))
    #expect(info.samplePrompt.hasPrefix("inkwash, 1girl"))
    #expect(info.samplePrompt.contains("mountain"))
    #expect(!info.samplePrompt.contains("masterpiece"))
    #expect(!info.samplePrompt.contains("nude"))
}

// MARK: - Civitai

private let versionJSON = """
    {"id": 222, "modelId": 111, "name": "v1.0", "baseModel": "Illustrious", "trainedWords": [" inkwash ", ""],
     "description": "<p>Use at <b>weight 0.7</b>.</p>",
     "model": {"name": "Ink Wash Style", "type": "LORA"},
     "images": [
       {"nsfwLevel": 8, "url": "https://image.civitai.com/nsfw.jpeg", "meta": {"prompt": "not this one"}},
       {"nsfwLevel": 1, "type": "video", "url": "https://image.civitai.com/clip.mp4"},
       {"nsfwLevel": 1, "type": "image", "url": "https://image.civitai.com/safe.jpeg",
        "meta": {"prompt": "inkwash, mountain, river"}}
     ]}
    """

@Test func civitaiVersionsAreRead() throws {
    let json = try #require(try JSONSerialization.jsonObject(with: Data(versionJSON.utf8)) as? [String: Any])
    let m = try #require(CivitaiClient.version(json, model: json["model"] as? [String: Any], modelID: nil))
    #expect(m.name == "Ink Wash Style")
    #expect(m.trainedWords == ["inkwash"])
    #expect(m.family == .illustrious)
    #expect(m.strength == 0.7)
    #expect(m.samplePrompt == "inkwash, mountain, river")
    #expect(m.sampleImage?.absoluteString == "https://image.civitai.com/safe.jpeg")  // safe, and no video
    #expect(m.link == "https://civitai.com/models/111?modelVersionId=222")

    var note = LoraNote(name: "ink.safetensors", notes: "My own words.")
    note.merge(m)
    note.merge(m)
    #expect(note.triggers == "inkwash")
    #expect(note.strength == 0.7)
    #expect(note.edited)
    #expect(note.notes.components(separatedBy: "Civitai: ").count == 2)
    #expect(note.notes.hasSuffix("My own words."))
}

@Test func civitaiHTMLBecomesText() {
    let html = "<h2>About</h2><p>Soft&nbsp;ink &amp; wash.</p><ul><li>one</li><li>two</li></ul>"
    #expect(CivitaiClient.plainText(html) == "About\nSoft ink & wash.\n• one\n• two")
}

@Test(arguments: [
    ("SDXL 1.0", ModelFamily.sdxl), ("Pony", .pony), ("SD 1.5", .sd15), ("Flux.1 D", .flux), ("ZImageTurbo", .zImage),
    ("Flux.2 Klein 9B", .flux2), ("Anima", .anima),
    ("SD 3.5 Large", .unsupported),
])
func civitaiBaseModels(_ base: String, _ family: ModelFamily) {
    let m = CivitaiModel(
        modelID: 1, versionID: 1, name: "", version: "", baseModel: base, trainedWords: [], description: "")
    #expect(m.family == family)
}

@Test func loraNotesKeepTheirPicture() throws {
    var note = LoraNote(name: "ink.safetensors")
    note.picture = UUID()
    let back = try JSONDecoder().decode(LoraNote.self, from: JSONEncoder().encode(note))
    #expect(back.picture == note.picture)
    let old = try JSONDecoder().decode(LoraNote.self, from: Data(#"{"name": "a.safetensors"}"#.utf8))
    #expect(old.picture == nil)
}

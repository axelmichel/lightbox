import Foundation
import Testing

@testable import LightboxCore

private func recipe(_ prompt: String = "a fox") throws -> GenerationRecipe {
    let input = PromptInput(
        preset: GenerationPreset(name: "P", checkpoint: "m.safetensors"), prompt: prompt, rating: .allAges)
    return GenerationRecipe(input: input, sent: try compose(input), seed: 42, finish: FinishSettings())
}

/// A 4×2 red PNG.
private let png = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEklEQVR4nGP4z8AARwzEcQAA4Ef/AXTNWnsAAAAASUVORK5CYII=")!

@Test func foldersHoldPictures() throws {
    var index = GalleryIndex()
    let cats = index.addFolder(named: "Cats")
    let again = index.addFolder(named: "cats")
    #expect(again.name == "cats 2")
    let a = GalleryItem(width: 1, height: 1, recipe: try recipe())
    let b = GalleryItem(folderID: cats.id, width: 1, height: 1, recipe: try recipe())
    index.insert([a, b])
    #expect(index.count(.all) == 2)
    #expect(index.items(.folder(cats.id)).map(\.id) == [b.id])
    #expect(index.items(.unfiled).map(\.id) == [a.id])

    index.move([a.id], to: cats.id)
    #expect(index.count(.folder(cats.id)) == 2)
    index.move([a.id], to: UUID())  // unknown folder: nothing happens
    #expect(index.count(.folder(cats.id)) == 2)

    index.renameFolder(cats.id, to: "  Felines ")
    #expect(index.folder(cats.id)?.name == "Felines")
    index.removeFolder(cats.id)
    #expect(index.count(.unfiled) == 2)
}

@Test func storeWritesPicturesAndIndex() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "lightbox-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GalleryStore(root: root)
    #expect(try store.load() == GalleryIndex())

    var index = GalleryIndex()
    let folder = index.addFolder(named: "Tests")
    let item = try store.write(png: png, recipe: try recipe("a fox in the snow"), folderID: folder.id)
    #expect((item.width, item.height) == (4, 2))
    index.insert([item])
    try store.save(index)

    let loaded = try store.load()
    #expect(loaded.items.first?.recipe.prompt == "a fox in the snow")
    #expect(loaded.items.first?.recipe.seed == 42)
    #expect(loaded.items.first?.folderID == folder.id)
    #expect(try Data(contentsOf: store.imageURL(item.id)) == png)
    #expect(store.thumbnail(item.id) != nil)

    // A missing thumbnail is made again.
    try FileManager.default.removeItem(at: store.thumbnailURL(item.id))
    #expect(store.thumbnail(item.id) != nil)

    store.deleteFiles([item.id])
    #expect(!FileManager.default.fileExists(atPath: store.imageURL(item.id).path(percentEncoded: false)))
}

@Test func refusesNonImages() throws {
    let store = GalleryStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    #expect(throws: GalleryError.self) { try store.write(png: Data([1, 2, 3]), recipe: try recipe(), folderID: nil) }
}

@Test func recipeListsItsSettings() throws {
    let rows = try recipe().details
    #expect(rows.contains { $0.label == "Seed" && $0.value == "42" })
    #expect(rows.contains { $0.label == "Checkpoint" && $0.value == "m.safetensors" })
}

@Test func guidePicturesAreKeptWhileARecipeUsesThem() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "lightbox-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GalleryStore(root: root)
    var r = try recipe()
    r.guides = [.init(kind: "pose", strength: 0.8, image: "guide-1.png")]
    let guides = ["guide-1.png": png]
    var index = GalleryIndex()
    let a = try store.write(png: png, recipe: r, folderID: nil, guides: guides)
    let b = try store.write(png: png, recipe: r, folderID: nil, guides: guides)
    index.insert([a, b])
    #expect(store.guideImages(of: r) == guides)

    let unusedAfterA = index.remove([a.id])
    #expect(unusedAfterA.isEmpty)
    let unusedAfterB = index.remove([b.id])
    #expect(unusedAfterB == ["guide-1.png"])
    store.deleteFiles([a.id, b.id], guides: unusedAfterB)
    #expect(store.guideImages(of: r).isEmpty)
    // Names from the index can't reach outside the guides folder.
    #expect(store.guideURL("../../index.json").lastPathComponent == "index.json")
    #expect(store.guideURL("../../index.json").deletingLastPathComponent().lastPathComponent == "guides")
}

@Test func cutOutSitsBeforeItsOriginal() throws {
    var index = GalleryIndex()
    let a = GalleryItem(width: 1, height: 1, recipe: try recipe())
    let b = GalleryItem(width: 1, height: 1, recipe: try recipe())
    index.insert([a, b])
    let cut = GalleryItem(width: 1, height: 1, recipe: try recipe(), source: b.id, edge: 0.5)
    index.insert(cut, before: b.id)
    #expect(index.items.map(\.id) == [a.id, cut.id, b.id])
    #expect(cut.isCutOut && !b.isCutOut)
}

@Test func recipesWithoutGuidesStillLoad() throws {
    var r = try recipe()
    r.guides = [.init(kind: "depth", strength: 0.6, extract: false, image: "g.png")]
    let data = try JSONEncoder.gallery.encode(r)
    #expect(try JSONDecoder.gallery.decode(GenerationRecipe.self, from: data) == r)

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["guides"] = nil
    let old = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder.gallery.decode(GenerationRecipe.self, from: old).guides.isEmpty)
}

@Test func recipesKeepTheirStyles() throws {
    let film = try #require(StyleModifier.builtIns.first { $0.category == .film })
    let input = PromptInput(
        preset: GenerationPreset(name: "P", style: .photo, checkpoint: "m.safetensors"), prompt: "a pier",
        modifiers: [film], rating: .allAges)
    let r = GenerationRecipe(input: input, sent: try compose(input), seed: 1, finish: FinishSettings())
    #expect(r.details.contains { $0.label == "Film" && $0.value == film.name })
    let data = try JSONEncoder.gallery.encode(r)
    #expect(try JSONDecoder.gallery.decode(GenerationRecipe.self, from: data).modifiers == [film])

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["modifiers"] = nil
    let old = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder.gallery.decode(GenerationRecipe.self, from: old).modifiers.isEmpty)
}

// The app's real folder is ".../Application Support/Lightbox/Gallery".
@Test func galleryInAFolderWithSpacesLoads() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "Application Support \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GalleryStore(root: root.appending(path: "Gallery"))
    var index = GalleryIndex()
    let folder = index.addFolder(named: "Foxes")
    index.insert([try store.write(png: png, recipe: try recipe(), folderID: folder.id)])
    try store.save(index)

    let loaded = try store.load()
    #expect(loaded.items.count == 1)
    #expect(loaded.folders.map(\.name) == ["Foxes"])
    #expect(store.orphans(of: loaded).isEmpty)
}

/// `png` with a tEXt chunk after its header, as ComfyUI writes them.
private func png(withText key: String, _ value: String) -> Data {
    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }
    let body = Array("tEXt".utf8) + Array(key.utf8) + [0] + Array(value.utf8)
    var chunk = withUnsafeBytes(of: UInt32(body.count - 4).bigEndian) { Array($0) } + body
    chunk += withUnsafeBytes(of: crc32(body).bigEndian) { Array($0) }
    var bytes = [UInt8](png)
    bytes.insert(contentsOf: chunk, at: 8 + 25)  // signature + IHDR
    return Data(bytes)
}

@Test func picturesMissingFromTheIndexAreRecovered() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "lightbox \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GalleryStore(root: root)
    let graph = """
        {"3": {"class_type": "KSampler", "inputs": {"seed": 4242, "steps": 8, "cfg": 1.0, "sampler_name": "euler",
          "scheduler": "sgm_uniform", "model": ["10", 0], "positive": ["6", 0], "negative": ["7", 0],
          "latent_image": ["5", 0]}},
         "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "PhotoReal-XL-v11.safetensors"}},
         "10": {"class_type": "LoraLoader", "inputs": {"lora_name": "Hyper-XL-8steps-CFG-lora.safetensors",
           "strength_model": 1.0, "strength_clip": 1.0, "model": ["4", 0], "clip": ["4", 1]}},
         "5": {"class_type": "EmptyLatentImage", "inputs": {"width": 832, "height": 1216, "batch_size": 1}},
         "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "photograph, a lighthouse", "clip": ["10", 1]}},
         "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "blurry, nsfw", "clip": ["10", 1]}},
         "9": {"class_type": "PreviewImage", "inputs": {"images": ["8", 0]}}}
        """
    let picture = png(withText: "prompt", graph)
    #expect(GalleryStore.pngText(picture)["prompt"] == graph)

    let known = try store.write(png: png, recipe: try recipe(), folderID: nil)
    let lost = try store.write(png: picture, recipe: try recipe(), folderID: nil)
    var index = GalleryIndex()
    index.insert([known])
    let orphans = store.orphans(of: index)
    #expect(orphans.map(\.id) == [lost.id])

    let item = try #require(store.recover(lost.id, date: orphans[0].date, folderID: nil, rating: .allAges))
    #expect(item.id == lost.id)
    #expect((item.width, item.height) == (4, 2))
    let r = item.recipe
    #expect(r.preset.checkpoint == "PhotoReal-XL-v11.safetensors")
    #expect((r.preset.sampler, r.preset.steps, r.seed) == ("euler", 8, 4242))
    #expect(r.prompt == "photograph, a lighthouse")
    #expect(r.sent.negative == "blurry, nsfw")
    #expect(r.sent.loras == [LoraUse(name: "Hyper-XL-8steps-CFG-lora.safetensors", weight: 1)])

    // A picture without ComfyUI's prompt still comes back, without settings.
    try FileManager.default.removeItem(at: store.imageURL(lost.id))
    let plain = try store.write(png: png, recipe: try recipe(), folderID: nil)
    let bare = try #require(store.recover(plain.id, date: Date(), folderID: nil, rating: .allAges))
    #expect(bare.recipe.preset.checkpoint == "")
}

import Foundation
import Testing

@testable import LightboxCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "lightbox-workflows-\(UUID().uuidString)")
}

/// A 4×2 red PNG.
private let png = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEklEQVR4nGP4z8AARwzEcQAA4Ef/AXTNWnsAAAAASUVORK5CYII=")!

@Test func keepsWorkflowsAsComfyFiles() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowStore(root: root)
    #expect(try store.list().isEmpty)
    let file = Data(#"{"nodes":[],"links":[],"version":0.4}"#.utf8)
    let older = try store.save(
        WorkflowEntry(name: store.uniqueName("Workflow")), data: file, date: Date(timeIntervalSince1970: 1))
    let newer = try store.save(WorkflowEntry(name: store.uniqueName("Workflow")), data: file)
    #expect(newer.name == "Workflow 2")
    #expect(try store.list().map(\.id) == [newer.id, older.id])
    #expect(try store.load(older.id) == file)

    try store.rename(older.id, to: "  Foxes ")
    #expect(try store.list().last?.name == "Foxes")
    try store.delete(newer.id)
    #expect(try store.list().map(\.id) == [older.id])
    #expect(!FileManager.default.fileExists(atPath: store.fileURL(newer.id).path(percentEncoded: false)))
}

@Test func workflowsBelongToAPreset() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowStore(root: root)
    let file = Data(#"{"nodes":[],"links":[],"version":0.4}"#.utf8)
    let (photo, comic) = (UUID(), UUID())
    let a = try store.save(WorkflowEntry(name: "A", presetID: photo), data: file)
    let b = try store.save(WorkflowEntry(name: "B", presetID: photo), data: file)
    let c = try store.save(WorkflowEntry(name: "C", presetID: comic), data: file)
    #expect(Set(try store.list().filter { $0.presetID == photo }.map(\.id)) == [a.id, b.id])

    // Kept without a preset…
    try store.presetDeleted(photo, keepWorkflows: true)
    #expect(Set(try store.list().filter { $0.presetID == nil }.map(\.id)) == [a.id, b.id])
    #expect(try store.load(a.id) == file)
    // …or deleted with it.
    try store.presetDeleted(comic, keepWorkflows: false)
    #expect(!(try store.list().contains { $0.id == c.id }))
    #expect(!FileManager.default.fileExists(atPath: store.fileURL(c.id).path(percentEncoded: false)))
}

@Test func workflowEntriesWithoutAPresetStillLoad() throws {
    let json =
        #"{"version":1,"workflows":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","#
        + #""created":"2026-01-01T00:00:00Z","modified":"2026-01-01T00:00:00Z"}]}"#
    let index = try JSONDecoder.gallery.decode(WorkflowIndex.self, from: Data(json.utf8))
    #expect(index.workflows.first?.name == "Old")
    #expect(index.workflows.first?.presetID == nil)
    #expect(index.workflows.first?.overrides.isEmpty == true)
}

@Test func overridesChangeThePresetNotItsPrompts() throws {
    let preset = GenerationPreset(
        name: "Photo", checkpoint: "photo-xl.safetensors", sampler: "euler", scheduler: "normal", steps: 30, cfg: 5)
    var o = PresetOverrides()
    o.steps = 12
    o.sampler = "dpmpp_2m"
    o.checkpoint = "photo-xl-v2.safetensors"
    let p = o.applied(to: preset)
    #expect((p.steps, p.sampler, p.checkpoint, p.cfg) == (12, "dpmpp_2m", "photo-xl-v2.safetensors", 5))
    #expect(
        (p.id, p.stylePrompt, p.negativePrompt, p.dialect) == (
            preset.id, preset.stylePrompt, preset.negativePrompt, preset.dialect
        ))
    // Set back to the preset's value, the override goes.
    o.steps = 30
    var trimmed = o.trimmed(for: preset)
    #expect(trimmed.steps == nil && trimmed.sampler == "dpmpp_2m")
    #expect(trimmed.fields == [.checkpoint, .sampler])
    trimmed.reset(.sampler)
    trimmed.reset(.checkpoint)
    #expect(trimmed.isEmpty && trimmed.fields.isEmpty)

    // Kept with the workflow, and only written when there are any.
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowStore(root: root)
    let file = Data(#"{"nodes":[],"links":[],"version":0.4}"#.utf8)
    let saved = try store.save(WorkflowEntry(name: "A", overrides: o), data: file)
    #expect(try store.list().first { $0.id == saved.id }?.overrides == o)
    let plain = try JSONEncoder.gallery.encode(WorkflowEntry(name: "B"))
    #expect(!String(decoding: plain, as: UTF8.self).contains("overrides"))
}

@Test func picturesKeepTheWorkflowTheyWereMadeWith() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GalleryStore(root: root)
    let run = Data(#"{"workflow":{"nodes":[]},"prompt":{}}"#.utf8)
    let name = try store.writeWorkflowRun(run)
    // The same run gives the same file.
    #expect(try store.writeWorkflowRun(run) == name)
    #expect(store.workflowRun(name) == run)

    let api = try Data(
        contentsOf: #require(
            Bundle.module.url(forResource: "workflow_api", withExtension: "json", subdirectory: "Fixtures")))
    let recipe = GalleryStore.recipe(
        fromPrompt: api, name: "Foxes", width: 4, height: 2, rating: .allAges,
        sent: ComposedPrompt(positive: "a fox", negative: "blurry", loras: []))
    #expect(recipe.prompt == "a fox")
    #expect(recipe.sent.negative == "blurry")
    #expect(recipe.preset.name == "Foxes")
    #expect(!recipe.preset.checkpoint.isEmpty)

    var index = GalleryIndex()
    let workflow = WorkflowRun(workflowID: UUID(), name: "Foxes", file: name, node: "9")
    let a = try store.write(png: png, recipe: recipe, folderID: nil, workflow: workflow)
    let b = try store.write(png: png, recipe: recipe, folderID: nil, workflow: workflow)
    index.insert([a, b])
    try store.save(index)
    #expect(try store.load().items.first?.workflow == workflow)

    // Kept while a picture uses it.
    index.remove([a.id])
    #expect(index.workflowRunNames == [name])
    index.remove([b.id])
    #expect(index.workflowRunNames.isEmpty)
    store.deleteFiles([a.id, b.id], workflowRuns: [name])
    #expect(store.workflowRun(name) == nil)
}

@Test func olderIndexesWithoutWorkflowsStillLoad() throws {
    let json = #"{"version":1,"folders":[],"items":[]}"#
    let index = try JSONDecoder.gallery.decode(GalleryIndex.self, from: Data(json.utf8))
    #expect(index.items.isEmpty)
}

@Test func picturesCanNameTheirWorkflowWithoutKeepingIt() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GalleryStore(root: root)
    let recipe = GalleryStore.recipe(
        fromPrompt: Data("{}".utf8), name: "Foxes", width: 4, height: 2, rating: .allAges,
        sent: ComposedPrompt(positive: "a fox", negative: "", loras: []))
    let pointer = WorkflowRun(workflowID: UUID(), name: "Foxes")
    var index = GalleryIndex()
    index.insert([try store.write(png: png, recipe: recipe, folderID: nil, workflow: pointer)])
    try store.save(index)
    let loaded = try store.load()
    #expect(loaded.items.first?.workflow == pointer)
    #expect(loaded.workflowRunNames.isEmpty)
    // Entries written with a run file still read.
    let json = #"{"workflowID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","file":"ab.json","node":"9"}"#
    let old = try JSONDecoder.gallery.decode(WorkflowRun.self, from: Data(json.utf8))
    #expect((old.file, old.node) == ("ab.json", "9"))
}

@Test func presetLorasCanBeSwitchedOffInAWorkflow() throws {
    let preset = GenerationPreset(
        name: "Ink", checkpoint: "ink-xl.safetensors",
        loras: [LoraSlot(name: "ink.safetensors", strength: 0.6), LoraSlot(name: "grain.safetensors", strength: 0.3)])
    var o = PresetOverrides()
    o.disabledLoras = ["ink.safetensors", "gone.safetensors"]
    o = o.trimmed(for: preset)
    #expect(o.disabledLoras == ["ink.safetensors"])  // one the preset doesn't have is dropped
    #expect(o.fields == [.disabledLoras])
    let p = o.applied(to: preset)
    #expect(p.loras.map(\.isActive) == [false, true])
    // Composed, it isn't loaded; the preset itself keeps it.
    let sent = try compose(PromptInput(preset: p, prompt: "a fox", rating: .allAges))
    #expect(sent.loras.map(\.name) == ["grain.safetensors"])
    #expect(preset.loras[0].isActive)
    o.reset(.disabledLoras)
    #expect(o.isEmpty)
}

@Test func aPresetsTemplateGoesWithIt() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowStore(root: root)
    let file = Data(#"{"nodes":[],"links":[],"version":0.4}"#.utf8)
    let preset = UUID()
    let template = try store.save(WorkflowEntry(name: "T", presetID: preset, isTemplate: true), data: file)
    let workflow = try store.save(WorkflowEntry(name: "W", presetID: preset), data: file)
    #expect(try store.list().first { $0.id == template.id }?.isTemplate == true)
    #expect(try store.list().first { $0.id == workflow.id }?.isTemplate == false)
    // Workflows kept: the template goes all the same.
    try store.presetDeleted(preset, keepWorkflows: true)
    #expect(try store.list().map(\.id) == [workflow.id])
    // Only written when it is one.
    #expect(
        !String(decoding: try JSONEncoder.gallery.encode(WorkflowEntry(name: "B")), as: UTF8.self).contains(
            "isTemplate"))
    // Presets saved before templates had them still load.
    let old = try JSONDecoder().decode(GenerationPreset.self, from: Data(#"{"name":"Old"}"#.utf8))
    #expect(old.template == nil && !old.usesTemplate)
}

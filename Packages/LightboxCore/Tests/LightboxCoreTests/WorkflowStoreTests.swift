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

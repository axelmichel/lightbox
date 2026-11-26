import Foundation
import Testing

@testable import LightboxCore

private func item(_ prompt: String, folder: UUID? = nil, tags: [String]? = nil) throws -> GalleryItem {
    let input = PromptInput(
        preset: GenerationPreset(name: "Photo XL", checkpoint: "PhotoReal-XL-v11.safetensors"), prompt: prompt,
        rating: .allAges)
    var i = GalleryItem(
        folderID: folder, width: 1, height: 1,
        recipe: GenerationRecipe(input: input, sent: try compose(input), seed: 4242, finish: FinishSettings()))
    i.tags = tags
    return i
}

@Test func foldersNestAndRefuseCycles() {
    var index = GalleryIndex()
    let trips = index.addFolder(named: "Trips")
    let lisbon = index.addFolder(named: "Lisbon", in: trips.id)
    let tram = index.addFolder(named: "Trams", in: lisbon.id)
    #expect(index.children(of: nil).map(\.name) == ["Trips"])
    #expect(index.children(of: trips.id).map(\.name) == ["Lisbon"])
    #expect(index.path(of: tram.id) == "Trips › Lisbon › Trams")
    #expect(index.folderTree.map(\.depth) == [0, 1, 2])
    // The same name may be used in another folder, not next to it.
    let top = index.addFolder(named: "Lisbon")
    let twin = index.addFolder(named: "lisbon", in: trips.id)
    #expect(top.name == "Lisbon")
    #expect(twin.name == "lisbon 2")

    let intoOwnChild = index.moveFolder(trips.id, into: tram.id)
    let intoItself = index.moveFolder(trips.id, into: trips.id)
    let toTop = index.moveFolder(tram.id, into: nil)
    #expect(!intoOwnChild && !intoItself && toTop)
    #expect(index.folder(tram.id)?.parentID == nil)
    #expect(index.descendants(of: trips.id).count == 3)  // Trips, Lisbon, lisbon 2
}

@Test func removingAFolderMovesItsContentsUp() throws {
    var index = GalleryIndex()
    let trips = index.addFolder(named: "Trips")
    let lisbon = index.addFolder(named: "Lisbon", in: trips.id)
    let tram = index.addFolder(named: "Trams", in: lisbon.id)
    let picture = try item("a tram", folder: lisbon.id)
    index.insert([picture])
    index.removeFolder(lisbon.id)
    #expect(index.folder(tram.id)?.parentID == trips.id)
    #expect(index.items[0].folderID == trips.id)
}

@Test func tagsAreAddedRemovedAndCountedIgnoringCase() throws {
    var index = GalleryIndex()
    let a = try item("a fox")
    let b = try item("a cat")
    index.insert([a, b])
    index.addTag("  #Animals ", to: [a.id, b.id])
    index.addTag("animals", to: [a.id])  // already there, in another case
    index.addTag("Night", to: [b.id])
    #expect(index.items.first { $0.id == a.id }?.tagList == ["Animals"])
    #expect(index.allTags.map(\.tag) == ["Animals", "Night"])
    #expect(index.allTags.map(\.count) == [2, 1])
    #expect(index.items(.tag("animals")).count == 2)
    #expect(index.normalized(tag: "  ") == nil)

    index.renameTag("Night", to: "animals")  // merges
    #expect(index.allTags.map(\.tag) == ["Animals"])
    #expect(index.allTags[0].count == 2)
    index.removeTag("ANIMALS")
    #expect(index.allTags.isEmpty)
    #expect(index.items.allSatisfy { $0.tags == nil })
}

@Test func searchFindsEveryWordInPromptModelSeedAndTags() throws {
    let fox = try item("A red fox in the snow, Café light", tags: ["Winter", "animals"])
    #expect(fox.matches("fox snow"))
    #expect(fox.matches("cafe"))  // accents don't matter
    #expect(fox.matches("photoreal"))
    #expect(fox.matches("Photo XL"))
    #expect(fox.matches("4242"))
    #expect(fox.matches("#winter"))
    #expect(!fox.matches("#red"))  // only in the prompt, not a tag
    #expect(!fox.matches("fox cat"))
    #expect(fox.matches("\"red fox\""))
    #expect(!fox.matches("\"fox red\""))
    #expect(fox.matches("  "))
}

@Test func oldIndexesHaveNoTagsOrParents() throws {
    var index = GalleryIndex()
    index.addFolder(named: "Old")
    index.insert([try item("x")])
    var json = try JSONSerialization.jsonObject(with: JSONEncoder.gallery.encode(index)) as! [String: Any]
    var folders = json["folders"] as! [[String: Any]]
    folders[0]["parentID"] = nil
    json["folders"] = folders
    let old = try JSONDecoder.gallery.decode(GalleryIndex.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.folders[0].parentID == nil && old.items[0].tags == nil)
}

@Test func foldersCanBeSortedByHand() {
    var index = GalleryIndex()
    let trips = index.addFolder(named: "Trips")
    let art = index.addFolder(named: "Art")
    let cats = index.addFolder(named: "Cats")
    #expect(index.children(of: nil).map(\.name) == ["Art", "Cats", "Trips"])  // by name at first
    let placed1 = index.placeFolder(trips.id, next: art.id, after: false)
    #expect(placed1)
    #expect(index.children(of: nil).map(\.name) == ["Trips", "Art", "Cats"])
    let placed2 = index.placeFolder(trips.id, next: cats.id, after: true)
    #expect(placed2)
    #expect(index.children(of: nil).map(\.name) == ["Art", "Cats", "Trips"])
    // Where it already is: nothing changes.
    let placed3 = index.placeFolder(trips.id, next: cats.id, after: true)
    #expect(!placed3)
    // A new folder goes after the sorted ones.
    _ = index.addFolder(named: "Animals")
    #expect(index.children(of: nil).map(\.name) == ["Art", "Cats", "Trips", "Animals"])

    // Next to a folder inside another: moved in there.
    let lisbon = index.addFolder(named: "Lisbon", in: trips.id)
    let placed4 = index.placeFolder(cats.id, next: lisbon.id, after: true)
    #expect(placed4)
    #expect(index.children(of: trips.id).map(\.name) == ["Lisbon", "Cats"])
    // Never into itself.
    let placed5 = index.placeFolder(trips.id, next: lisbon.id, after: false)
    #expect(!placed5)
    let placed6 = index.placeFolder(trips.id, next: trips.id, after: false)
    #expect(!placed6)
}

@Test func picturesGroupByFolderInSidebarOrder() throws {
    var index = GalleryIndex()
    let trips = index.addFolder(named: "Trips")
    let lisbon = index.addFolder(named: "Lisbon", in: trips.id)
    let art = index.addFolder(named: "Art")
    _ = index.addFolder(named: "Empty")
    let pictures = [
        try item("a tram", folder: lisbon.id), try item("loose"), try item("a sketch", folder: art.id),
        try item("a beach", folder: trips.id), try item("a bridge", folder: lisbon.id),
    ]
    let groups = index.grouped(pictures)
    #expect(groups.map { $0.folder?.name } == [nil, "Art", "Trips", "Lisbon"])
    #expect(groups.last?.items.map(\.id) == [pictures[0].id, pictures[4].id])
}

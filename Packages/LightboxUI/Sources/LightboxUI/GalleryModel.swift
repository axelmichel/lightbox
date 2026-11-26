import CoreGraphics
import Foundation
import ImageIO
import LightboxCore
import Observation

/// Opens the full view at one picture.
public struct ViewerRequest: Identifiable, Equatable {
    public let id = UUID()
    public var itemID: UUID
}

/// The gallery: folders, pictures and what is selected.
@MainActor @Observable
public final class GalleryModel {
    public private(set) var index = GalleryIndex()
    public var filter: GalleryFilter = .all {
        didSet { if filter != oldValue { selection = [] } }
    }
    public var selection: Set<UUID> = []
    public var viewer: ViewerRequest?
    /// The search field's text; empty = no search.
    public var search = ""
    /// Search all pictures instead of only those of the folder or tag shown.
    public var searchEverywhere = false
    /// The last problem reading or writing the gallery.
    public var problem: String?
    /// Pictures whose background is being removed (or cut again).
    public private(set) var cutting: Set<UUID> = []

    public let store: GalleryStore
    @ObservationIgnored private var thumbnails: [UUID: CGImage] = [:]
    /// The index on disk could not be read. Changes then stay in memory, so
    /// the file isn't replaced by a nearly empty one.
    @ObservationIgnored private var readable = true

    init(store: GalleryStore) {
        self.store = store
        do {
            index = try store.load()
        } catch {
            readable = false
            let copy = store.setAsideUnreadableIndex()
            problem =
                "Could not read the gallery: \(AppModel.describe(error)) Nothing is saved to it until it can be read"
                + (copy.map { "; a copy of the list is at \($0.path(percentEncoded: false))." } ?? ".")
        }
    }

    /// Put back pictures whose files are there but which the index doesn't
    /// list, in a folder “Recovered”. Their settings come from the prompt
    /// ComfyUI stored in each picture; a preset with the same checkpoint is
    /// linked by name.
    func recoverOrphans(rating: ContentRating, presets: [GenerationPreset]) {
        guard readable else { return }
        let orphans = store.orphans(of: index)
        guard !orphans.isEmpty else { return }
        let folder =
            index.folders.first { $0.name == Self.recoveredFolder } ?? GalleryFolder(name: Self.recoveredFolder)
        var items = orphans.compactMap { store.recover($0.id, date: $0.date, folderID: folder.id, rating: rating) }
        for i in items.indices {
            if let p = presets.first(where: { $0.checkpoint == items[i].recipe.preset.checkpoint }) {
                items[i].recipe.preset.id = p.id
                items[i].recipe.preset.name = p.name
            }
        }
        guard !items.isEmpty else { return }
        change { index in
            if !index.folders.contains(where: { $0.id == folder.id }) { index.folders.append(folder) }
            // Newest first; a stable sort keeps cut-outs before their originals.
            let all = index.items + items
            index.items = all.enumerated().sorted { a, b in
                a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset
            }
            .map(\.element)
        }
        problem =
            (items.count == 1 ? "A picture had" : "\(items.count) pictures had")
            + " dropped out of the gallery's list and were put back, in the folder “\(Self.recoveredFolder)”. "
            + "Their settings come from the prompt ComfyUI stored in each picture; the folders they were in are lost."
    }

    static let recoveredFolder = "Recovered"

    public var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The pictures shown, newest first: those of the folder or tag, or
    /// with a search those that match it.
    public var items: [GalleryItem] {
        guard isSearching else { return index.items(filter) }
        return (searchEverywhere ? index.items : index.items(filter)).filter { $0.matches(search) }
    }

    public func item(_ id: UUID) -> GalleryItem? { index.items.first { $0.id == id } }

    public var title: String {
        switch filter {
        case .all: "All Pictures"
        case .unfiled: "Not in a Folder"
        case .folder(let id): index.folder(id)?.name ?? "Folder"
        case .tag(let tag): "#\(tag)"
        }
    }

    /// Where new pictures go: the folder shown, or none.
    public var targetFolder: GalleryFolder? { index.folder(filter.folderID) }

    // MARK: - Changes

    /// Store new pictures in the folder that is shown, with the guide
    /// pictures their recipes use.
    func add(
        _ pictures: [(png: Data, recipe: GenerationRecipe)], guides: [String: Data] = [:], workflow: WorkflowRun? = nil
    ) {
        var new: [GalleryItem] = []
        for p in pictures {
            do {
                new.append(
                    try store.write(
                        png: p.png, recipe: p.recipe, folderID: filter.folderID, guides: guides, workflow: workflow))
            } catch {
                problem = "Could not save a picture: \(AppModel.describe(error))"
            }
        }
        // Newest first, in batch order.
        change { $0.insert(new) }
    }

    /// A new folder in `parentID` (`nil` = at the top).
    @discardableResult
    public func addFolder(named name: String, in parentID: UUID? = nil) -> GalleryFolder {
        var folder: GalleryFolder?
        change { folder = $0.addFolder(named: name, in: parentID) }
        return folder!
    }

    /// Put a folder into another one (`nil` = at the top); refused into itself.
    @discardableResult
    public func moveFolder(_ id: UUID, into parentID: UUID?) -> Bool {
        var moved = false
        change { moved = $0.moveFolder(id, into: parentID) }
        return moved
    }

    /// Put a folder before or after another, in that one's folder.
    @discardableResult
    public func placeFolder(_ id: UUID, next target: UUID, after: Bool) -> Bool {
        var placed = false
        change { placed = $0.placeFolder(id, next: target, after: after) }
        return placed
    }

    // MARK: - Tags

    public func addTag(_ tag: String, to ids: Set<UUID>) {
        change { $0.addTag(tag, to: ids) }
    }

    public func removeTag(_ tag: String, from ids: Set<UUID>) {
        change { $0.removeTag(tag, from: ids) }
    }

    public func renameTag(_ tag: String, to name: String) {
        guard let new = index.normalized(tag: name) else { return }
        change { $0.renameTag(tag, to: new) }
        if case .tag(let shown) = filter, shown.localizedCaseInsensitiveCompare(tag) == .orderedSame {
            filter = .tag(new)
        }
    }

    /// Take a tag off every picture; the pictures stay.
    public func deleteTag(_ tag: String) {
        if case .tag(let shown) = filter, shown.localizedCaseInsensitiveCompare(tag) == .orderedSame {
            filter = .all
        }
        change { $0.removeTag(tag) }
    }

    public func renameFolder(_ id: UUID, to name: String) {
        change { $0.renameFolder(id, to: name) }
    }

    /// Its pictures and folders move up into the folder it was in.
    public func removeFolder(_ id: UUID) {
        if filter == .folder(id) { filter = index.folder(id)?.parentID.map(GalleryFilter.folder) ?? .all }
        change { $0.removeFolder(id) }
    }

    public func move(_ ids: Set<UUID>, to folderID: UUID?) {
        change { $0.move(ids, to: folderID) }
    }

    public func delete(_ ids: Set<UUID>) {
        var unused: Set<String> = []
        let runs = index.workflowRunNames
        change { unused = $0.remove(ids) }
        selection.subtract(ids)
        for id in ids { thumbnails[id] = nil }
        store.deleteFiles(ids, guides: unused, workflowRuns: runs.subtracting(index.workflowRunNames))
    }

    // MARK: - Cut-outs

    /// Add a copy of a picture without its background, right before it, in
    /// the same folder. Returns the cut-out's ID.
    @discardableResult
    public func removeBackground(of id: UUID) async -> UUID? {
        guard let item = item(id), !item.isCutOut, !cutting.contains(id), let png = pngData(id) else { return nil }
        cutting.insert(id)
        defer { cutting.remove(id) }
        do {
            let edge = BackgroundRemoval.lastEdge
            let cut = try await BackgroundRemoval.cutOut(png, edge: edge)
            let new = try store.write(
                png: cut, recipe: item.recipe, folderID: item.folderID, source: id, edge: edge)
            change { $0.insert(new, before: id) }
            return new.id
        } catch {
            problem = "Can't remove the background: \(AppModel.describe(error))"
            return nil
        }
    }

    /// Cut a cut-out again from its original, with another edge strength.
    public func changeEdge(of id: UUID, to edge: Double) async {
        guard let item = item(id), let source = item.source, !cutting.contains(id), let png = pngData(source) else {
            return
        }
        cutting.insert(id)
        defer { cutting.remove(id) }
        do {
            let cut = try await BackgroundRemoval.cutOut(png, edge: edge)
            BackgroundRemoval.lastEdge = edge
            try store.writeImage(cut, for: id)
            thumbnails[id] = nil
            change { index in
                if let i = index.items.firstIndex(where: { $0.id == id }) { index.items[i].edge = edge }
            }
        } catch {
            problem = "Can't cut the picture again: \(AppModel.describe(error))"
        }
    }

    // MARK: - Compositions

    /// Store a flattened composition as a new picture, in the folder shown.
    /// Returns its ID.
    func saveComposition(_ png: Data, recipe: GenerationRecipe, composition: UUID) -> UUID? {
        do {
            let new = try store.write(png: png, recipe: recipe, folderID: filter.folderID, composition: composition)
            change { $0.insert([new]) }
            return new.id
        } catch {
            problem = "Could not save the picture: \(AppModel.describe(error))"
            return nil
        }
    }

    /// The guide pictures of a picture's recipe, by file name.
    public func guideImages(of id: UUID) -> [String: Data] {
        item(id).map { store.guideImages(of: $0.recipe) } ?? [:]
    }

    private func change(_ edit: (inout GalleryIndex) -> Void) {
        edit(&index)
        guard readable else { return }
        do {
            try store.save(index)
        } catch {
            problem = "Could not save the gallery: \(AppModel.describe(error))"
        }
    }

    // MARK: - Selection

    /// The pictures an action on `id` applies to: the selection if `id` is
    /// in it, else just `id`.
    public func targets(for id: UUID) -> Set<UUID> {
        selection.contains(id) ? selection : [id]
    }

    public func open(_ id: UUID) {
        viewer = ViewerRequest(itemID: id)
    }

    // MARK: - Images

    public func cachedThumbnail(_ id: UUID) -> CGImage? { thumbnails[id] }

    public func thumbnail(_ id: UUID) async -> CGImage? {
        if let cached = thumbnails[id] { return cached }
        let store = store
        let data = await Task.detached(priority: .userInitiated) { store.thumbnail(id) }.value
        guard let data, let image = decode(data) else { return nil }
        thumbnails[id] = image
        return image
    }

    /// The full picture and its PNG data.
    public func picture(_ id: UUID) async -> (image: CGImage, png: Data)? {
        let url = store.imageURL(id)
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data, let image = decode(data) else { return nil }
        return (image, data)
    }

    public func pngData(_ id: UUID) -> Data? {
        try? Data(contentsOf: store.imageURL(id))
    }
}

func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

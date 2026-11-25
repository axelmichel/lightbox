// The gallery on disk (see docs/GALLERY_FORMAT.md):
//
//   Gallery/
//     index.json          folders and pictures, with each picture's recipe
//     images/<id>.png     the picture as ComfyUI made it
//     thumbs/<id>.jpg     a small copy for the grid
//     guides/<name>       guide pictures the recipes refer to, shared
//     workflow-runs/<name> the node-editor workflow pictures were made with, shared
//     workflows/          the node editor's workflows (see `WorkflowStore`)
//
// Folders are a property of each picture, so moving a picture only changes
// the index.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public struct GalleryFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    /// The folder it is in; `nil` = at the top.
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, created: Date = Date(), parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.parentID = parentID
    }
}

public struct GalleryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// `nil` = not in a folder.
    public var folderID: UUID?
    public var date: Date
    public var width: Int
    public var height: Int
    public var recipe: GenerationRecipe
    /// For a cut-out: the picture it was cut from, and how tightly (0…1).
    public var source: UUID?
    public var edge: Double?
    /// For a flattened composition: the composition, to edit it again.
    public var composition: UUID?
    /// Words to find and group pictures by; `nil` in older indexes.
    public var tags: [String]?
    /// Made by a workflow in the node editor: the workflow, to open it
    /// again. `recipe` then holds what could be read from it.
    public var workflow: WorkflowRun?

    public var tagList: [String] { tags ?? [] }

    public var isCutOut: Bool { edge != nil }

    public init(
        id: UUID = UUID(), folderID: UUID? = nil, date: Date = Date(), width: Int, height: Int,
        recipe: GenerationRecipe, source: UUID? = nil, edge: Double? = nil, composition: UUID? = nil,
        workflow: WorkflowRun? = nil
    ) {
        self.id = id
        self.workflow = workflow
        self.folderID = folderID
        self.date = date
        self.width = width
        self.height = height
        self.recipe = recipe
        self.source = source
        self.edge = edge
        self.composition = composition
    }
}

/// Which pictures the grid shows.
public enum GalleryFilter: Hashable, Sendable {
    case all
    /// Pictures in no folder.
    case unfiled
    case folder(UUID)
    /// Pictures with this tag, wherever they are.
    case tag(String)

    /// The folder new pictures go to while this is shown.
    public var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

public struct GalleryIndex: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = currentVersion
    public var folders: [GalleryFolder] = []
    /// Newest first.
    public var items: [GalleryItem] = []

    public init() {}

    public func items(_ filter: GalleryFilter) -> [GalleryItem] {
        switch filter {
        case .all: items
        case .unfiled: items.filter { $0.folderID == nil }
        case .folder(let id): items.filter { $0.folderID == id }
        case .tag(let tag): items.filter { $0.has(tag: tag) }
        }
    }

    public func count(_ filter: GalleryFilter) -> Int { items(filter).count }

    public func folder(_ id: UUID?) -> GalleryFolder? {
        id.flatMap { id in folders.first { $0.id == id } }
    }

    /// A new folder in `parentID` (`nil` = at the top); "Folder 2" and so on
    /// when a folder next to it has the name.
    @discardableResult
    public mutating func addFolder(named name: String, in parentID: UUID? = nil) -> GalleryFolder {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Folder" : name
        let parent = folder(parentID)?.id
        var unique = base
        var n = 2
        while folders.contains(where: {
            $0.parentID == parent && $0.name.localizedCaseInsensitiveCompare(unique) == .orderedSame
        }) {
            unique = "\(base) \(n)"
            n += 1
        }
        let folder = GalleryFolder(name: unique, parentID: parent)
        folders.append(folder)
        return folder
    }

    public mutating func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = trimmed
    }

    /// Remove a folder; its pictures and folders move up into the folder
    /// it was in (or to the top).
    public mutating func removeFolder(_ id: UUID) {
        let parent = folder(id)?.parentID
        folders.removeAll { $0.id == id }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = parent }
        for i in items.indices where items[i].folderID == id { items[i].folderID = parent }
    }

    public mutating func move(_ ids: Set<UUID>, to folderID: UUID?) {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        for i in items.indices where ids.contains(items[i].id) { items[i].folderID = folderID }
    }

    /// Insert at the front (newest first).
    public mutating func insert(_ new: [GalleryItem]) {
        items.insert(contentsOf: new, at: 0)
    }

    /// Insert right before the picture `id` (a cut-out next to its original).
    public mutating func insert(_ new: GalleryItem, before id: UUID) {
        items.insert(new, at: items.firstIndex { $0.id == id } ?? 0)
    }

    /// Remove pictures; returns the guide pictures no remaining recipe uses.
    @discardableResult
    public mutating func remove(_ ids: Set<UUID>) -> Set<String> {
        let before = guideNames
        items.removeAll { ids.contains($0.id) }
        return before.subtracting(guideNames)
    }

    /// Guide pictures used by any recipe.
    public var guideNames: Set<String> {
        Set(items.flatMap { $0.recipe.guides.map(\.image) })
    }

    /// Workflow files (in `workflow-runs/`) used by any picture.
    public var workflowRunNames: Set<String> {
        Set(items.compactMap { $0.workflow?.file })
    }
}

/// The node-editor workflow a picture was made with.
public struct WorkflowRun: Codable, Hashable, Sendable {
    /// The workflow in the library it was run from; `nil` if it is gone or was never saved.
    public var workflowID: UUID?
    public var name: String
    /// The file in `workflow-runs/`: the workflow as run (UI format) and the prompt sent (API format).
    public var file: String
    /// The output node the picture came from (API id).
    public var node: String
    public var server: String?

    public init(workflowID: UUID?, name: String, file: String, node: String, server: String? = nil) {
        self.workflowID = workflowID
        self.name = name
        self.file = file
        self.node = node
        self.server = server
    }
}

public enum GalleryError: Error, CustomStringConvertible {
    case notAnImage
    case newerFormat(Int)

    public var description: String {
        switch self {
        case .notAnImage: "The picture could not be read."
        case .newerFormat(let v): "The gallery was written by a newer version of Lightbox (format \(v))."
        }
    }
}

/// Reads and writes the gallery folder.
public struct GalleryStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var indexURL: URL { root.appending(path: "index.json") }

    public func imageURL(_ id: UUID) -> URL { root.appending(path: "images/\(id.uuidString).png") }
    public func thumbnailURL(_ id: UUID) -> URL { root.appending(path: "thumbs/\(id.uuidString).jpg") }
    /// Only the last path component of `name` is used.
    public func guideURL(_ name: String) -> URL {
        root.appending(path: "guides").appending(path: (name as NSString).lastPathComponent)
    }

    /// An empty index when there is no gallery yet.
    public func load() throws -> GalleryIndex {
        // `path()` is percent-encoded ("Application%20Support"), so it must
        // not be used to look for files.
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
            return GalleryIndex()
        }
        let index = try JSONDecoder.gallery.decode(GalleryIndex.self, from: Data(contentsOf: indexURL))
        if index.version > GalleryIndex.currentVersion { throw GalleryError.newerFormat(index.version) }
        return index
    }

    public func workflowRunURL(_ name: String) -> URL {
        root.appending(path: "workflow-runs").appending(path: (name as NSString).lastPathComponent)
    }

    /// Store a run's workflow and prompt (`{"workflow": …, "prompt": …}`);
    /// the name is made from the content, so the pictures of one run share it.
    public func writeWorkflowRun(_ data: Data) throws -> String {
        let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined() + ".json"
        let url = workflowRunURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try data.write(to: url, options: .atomic)
        }
        return name
    }

    public func workflowRun(_ name: String) -> Data? {
        try? Data(contentsOf: workflowRunURL(name))
    }

    public func save(_ index: GalleryIndex) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.gallery.encode(index).write(to: indexURL, options: .atomic)
    }

    /// Write a picture, its thumbnail and the guide pictures its recipe
    /// uses (by file name); the caller adds the returned item to the index.
    public func write(
        png: Data, recipe: GenerationRecipe, folderID: UUID?, guides: [String: Data] = [:], source: UUID? = nil,
        edge: Double? = nil, composition: UUID? = nil, workflow: WorkflowRun? = nil, date: Date = Date()
    ) throws -> GalleryItem {
        guard let size = Self.pixelSize(png) else { throw GalleryError.notAnImage }
        let item = GalleryItem(
            folderID: folderID, date: date, width: size.width, height: size.height, recipe: recipe, source: source,
            edge: edge, composition: composition, workflow: workflow)
        try writeImage(png, for: item.id)
        let fm = FileManager.default
        for use in recipe.guides {
            let url = guideURL(use.image)
            guard let data = guides[use.image], !fm.fileExists(atPath: url.path(percentEncoded: false)) else {
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return item
    }

    /// Write (or replace) a picture and its thumbnail.
    public func writeImage(_ png: Data, for id: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: imageURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbnailURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: imageURL(id), options: .atomic)
        if let thumb = Self.thumbnail(png) { try thumb.write(to: thumbnailURL(id), options: .atomic) }
    }

    /// Delete the files of pictures already taken out of the index, and the
    /// guide pictures and workflow runs no picture uses any more.
    public func deleteFiles(
        _ ids: some Sequence<UUID>, guides: some Sequence<String> = [], workflowRuns: some Sequence<String> = []
    ) {
        for id in ids {
            try? FileManager.default.removeItem(at: imageURL(id))
            try? FileManager.default.removeItem(at: thumbnailURL(id))
        }
        for name in guides { try? FileManager.default.removeItem(at: guideURL(name)) }
        for name in workflowRuns { try? FileManager.default.removeItem(at: workflowRunURL(name)) }
    }

    /// The guide pictures a recipe uses, by file name; missing ones are left out.
    public func guideImages(of recipe: GenerationRecipe) -> [String: Data] {
        var images: [String: Data] = [:]
        for use in recipe.guides {
            if let data = try? Data(contentsOf: guideURL(use.image)) { images[use.image] = data }
        }
        return images
    }

    /// Keep a copy of an index that could not be read, before anything
    /// can write over it. Returns where it went.
    @discardableResult
    public func setAsideUnreadableIndex(date: Date = Date()) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let copy = root.appending(path: "index-unreadable-\(stamp).json")
        return (try? FileManager.default.copyItem(at: indexURL, to: copy)) != nil ? copy : nil
    }

    // MARK: - Recovery

    /// Pictures in `images/` that the index doesn't list, oldest first.
    public func orphans(of index: GalleryIndex) -> [(id: UUID, date: Date)] {
        let folder = root.appending(path: "images")
        let known = Set(index.items.map(\.id))
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? []
        return files.compactMap { url -> (UUID, Date)? in
            guard url.pathExtension == "png", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                !known.contains(id)
            else { return nil }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return (id, values?.creationDate ?? values?.contentModificationDate ?? Date())
        }
        .sorted { $0.1 < $1.1 }
    }

    /// An index entry for a picture that lost its own, rebuilt from the
    /// ComfyUI prompt stored in the PNG: checkpoint, LoRAs, sampling, size,
    /// seed and the prompt as sent. The folder, the guides and the prompt
    /// as typed are lost.
    public func recover(_ id: UUID, date: Date, folderID: UUID?, rating: ContentRating) -> GalleryItem? {
        guard let png = try? Data(contentsOf: imageURL(id)), let size = Self.pixelSize(png) else { return nil }
        let recipe = Self.recipe(
            fromPrompt: Self.pngText(png)["prompt"].map { Data($0.utf8) }, name: "Recovered", width: size.width,
            height: size.height, rating: rating)
        return GalleryItem(
            id: id, folderID: folderID, date: date, width: size.width, height: size.height, recipe: recipe)
    }

    /// A recipe read from a ComfyUI prompt (API format): checkpoint, LoRAs,
    /// sampling, seed and prompts as far as `WorkflowImport` finds them.
    /// `sent` replaces the prompts it found (a node-editor run knows them).
    public static func recipe(
        fromPrompt prompt: Data?, name: String, width: Int, height: Int, rating: ContentRating,
        sent known: ComposedPrompt? = nil
    ) -> GenerationRecipe {
        var preset = GenerationPreset(name: name, negativePrompt: "")
        var text = ""
        var seed = 0
        if let prompt, let found = try? WorkflowImport.read(prompt, name: name) {
            preset = found.preset
            preset.name = name
            preset.detectionNotes = []
            text = found.prompt
            seed = found.seed ?? 0
        }
        (preset.width, preset.height) = (width, height)
        if let known {
            text = known.positive
            preset.negativePrompt = known.negative
        }
        let input = PromptInput(preset: preset, prompt: text, rating: rating)
        var sent = ComposedPrompt(
            positive: text, negative: preset.negativePrompt,
            loras: preset.loras.map { LoraUse(name: $0.name, weight: $0.strength, clipWeight: $0.clipStrength) })
        sent.minorSignal = known?.minorSignal
        return GenerationRecipe(input: input, sent: sent, seed: seed, finish: FinishSettings())
    }

    /// A PNG's text chunks (`tEXt`), where ComfyUI keeps the prompt graph.
    public static func pngText(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0..<8].elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else { return [:] }
        var out: [String: String] = [:]
        var i = 8
        while i + 12 <= bytes.count {
            let length = bytes[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[i + 4..<i + 8], as: UTF8.self)
            let start = i + 8
            guard length >= 0, start + length <= bytes.count else { break }
            if type == "tEXt", let zero = bytes[start..<start + length].firstIndex(of: 0) {
                let key = String(decoding: bytes[start..<zero], as: UTF8.self)
                out[key] = String(decoding: bytes[(zero + 1)..<(start + length)], as: UTF8.self)
            }
            if type == "IEND" { break }
            i = start + length + 4
        }
        return out
    }

    /// The thumbnail, made again from the picture if it is missing.
    public func thumbnail(_ id: UUID) -> Data? {
        if let data = try? Data(contentsOf: thumbnailURL(id)) { return data }
        guard let png = try? Data(contentsOf: imageURL(id)), let thumb = Self.thumbnail(png) else { return nil }
        try? thumb.write(to: thumbnailURL(id), options: .atomic)
        return thumb
    }

    /// A JPEG whose longer side is `maxPixels`.
    public static func thumbnail(_ image: Data, maxPixels: Int = 512) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    public static func pixelSize(_ image: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}

extension JSONEncoder {
    static var gallery: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var gallery: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

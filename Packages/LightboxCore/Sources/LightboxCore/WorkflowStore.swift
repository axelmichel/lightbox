// The node editor's workflows, in the gallery folder:
//
//   workflows/
//     index.json      names and dates
//     <id>.json       the workflow, as ComfyUI saves it (UI format)
//
// The files are plain ComfyUI workflows, so they can be copied out and
// opened in ComfyUI as they are. Lightbox doesn't read them here; the editor
// does (ComfyKit's `WorkflowDocument`).

import Foundation

public struct WorkflowEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var modified: Date
    /// The preset the workflow belongs to; `nil` for workflows without one
    /// (kept when their preset was deleted, or saved before presets had them).
    public var presetID: UUID?

    public init(
        id: UUID = UUID(), name: String, created: Date = Date(), modified: Date = Date(), presetID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.created = created
        self.modified = modified
        self.presetID = presetID
    }
}

struct WorkflowIndex: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var workflows: [WorkflowEntry] = []
}

public struct WorkflowStore: Sendable {
    /// The gallery folder.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    var folder: URL { root.appending(path: "workflows") }
    var indexURL: URL { folder.appending(path: "index.json") }
    public func fileURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).json") }

    /// Workflows whose file is there, last changed first.
    public func list() throws -> [WorkflowEntry] {
        try index().workflows
            .filter { FileManager.default.fileExists(atPath: fileURL($0.id).path(percentEncoded: false)) }
            .sorted { $0.modified > $1.modified }
    }

    public func load(_ id: UUID) throws -> Data {
        try Data(contentsOf: fileURL(id))
    }

    /// Write the workflow file and its entry (the entry's `modified` is set).
    @discardableResult
    public func save(_ entry: WorkflowEntry, data: Data, date: Date = Date()) throws -> WorkflowEntry {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: fileURL(entry.id), options: .atomic)
        var e = entry
        e.modified = date
        try update { index in
            index.workflows.removeAll { $0.id == e.id }
            index.workflows.append(e)
        }
        return e
    }

    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update { index in
            if let i = index.workflows.firstIndex(where: { $0.id == id }) { index.workflows[i].name = trimmed }
        }
    }

    public func delete(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: fileURL(id))
        try update { $0.workflows.removeAll { $0.id == id } }
    }

    /// The preset is deleted: delete its workflows too, or keep them
    /// without a preset.
    public func presetDeleted(_ presetID: UUID, keepWorkflows: Bool) throws {
        let ids = try index().workflows.filter { $0.presetID == presetID }.map(\.id)
        guard !ids.isEmpty else { return }
        if keepWorkflows {
            try update { index in
                for i in index.workflows.indices where index.workflows[i].presetID == presetID {
                    index.workflows[i].presetID = nil
                }
            }
        } else {
            for id in ids { try delete(id) }
        }
    }

    /// "Workflow", "Workflow 2", … not used yet.
    public func uniqueName(_ base: String) -> String {
        let names = Set(((try? list()) ?? []).map { $0.name.lowercased() })
        var name = base
        var n = 2
        while names.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    func index() throws -> WorkflowIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) else {
            return WorkflowIndex()
        }
        let index = try JSONDecoder.gallery.decode(WorkflowIndex.self, from: Data(contentsOf: indexURL))
        if index.version > WorkflowIndex.currentVersion { throw GalleryError.newerFormat(index.version) }
        return index
    }

    private func update(_ edit: (inout WorkflowIndex) -> Void) throws {
        var i = try index()
        edit(&i)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.gallery.encode(i).write(to: indexURL, options: .atomic)
    }
}

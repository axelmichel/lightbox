import LightboxCore
import SwiftUI

/// What the sidebar shows in the main area.
private enum SidebarItem: Hashable {
    case pictures(GalleryFilter)
    case composition(UUID)
    case workflow(UUID)
}

/// All pictures, those in no folder, the folders (inside each other), the
/// tags and the compositions. Drop pictures on a folder to move them there,
/// on a tag to tag them; drop a folder on another to put it inside.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var renaming: GalleryFolder?
    @State private var newName = ""
    @State private var removing: GalleryFolder?
    @State private var renamingComposition: Composition?
    @State private var removingComposition: Composition?
    @State private var renamingWorkflow: WorkflowEntry?
    @State private var removingWorkflow: WorkflowEntry?
    @State private var importingWorkflow = false
    @State private var exportingWorkflow: NodeEditorView.ExportFile?
    @State private var renamingTag: String?
    @State private var removingTag: String?

    var body: some View {
        let gallery = app.gallery
        let index = gallery.index
        let compositions = app.compositions
        let workflows = app.workflows
        List(selection: selection) {
            Section {
                row("All Pictures", "photo.on.rectangle.angled", .all, count: index.count(.all))
                row("Not in a Folder", "tray", .unfiled, count: index.count(.unfiled))
            }
            Section("Folders") {
                OutlineGroup(FolderNode.tree(index), children: \.children) { node in
                    folderRow(node.folder)
                }
            }
            if !index.allTags.isEmpty {
                Section("Tags") {
                    ForEach(index.allTags, id: \.tag) { entry in
                        row("#\(entry.tag)", "tag", .tag(entry.tag), count: entry.count)
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") {
                                    newName = entry.tag
                                    renamingTag = entry.tag
                                }
                                Button("Delete Tag…", systemImage: "trash", role: .destructive) {
                                    removingTag = entry.tag
                                }
                            }
                    }
                }
            }
            Section("Compositions") {
                ForEach(compositions.list) { c in
                    Label(c.name, systemImage: "square.3.layers.3d")
                        .lineLimit(1)
                        .tag(SidebarItem.composition(c.id))
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                newName = c.name
                                renamingComposition = c
                            }
                            Button("Delete Composition…", systemImage: "trash", role: .destructive) {
                                removingComposition = c
                            }
                        }
                }
            }
            Section("Workflows") {
                ForEach(workflows.list) { w in
                    Label(w.name, systemImage: "point.3.connected.trianglepath.dotted")
                        .lineLimit(1)
                        .tag(SidebarItem.workflow(w.id))
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                newName = w.name
                                renamingWorkflow = w
                            }
                            Button("Duplicate", systemImage: "plus.square.on.square") { workflows.duplicate(w.id) }
                            Button("Export…", systemImage: "square.and.arrow.up") {
                                if let data = workflows.data(of: w.id) {
                                    exportingWorkflow = .init(document: JSONFile(data: data), name: "\(w.name).json")
                                }
                            }
                            Button("Delete Workflow…", systemImage: "trash", role: .destructive) {
                                removingWorkflow = w
                            }
                        }
                }
            }
        }
        .navigationTitle("Lightbox")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("New Folder", systemImage: "folder.badge.plus") {
                    // Inside the folder shown, if one is.
                    let folder = gallery.addFolder(named: "New Folder", in: gallery.filter.folderID)
                    gallery.filter = .folder(folder.id)
                    newName = folder.name
                    renaming = folder
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("New Composition", systemImage: "square.3.layers.3d.badge.plus") { compositions.create() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("A new composition; add gallery pictures to it as layers")
                Menu("New Workflow", systemImage: "point.3.connected.trianglepath.dotted") {
                    Button("New Workflow", systemImage: "plus") { workflows.create() }
                    Button("Import ComfyUI Workflow…", systemImage: "square.and.arrow.down") {
                        importingWorkflow = true
                    }
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("A workflow for the node editor: new, or a ComfyUI file (also a picture made by ComfyUI)")
            }
            .padding(10)
        }
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { gallery.renameFolder(renaming.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete the folder “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let removing { gallery.removeFolder(removing.id) }
                removing = nil
            }
        } message: {
            let parent = gallery.index.folder(removing?.parentID)?.name
            Text(
                "Its pictures and folders are kept; they move to "
                    + (parent.map { "“\($0)”." } ?? "the top (pictures to “Not in a Folder”)."))
        }
        .alert(
            "Rename Tag", isPresented: Binding(get: { renamingTag != nil }, set: { if !$0 { renamingTag = nil } })
        ) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renamingTag { gallery.renameTag(renamingTag, to: newName) }
                renamingTag = nil
            }
            Button("Cancel", role: .cancel) { renamingTag = nil }
        } message: {
            Text("Renamed on every picture; a name already used merges the two tags.")
        }
        .confirmationDialog(
            "Delete the tag “\(removingTag ?? "")”?",
            isPresented: Binding(get: { removingTag != nil }, set: { if !$0 { removingTag = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Tag", role: .destructive) {
                if let removingTag { gallery.deleteTag(removingTag) }
                removingTag = nil
            }
        } message: {
            Text("It is taken off every picture; the pictures stay.")
        }
        .fileImporter(isPresented: $importingWorkflow, allowedContentTypes: [.json, .png]) { result in
            guard case .success(let url) = result else { return }
            do {
                let data = try readPickedFile(url)
                workflows.importFile(
                    data, name: url.deletingPathExtension().lastPathComponent, catalog: app.catalog)
            } catch {
                workflows.problem = "Could not open the file: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exportingWorkflow != nil }, set: { if !$0 { exportingWorkflow = nil } }),
            document: exportingWorkflow?.document, contentType: .json, defaultFilename: exportingWorkflow?.name
        ) { _ in exportingWorkflow = nil }
        .alert(
            "Workflows",
            isPresented: Binding(get: { workflows.problem != nil }, set: { if !$0 { workflows.problem = nil } })
        ) {
            Button("OK") { workflows.problem = nil }
        } message: {
            Text(workflows.problem ?? "")
        }
        .alert(
            "Rename Workflow",
            isPresented: Binding(get: { renamingWorkflow != nil }, set: { if !$0 { renamingWorkflow = nil } })
        ) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renamingWorkflow { workflows.rename(renamingWorkflow.id, to: newName) }
                renamingWorkflow = nil
            }
            Button("Cancel", role: .cancel) { renamingWorkflow = nil }
        }
        .confirmationDialog(
            "Delete the workflow “\(removingWorkflow?.name ?? "")”?",
            isPresented: Binding(get: { removingWorkflow != nil }, set: { if !$0 { removingWorkflow = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Workflow", role: .destructive) {
                if let removingWorkflow { workflows.delete(removingWorkflow.id) }
                removingWorkflow = nil
            }
        } message: {
            Text("Pictures made with it stay in the gallery, with the workflow as it was run.")
        }
        .alert(
            "Rename Composition",
            isPresented: Binding(get: { renamingComposition != nil }, set: { if !$0 { renamingComposition = nil } })
        ) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renamingComposition { compositions.rename(renamingComposition.id, to: newName) }
                renamingComposition = nil
            }
            Button("Cancel", role: .cancel) { renamingComposition = nil }
        }
        .confirmationDialog(
            "Delete the composition “\(removingComposition?.name ?? "")”?",
            isPresented: Binding(get: { removingComposition != nil }, set: { if !$0 { removingComposition = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Composition", role: .destructive) {
                if let removingComposition { compositions.delete(removingComposition.id) }
                removingComposition = nil
            }
        } message: {
            Text("Its layers are deleted. Pictures saved from it to the gallery are kept.")
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if let editor = app.workflows.editor { return .workflow(editor.entry.id) }
                return app.compositions.document.map { .composition($0.composition.id) }
                    ?? .pictures(app.gallery.filter)
            },
            set: { item in
                switch item {
                case .pictures(let filter):
                    app.compositions.close()
                    app.workflows.close()
                    app.gallery.filter = filter
                case .composition(let id):
                    app.workflows.close()
                    app.compositions.open(id)
                case .workflow(let id):
                    app.compositions.close()
                    app.workflows.open(id)
                case nil:
                    break
                }
            })
    }

    private func row(_ title: String, _ icon: String, _ filter: GalleryFilter, count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(SidebarItem.pictures(filter))
        .dropDestination(for: String.self) { payload, _ in drop(payload, on: filter) }
    }

    private func folderRow(_ folder: GalleryFolder) -> some View {
        let gallery = app.gallery
        return row(folder.name, "folder", .folder(folder.id), count: gallery.index.count(.folder(folder.id)))
            .draggable("folder:\(folder.id.uuidString)")
            .contextMenu {
                Button("New Folder Inside", systemImage: "folder.badge.plus") {
                    let inner = gallery.addFolder(named: "New Folder", in: folder.id)
                    gallery.filter = .folder(inner.id)
                    newName = inner.name
                    renaming = inner
                }
                Button("Rename…", systemImage: "pencil") {
                    newName = folder.name
                    renaming = folder
                }
                if folder.parentID != nil {
                    Button("Move to the Top", systemImage: "arrow.up.to.line") {
                        gallery.moveFolder(folder.id, into: nil)
                    }
                }
                Divider()
                Button("Delete Folder…", systemImage: "trash", role: .destructive) { removing = folder }
            }
    }

    /// Pictures dropped on a folder move there, on a tag get it; a folder
    /// dropped on a folder goes inside it, on All Pictures or Not in a
    /// Folder to the top.
    private func drop(_ payload: [String], on filter: GalleryFilter) -> Bool {
        let gallery = app.gallery
        let lines = payload.flatMap { $0.split(separator: "\n") }.map(String.init)
        let folders = lines.compactMap { $0.hasPrefix("folder:") ? UUID(uuidString: String($0.dropFirst(7))) : nil }
        if !folders.isEmpty {
            switch filter {
            case .all, .unfiled: return folders.map { gallery.moveFolder($0, into: nil) }.contains(true)
            case .folder(let target): return folders.map { gallery.moveFolder($0, into: target) }.contains(true)
            case .tag: return false
            }
        }
        let ids = Set(lines.compactMap { UUID(uuidString: $0) })
        guard !ids.isEmpty else { return false }
        switch filter {
        case .all: return false
        case .tag(let tag): gallery.addTag(tag, to: ids)
        case .unfiled, .folder: gallery.move(ids, to: filter.folderID)
        }
        return true
    }
}

/// A folder with the folders inside it, for the sidebar's tree.
private struct FolderNode: Identifiable {
    let folder: GalleryFolder
    /// `nil` = none (no disclosure arrow).
    let children: [FolderNode]?

    var id: UUID { folder.id }

    static func tree(_ index: GalleryIndex, in parent: UUID? = nil) -> [FolderNode] {
        index.children(of: parent).map { f in
            let inner = tree(index, in: f.id)
            return FolderNode(folder: f, children: inner.isEmpty ? nil : inner)
        }
    }
}

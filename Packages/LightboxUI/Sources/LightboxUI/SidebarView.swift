import LightboxCore
import SwiftUI

/// What the sidebar shows in the main area.
private enum SidebarItem: Hashable {
    case pictures(GalleryFilter)
    case composition(UUID)
}

/// The sidebar's two tabs.
private enum SidebarTab: String {
    case gallery, compositions
}

/// Two tabs. The gallery's: all pictures, those in no folder, the folders
/// (inside each other) and the most used tags, the two groups collapsible.
/// Drop pictures on a folder to move them there, on a tag to tag them; drop
/// a folder on another to put it inside. The other tab lists the compositions.
struct SidebarView: View {
    /// Tags shown before "more".
    static let tagLimit = 10
    @Environment(AppModel.self) private var app
    @State private var renaming: GalleryFolder?
    @State private var newName = ""
    @State private var removing: GalleryFolder?
    @State private var renamingComposition: Composition?
    @State private var removingComposition: Composition?
    @State private var renamingTag: String?
    @State private var removingTag: String?
    @AppStorage(PanelKeys.nodes) private var showNodes = false
    @AppStorage("sidebarTab") private var tab = SidebarTab.gallery
    @AppStorage("sidebarFoldersOpen") private var foldersOpen = true
    @AppStorage("sidebarTagsOpen") private var tagsOpen = true
    @State private var allTagsShown = false
    @State private var creating = false

    var body: some View {
        let gallery = app.gallery
        let index = gallery.index
        let compositions = app.compositions
        List(selection: selection) {
            if tab == .gallery {
                Section {
                    row("All Pictures", "photo.on.rectangle.angled", .all, count: index.count(.all))
                    row("Not in a Folder", "tray", .unfiled, count: index.count(.unfiled))
                }
                Section("Folders", isExpanded: $foldersOpen) {
                    OutlineGroup(FolderNode.tree(index), children: \.children) { node in
                        folderRow(node.folder)
                    }
                }
                tags(index)
            } else {
                compositionRows
            }
        }
        .navigationTitle("Lightbox")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $tab) {
                Label("Gallery", systemImage: "photo.on.rectangle.angled").tag(SidebarTab.gallery)
                Label("Compositions", systemImage: "square.3.layers.3d").tag(SidebarTab.compositions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onChange(of: tab) { _, now in
            // The gallery tab shows the gallery again.
            if now == .gallery { app.compositions.close() }
        }
        .onChange(of: compositions.document?.composition.id) { _, open in
            // Opened from the gallery (Edit in Composition): its tab.
            if open != nil { tab = .compositions }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if tab == .gallery {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        // Inside the folder shown, if one is; renamed from its menu.
                        let folder = gallery.addFolder(named: "New Folder", in: gallery.filter.folderID)
                        gallery.filter = .folder(folder.id)
                    }
                } else {
                    Button("New Composition", systemImage: "square.3.layers.3d.badge.plus") { creating = true }
                        .help("A blank canvas, or gallery pictures as layers")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .sheet(isPresented: $creating) { NewCompositionView() }
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

    /// The most used tags; "more" shows the rest. The tag shown stays in view.
    @ViewBuilder private func tags(_ index: GalleryIndex) -> some View {
        let all = index.topTags(.max)
        if !all.isEmpty {
            let shown: String? = if case .tag(let t) = app.gallery.filter { t } else { nil }
            let list = allTagsShown ? all : index.topTags(Self.tagLimit, keeping: shown)
            Section("Tags", isExpanded: $tagsOpen) {
                ForEach(list, id: \.tag) { entry in
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
                if all.count > Self.tagLimit {
                    Button {
                        withAnimation { allTagsShown.toggle() }
                    } label: {
                        Label(
                            allTagsShown ? "Fewer" : "\(all.count - list.count) More",
                            systemImage: allTagsShown ? "minus.circle" : "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(allTagsShown ? "Only the \(Self.tagLimit) most used tags" : "All tags, most used first")
                }
            }
        }
    }

    @ViewBuilder private var compositionRows: some View {
        let compositions = app.compositions
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
        if compositions.list.isEmpty {
            Text("No compositions yet.").foregroundStyle(.secondary)
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if let doc = app.compositions.document { return .composition(doc.composition.id) }
                // While the node graph is shown no folder is, so any click brings the gallery back.
                return showNodes ? nil : .pictures(app.gallery.filter)
            },
            set: { item in
                switch item {
                case .pictures(let filter):
                    app.compositions.close()
                    showNodes = false
                    app.gallery.filter = filter
                case .composition(let id):
                    showNodes = false
                    app.compositions.open(id)
                case nil:
                    break
                }
            })
    }

    private func row(_ title: String, _ icon: String, _ filter: GalleryFilter, count: Int) -> some View {
        rowLabel(title, icon, count: count)
            .tag(SidebarItem.pictures(filter))
            .dropDestination(for: String.self) { payload, _ in drop(payload, on: filter) }
    }

    private func rowLabel(_ title: String, _ icon: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    /// A folder: a folder dropped on its upper or lower edge goes before or
    /// after it, in the middle inside it; pictures go into it.
    private func folderRow(_ folder: GalleryFolder) -> some View {
        let gallery = app.gallery
        return FolderDropRow { zone, payload in
            drop(payload, on: folder.id, zone)
        } label: {
            rowLabel(folder.name, "folder", count: gallery.index.count(.folder(folder.id)))
        }
        .tag(SidebarItem.pictures(.folder(folder.id)))
        .draggable("folder:\(folder.id.uuidString)")
        .contextMenu {
            Button("New Folder Inside", systemImage: "folder.badge.plus") {
                let inner = gallery.addFolder(named: "New Folder", in: folder.id)
                gallery.filter = .folder(inner.id)
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

    private func drop(_ payload: [String], on target: UUID, _ zone: FolderDropZone) {
        let folders = payload.flatMap { $0.split(separator: "\n") }
            .compactMap { $0.hasPrefix("folder:") ? UUID(uuidString: String($0.dropFirst(7))) : nil }
        guard zone != .inside, !folders.isEmpty else {
            _ = drop(payload, on: .folder(target))
            return
        }
        // Several in a row: each after the one placed before it.
        var next = target
        for (i, id) in folders.enumerated() {
            app.gallery.placeFolder(id, next: next, after: zone == .after || i > 0)
            next = id
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

/// Where on a folder's row something was dropped.
private enum FolderDropZone {
    case before, inside, after
}

/// A sidebar row that tells where on it something was dropped: its upper
/// quarter, its lower quarter, or the middle. A line shows the edge.
private struct FolderDropRow<Label: View>: View {
    typealias Zone = FolderDropZone

    let onDrop: @MainActor ([String], Zone) -> Void
    @ViewBuilder let label: Label
    @State private var zone: Zone?
    @State private var height = 24.0

    init(onDrop: @escaping @MainActor (Zone, [String]) -> Void, @ViewBuilder label: () -> Label) {
        self.onDrop = { payload, zone in onDrop(zone, payload) }
        self.label = label()
    }

    var body: some View {
        label
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
            .onDrop(of: [.text], delegate: Delegate(height: height, zone: $zone, onDrop: onDrop))
            .overlay(alignment: zone == .after ? .bottom : .top) {
                if zone == .before || zone == .after {
                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: zone == .after ? 3 : -3)
                }
            }
            .background {
                if zone == .inside { RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2)) }
            }
    }

    private struct Delegate: DropDelegate {
        let height: Double
        @Binding var zone: Zone?
        let onDrop: @MainActor ([String], Zone) -> Void

        func zone(at y: Double) -> Zone {
            y < height * 0.25 ? .before : y > height * 0.75 ? .after : .inside
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            zone = zone(at: info.location.y)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) { zone = nil }

        func performDrop(info: DropInfo) -> Bool {
            let at = zone(at: info.location.y)
            zone = nil
            let providers = info.itemProviders(for: [.text])
            for provider in providers {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in onDrop([text], at) }
                }
            }
            return !providers.isEmpty
        }
    }
}

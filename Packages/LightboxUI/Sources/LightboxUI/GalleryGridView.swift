import LightboxCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Thumbnails of the pictures shown, newest first. On the Mac a click
/// selects (⌘ or ⇧ adds) and a double-click opens; on the iPad a tap opens.
struct GalleryGridView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("thumbnailSize") private var thumbnailSize = 180.0
    @State private var deleting: Set<UUID> = []
    @State private var exporting: GalleryItem?
    @State private var newFolderFor: Set<UUID>?
    @State private var newFolderName = ""
    @State private var tagging: Set<UUID>?
    @AppStorage(PanelKeys.generate) private var showGenerate = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        let gallery = app.gallery
        let items = gallery.items
        let generation = app.generation
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 10)], spacing: 10) {
                if generation.isRunning { RunningCard().aspectRatio(1, contentMode: .fit) }
                ForEach(items) { item in
                    ThumbnailCell(item: item, selected: gallery.selection.contains(item.id))
                        .aspectRatio(1, contentMode: .fit)
                        .contentShape(Rectangle())
                        #if os(macOS)
                            .onTapGesture(count: 2) { gallery.open(item.id) }
                            .onTapGesture { select(item.id, in: items) }
                        #else
                            .onTapGesture { gallery.open(item.id) }
                        #endif
                        .contextMenu { menu(for: item) }
                        .draggable(gallery.targets(for: item.id).map(\.uuidString).joined(separator: "\n"))
                }
            }
            .padding()
        }
        .overlay {
            if items.isEmpty, gallery.isSearching {
                ContentUnavailableView.search(text: gallery.search)
            } else if items.isEmpty, !generation.isRunning {
                ContentUnavailableView(
                    "No Pictures", systemImage: "photo.on.rectangle",
                    description: Text(
                        gallery.filter == .all
                            ? "Write a prompt under Generate and press Generate. Every picture lands here, with its settings."
                            : "New pictures go into the folder that is shown. Drag pictures onto a folder to move them."
                    ))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header(count: items.count) }
        .navigationTitle(gallery.title)
        .sheet(isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            TagsSheet(ids: tagging ?? [])
        }
        #if os(macOS)
            .onDeleteCommand { if !gallery.selection.isEmpty { deleting = gallery.selection } }
        #endif
        .confirmationDialog(
            deleting.count == 1 ? "Delete this picture?" : "Delete \(deleting.count) pictures?",
            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                gallery.delete(deleting)
                deleting = []
            }
        } message: {
            Text("The picture files and their settings are removed from this device.")
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: exporting.flatMap { gallery.pngData($0.id) }.map(PNGFile.init),
            contentType: .png, defaultFilename: exporting.map(Self.fileName) ?? "lightbox.png"
        ) { _ in }
        .alert(
            "New Folder", isPresented: Binding(get: { newFolderFor != nil }, set: { if !$0 { newFolderFor = nil } })
        ) {
            TextField("Name", text: $newFolderName)
            Button("Create and Move") {
                if let ids = newFolderFor {
                    // Inside the folder shown, if one is.
                    let folder = gallery.addFolder(named: newFolderName, in: gallery.filter.folderID)
                    gallery.move(ids, to: folder.id)
                }
                newFolderFor = nil
            }
            Button("Cancel", role: .cancel) { newFolderFor = nil }
        }
    }

    /// The picture count, and the thumbnail size at the top right.
    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            searchField
            Text(
                app.gallery.isSearching
                    ? (count == 1 ? "1 found" : "\(count) found")
                    : (count == 1 ? "1 picture" : "\(count) pictures")
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize()
            Spacer()
            Button("Edit", systemImage: "square.3.layers.3d") { app.compositions.edit(Array(app.gallery.selection)) }
                .controlSize(.small)
                .disabled(app.gallery.selection.isEmpty)
                .help(
                    app.gallery.selection.count > 1
                        ? "Put the selected pictures together in the editor"
                        : "Open the selected picture in the editor (select one or more first)"
                )
                .padding(.trailing, 8)
            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
            Slider(value: $thumbnailSize, in: 100...360) { Text("Thumbnail size") }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 120)
                .help("Thumbnail size")
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            if !showGenerate {
                // Where the Generate panel's own button was, at the same height.
                PanelButton(title: "Show the Generate panel", systemImage: "sidebar.trailing") { showGenerate = true }
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: PanelHeader.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Search in the gallery's own bar: the folder or tag shown, or everything.
    private var searchField: some View {
        let gallery = app.gallery
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(
                    "Search", text: Binding(get: { gallery.search }, set: { gallery.search = $0 }),
                    prompt: Text("Prompt, model, seed or #tag")
                )
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($searchFocused)
                #if os(macOS)
                    .onExitCommand { gallery.search = "" }
                #endif
                if gallery.isSearching {
                    Button("Clear", systemImage: "xmark.circle.fill") { gallery.search = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 160, maxWidth: 280)
            if gallery.isSearching, gallery.filter != .all {
                Picker(
                    "Search in",
                    selection: Binding(get: { gallery.searchEverywhere }, set: { gallery.searchEverywhere = $0 })
                ) {
                    Text(gallery.title).tag(false)
                    Text("All Pictures").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Search the folder or tag shown, or all pictures")
            }
            // ⌘F puts the cursor into the search field.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func menu(for item: GalleryItem) -> some View {
        let gallery = app.gallery
        let items = gallery.items
        let targets = gallery.targets(for: item.id)
        if targets.count == 1 {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { gallery.open(item.id) }
            Divider()
            Button("Use Settings", systemImage: "slider.horizontal.3") { app.useSettings(of: item.recipe) }
            Button("Use Settings with a New Seed", systemImage: "dice") {
                app.useSettings(of: item.recipe, includingSeed: false)
            }
            Button("Use Seed", systemImage: "number") { app.useSeed(of: item.recipe) }
            Button("Copy Prompt", systemImage: "doc.on.doc") { Pasteboard.copy(item.recipe.prompt) }
            Divider()
        }
        UseAsGuideMenu(title: targets.count == 1 ? "Use as Guide" : "Use \(targets.count) Pictures as Guides") {
            kind in app.useAsGuides(items.map(\.id).filter(targets.contains), kind: kind)
        }
        if targets.count == 1, !item.isCutOut {
            RemoveBackgroundButton(id: item.id)
        }
        if targets.count == 1 {
            let loras = item.recipe.sent.loras.map(\.name)
            if !loras.isEmpty {
                Menu("Use as LoRA Picture", systemImage: LoraInfoIcon.name) {
                    ForEach(loras, id: \.self) { name in
                        Button(PresetDetector.displayName(name)) {
                            if let png = gallery.pngData(item.id) { app.setLoraPicture(name, image: png) }
                        }
                    }
                }
                .help("Show this picture for a LoRA it was made with, when choosing LoRAs")
            }
            Menu("Use as Style Preview", systemImage: "camera.filters") {
                ForEach(ModifierCategory.allCases, id: \.self) { category in
                    Section(category.label) {
                        ForEach(app.library.modifiers.filter { $0.category == category }) { m in
                            Button(m.name) {
                                if let png = gallery.pngData(item.id) { app.setPreview(m.id, image: png) }
                            }
                        }
                    }
                }
            }
        }
        Divider()
        Button(
            targets.count == 1 ? "Edit" : "Edit \(targets.count) Pictures Together", systemImage: "square.3.layers.3d"
        ) {
            app.compositions.edit(Array(targets))
        }
        .help("Open in the editor: layers, magic wand, brush, Edit with Model")
        if targets.count == 1, let id = item.composition, app.compositions.composition(id) != nil {
            Button("New Composition", systemImage: "square.3.layers.3d.down.right") {
                app.compositions.create(with: [item.id])
            }
            .help("Start a new composition with this picture instead of opening the one it came from")
        }
        if targets.count == 1, item.workflow != nil {
            Button("Open Workflow", systemImage: "point.3.connected.trianglepath.dotted") {
                app.workflows.openRun(of: item.id, catalog: app.catalog)
            }
            .help("Open the node-editor workflow this picture was made with, as it was run")
        }
        Button(targets.count == 1 ? "Tags…" : "Tags for \(targets.count) Pictures…", systemImage: "tag") {
            tagging = targets
        }
        Menu(targets.count == 1 ? "Move to" : "Move \(targets.count) Pictures to", systemImage: "folder") {
            Button("Not in a Folder") { gallery.move(targets, to: nil) }
            // Indented as in the sidebar.
            ForEach(gallery.index.folderTree, id: \.folder.id) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) {
                    gallery.move(targets, to: entry.folder.id)
                }
            }
            Divider()
            Button("New Folder…") {
                newFolderName = ""
                newFolderFor = targets
            }
        }
        if targets.count == 1 {
            Button("Save As…", systemImage: "square.and.arrow.down") { exporting = item }
            Button("Copy Image", systemImage: "photo.on.rectangle") {
                if let png = gallery.pngData(item.id) { Pasteboard.copy(png: png) }
            }
        }
        Divider()
        Button(
            targets.count == 1 ? "Delete…" : "Delete \(targets.count) Pictures…", systemImage: "trash",
            role: .destructive
        ) {
            deleting = targets
        }
    }

    private func select(_ id: UUID, in items: [GalleryItem]) {
        let gallery = app.gallery
        #if os(macOS)
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                if gallery.selection.contains(id) { gallery.selection.remove(id) } else { gallery.selection.insert(id) }
                return
            }
            if flags.contains(.shift), let anchor = items.firstIndex(where: { gallery.selection.contains($0.id) }),
                let to = items.firstIndex(where: { $0.id == id })
            {
                gallery.selection.formUnion(items[min(anchor, to)...max(anchor, to)].map(\.id))
                return
            }
        #endif
        gallery.selection = [id]
    }

    static func fileName(_ item: GalleryItem) -> String {
        let words = item.recipe.prompt.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(5)
        let stem = words.isEmpty ? "lightbox" : words.joined(separator: "-").lowercased()
        return "\(stem)-\(item.recipe.seed).png"
    }
}

/// One picture in the grid.
struct ThumbnailCell: View {
    let item: GalleryItem
    let selected: Bool
    @Environment(AppModel.self) private var app
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if item.isCutOut { Checkerboard() }
            if let image = image ?? app.gallery.cachedThumbnail(item.id) {
                FittedImage(image: image)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .overlay {
            if app.gallery.cutting.contains(item.id) { ProgressView().controlSize(.small) }
        }
        // The edge changes when a cut-out is cut again, the date when a
        // composition is saved again.
        .task(id: "\(item.id)/\(item.edge ?? -1)/\(item.date.timeIntervalSince1970)") {
            image = await app.gallery.thumbnail(item.id)
        }
        .help(item.recipe.prompt)
        .accessibilityLabel(item.recipe.prompt.isEmpty ? "Picture" : item.recipe.prompt)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The generation in progress, shown first in the grid.
struct RunningCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let gen = app.generation
        ZStack {
            Color.primary.opacity(0.05)
            if let preview = gen.preview {
                FittedImage(image: preview).opacity(0.85)
            }
            VStack(spacing: 8) {
                Spacer()
                if gen.totalSteps > 0, gen.step > 0 {
                    ProgressView(value: Double(gen.step), total: Double(gen.totalSteps))
                } else {
                    ProgressView()
                }
                if case .running(let text) = gen.state {
                    Text(text).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                }
            }
            .padding(10)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
    }
}

/// Add a copy of a picture without its background, next to it.
struct RemoveBackgroundButton: View {
    let id: UUID
    @Environment(AppModel.self) private var app

    var body: some View {
        let busy = app.gallery.cutting.contains(id)
        Button(busy ? "Removing Background…" : "Remove Background", systemImage: "person.and.background.dotted") {
            Task { await app.gallery.removeBackground(of: id) }
        }
        .disabled(busy)
        .help("Add a copy without the background next to this picture")
    }
}

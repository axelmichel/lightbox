import LightboxCore
import SwiftUI

/// The full view: one picture large, the others in a strip below. Step with
/// the arrow keys, the buttons at the sides, a swipe, or the strip. Fit or
/// zoom with a pinch or a double-click. The info panel shows everything the
/// picture was made with.
struct ImageViewer: View {
    @State var current: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var picture: (image: CGImage, png: Data)?
    @State private var loadedID: UUID?
    @State private var zoom: CGFloat = 1
    @State private var fit = true
    @State private var showInfo = true
    @State private var exporting = false
    @State private var deleting = false
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        let items = app.gallery.items
        let index = items.firstIndex { $0.id == current }
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black.opacity(0.92)
                    if let picture, loadedID == current {
                        image(picture.image, cutOut: index.map { items[$0].isCutOut } ?? false)
                    } else if index == nil {
                        ContentUnavailableView("Picture deleted", systemImage: "photo")
                    } else {
                        ProgressView()
                    }
                    if let index { arrows(items, index) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let index, items[index].isCutOut { edgeBar(items[index]) }
                Filmstrip(items: items, current: $current)
            }
            .inspector(isPresented: $showInfo) {
                Group {
                    if let index {
                        RecipeInfoView(item: items[index]) { dismiss() }
                    } else {
                        Color.clear
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
            .toolbar { toolbar(items, index) }
            .navigationTitle(index.map { "\($0 + 1) of \(items.count)" } ?? "")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        // The edge changes when a cut-out is cut again.
        .task(id: "\(current)/\(index.flatMap { items[$0].edge } ?? -1)") { await load(current) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1, items) }
        .onKeyPress(.rightArrow) { step(1, items) }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .fileExporter(
            isPresented: $exporting, document: picture.map { PNGFile(data: $0.png) }, contentType: .png,
            defaultFilename: index.map { GalleryGridView.fileName(items[$0]) } ?? "lightbox.png"
        ) { _ in }
        .confirmationDialog("Delete this picture?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent(items) }
        }
        #if os(macOS)
            .frame(minWidth: 1000, idealWidth: 1400, minHeight: 700, idealHeight: 1000)
        #endif
    }

    @ViewBuilder private func image(_ image: CGImage, cutOut: Bool) -> some View {
        if fit {
            FittedImage(image: image)
                .background { if cutOut { Checkerboard() } }
                .padding()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { setZoom(1) }
                .gesture(MagnifyGesture().onEnded { if $0.magnification > 1.1 { setZoom($0.magnification) } })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30).onEnded { value in
                        let dx = value.translation.width
                        guard abs(dx) > abs(value.translation.height), abs(dx) > 60 else { return }
                        _ = step(dx < 0 ? 1 : -1, app.gallery.items)
                    })
        } else {
            let scale = zoom * pinch
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(scale >= 2 ? .none : .high)
                    .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    .background { if cutOut { Checkerboard() } }
            }
            .defaultScrollAnchor(.center)
            .onTapGesture(count: 2) { fit = true }
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { zoom = min(max(zoom * $0.magnification, 0.25), 8) })
        }
    }

    private func arrows(_ items: [GalleryItem], _ index: Int) -> some View {
        HStack {
            arrow("chevron.left", "Previous", enabled: index > 0) { _ = step(-1, items) }
            Spacer()
            arrow("chevron.right", "Next", enabled: index < items.count - 1) { _ = step(1, items) }
        }
        .padding(.horizontal, 12)
    }

    private func arrow(_ icon: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .font(.title2.weight(.semibold))
            .padding(12)
            .background(.ultraThinMaterial, in: Circle())
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0)
            .disabled(!enabled)
    }

    @ToolbarContentBuilder private func toolbar(_ items: [GalleryItem], _ index: Int?) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(
                fit ? "Actual Size" : "Fit",
                systemImage: fit ? "1.magnifyingglass" : "arrow.down.right.and.arrow.up.left"
            ) {
                if fit { setZoom(1) } else { fit = true }
            }
            if let index {
                let item = items[index]
                Button("Edit", systemImage: "square.3.layers.3d") {
                    dismiss()
                    app.compositions.edit([item.id])
                }
                .help(
                    item.composition == nil
                        ? "Open the picture in the editor: layers, magic wand, brush, Edit with Model"
                        : "Open the composition this picture was saved from")
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Save As…", systemImage: "square.and.arrow.down") { exporting = true }
                    Button("Copy Image", systemImage: "photo.on.rectangle") {
                        if let png = picture?.png { Pasteboard.copy(png: png) }
                    }
                    UseAsGuideMenu { kind in
                        app.useAsGuides([item.id], kind: kind)
                        dismiss()
                    }
                    if !item.isCutOut {
                        Button("Remove Background", systemImage: "person.and.background.dotted") {
                            Task { if let cut = await app.gallery.removeBackground(of: item.id) { current = cut } }
                        }
                        .disabled(app.gallery.cutting.contains(item.id))
                    }
                    Menu("Move to", systemImage: "folder") {
                        Button("Not in a Folder") { app.gallery.move([item.id], to: nil) }
                        ForEach(app.gallery.index.folderTree, id: \.folder.id) { entry in
                            Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) {
                                app.gallery.move([item.id], to: entry.folder.id)
                            }
                        }
                    }
                    Divider()
                    Button("Delete…", systemImage: "trash", role: .destructive) { deleting = true }
                }
            }
            Button("Info", systemImage: "info.circle") { showInfo.toggle() }
        }
    }

    /// How tightly a cut-out is cut; cut again from the original on release.
    private func edgeBar(_ item: GalleryItem) -> some View {
        HStack {
            if app.gallery.item(item.source ?? UUID()) != nil {
                EdgeSlider(
                    edge: item.edge ?? BackgroundRemoval.defaultEdge, busy: app.gallery.cutting.contains(item.id)
                ) { edge in
                    Task { await app.gallery.changeEdge(of: item.id, to: edge) }
                }
                .frame(maxWidth: 420)
            } else {
                Text("Cut-out. Its original was deleted, so the edge can't be changed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func load(_ id: UUID) async {
        let loaded = await app.gallery.picture(id)
        guard id == current else { return }
        picture = loaded
        loadedID = id
        fit = true
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 0.25), 8)
        fit = false
    }

    private func step(_ delta: Int, _ items: [GalleryItem]) -> KeyPress.Result {
        guard let i = items.firstIndex(where: { $0.id == current }), items.indices.contains(i + delta) else {
            return .ignored
        }
        current = items[i + delta].id
        return .handled
    }

    /// Delete and show the next picture (or the one before the last).
    private func deleteCurrent(_ items: [GalleryItem]) {
        guard let i = items.firstIndex(where: { $0.id == current }) else { return }
        let next = items.indices.contains(i + 1) ? items[i + 1].id : i > 0 ? items[i - 1].id : nil
        app.gallery.delete([current])
        if let next { current = next } else { dismiss() }
    }
}

/// Thumbnails of all pictures shown, the current one framed.
struct Filmstrip: View {
    let items: [GalleryItem]
    @Binding var current: UUID

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(items) { item in
                        ThumbnailCell(item: item, selected: item.id == current)
                            .frame(width: 64, height: 64)
                            .onTapGesture { current = item.id }
                            .id(item.id)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .frame(height: 80)
            .background(.bar)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { withAnimation { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

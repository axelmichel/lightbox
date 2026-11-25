import LightboxCore
import SwiftUI

/// Create and edit the camera, light, film and comic styles, and their
/// previews.
struct StylesView: View {
    /// What the editor opens with.
    enum Start: Identifiable, Hashable {
        /// A new style of this category.
        case new(ModifierCategory)
        /// This style; `nil` = the first.
        case existing(UUID?)

        var id: Self { self }
    }

    let start: Start
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(ModifierCategory.allCases, id: \.self) { category in
                    Section(category.label) {
                        ForEach(app.library.modifiers.filter { $0.category == category }) { m in
                            row(m).tag(m.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Menu("Add", systemImage: "plus") {
                        ForEach(ModifierCategory.allCases, id: \.self) { category in
                            Button("New \(category.label) Style") { add(category) }
                        }
                    }
                }
            }
        } detail: {
            if let selection, app.library.modifier(selection) != nil {
                StyleEditor(id: selection)
            } else {
                ContentUnavailableView(
                    "No Style Selected", systemImage: "camera.filters",
                    description: Text(
                        "Styles add camera, light and film terms to photos, or a comic style to drawings."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear {
            switch start {
            case .new(let category): add(category)
            case .existing(let id): selection = id ?? app.library.modifiers.first?.id
            }
        }
        #if os(macOS)
            .frame(minWidth: 760, idealWidth: 880, minHeight: 540, idealHeight: 640)
        #endif
    }

    private func row(_ m: StyleModifier) -> some View {
        HStack(spacing: 8) {
            StylePreview(image: app.previews[m.id], icon: m.category.icon).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name.isEmpty ? "Untitled" : m.name).lineLimit(1)
                Text(m.positive).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(m) }
            if let original = m.original, original != m {
                Button("Restore Default", systemImage: "arrow.counterclockwise") { restore(original) }
            }
            if !m.builtIn {
                Button("Delete", systemImage: "trash", role: .destructive) { delete(m.id) }
            }
        }
    }

    private func add(_ category: ModifierCategory) {
        let m = StyleModifier(name: "New \(category.label) Style", category: category)
        app.library.modifiers.append(m)
        selection = m.id
    }

    private func duplicate(_ m: StyleModifier) {
        var copy = m
        copy.id = UUID()
        copy.name += " copy"
        copy.builtIn = false
        app.library.modifiers.append(copy)
        selection = copy.id
    }

    private func restore(_ original: StyleModifier) {
        guard let i = app.library.modifiers.firstIndex(where: { $0.id == original.id }) else { return }
        app.library.modifiers[i] = original
    }

    private func delete(_ id: UUID) {
        app.deleteModifier(id)
        if selection == id { selection = app.library.modifiers.first?.id }
    }
}

/// One style: name, category, terms and preview.
private struct StyleEditor: View {
    let id: UUID
    @Environment(AppModel.self) private var app
    @State private var picking = false

    var body: some View {
        @Bindable var app = app
        if let i = app.library.modifiers.firstIndex(where: { $0.id == id }) {
            let m = $app.library.modifiers[i]
            let style = app.library.modifiers[i]
            let gen = app.generation
            Form {
                Section {
                    TextField("Name", text: m.name)
                    Picker("Category", selection: m.category) {
                        ForEach(ModifierCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(
                        style.category == .comic
                            ? "Offered for anime and illustration presets." : "Offered for photo presets.")
                }

                Section("Terms") {
                    PromptField(title: "Added to the prompt", text: m.positive, height: 64)
                    PromptField(title: "Added to the negative", text: m.negative, height: 44)
                }

                Section {
                    HStack(alignment: .top, spacing: 16) {
                        StylePreview(image: app.previews[id], icon: style.category.icon)
                            .frame(width: 160, height: 160)
                            .overlay {
                                if gen.renderingPreview == id { ProgressView() }
                            }
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Render Preview", systemImage: "wand.and.stars") {
                                gen.renderPreview(of: style, app)
                            }
                            .disabled(!app.isConnected || gen.isRunning)
                            .help("Make a small sample picture with this style on the server")
                            Button("Choose from Gallery…", systemImage: "photo.on.rectangle") { picking = true }
                                .disabled(app.gallery.index.items.isEmpty)
                            if app.previews[id] != nil {
                                Button("Remove Preview", systemImage: "trash", role: .destructive) {
                                    app.removePreview(id)
                                }
                            }
                            if gen.renderingPreview == id, case .running(let text) = gen.state {
                                Text(text).font(.caption).foregroundStyle(.secondary)
                            }
                            if gen.renderingPreview == nil, case .failed(let message) = gen.state {
                                Text(message).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Preview")
                } footer: {
                    Text(
                        "Render Preview draws a sample picture with the current preset (or the first one that fits) and this style."
                    )
                }

                if let original = style.original, original != style {
                    Section {
                        Button("Restore Default", systemImage: "arrow.counterclockwise") {
                            app.library.modifiers[i] = original
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(style.name)
            .sheet(isPresented: $picking) {
                GalleryPickerSheet(title: "Preview for “\(style.name)”") { png in
                    app.setPreview(id, image: png)
                }
            }
        }
    }
}

/// Pick one gallery picture.
struct GalleryPickerSheet: View {
    let title: String
    let pick: (Data) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(app.gallery.index.items) { item in
                        Button {
                            if let png = app.gallery.pngData(item.id) { pick(png) }
                            dismiss()
                        } label: {
                            ThumbnailCell(item: item, selected: false).aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 480)
        #endif
    }
}

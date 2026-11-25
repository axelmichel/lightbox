import ComfyKit
import LightboxCore
import SwiftUI
import UniformTypeIdentifiers

/// The node editor in the main area: the canvas, with Run, Save, search
/// and the subgraph path over it.
struct NodeEditorView: View {
    @Bindable var editor: NodeEditorModel
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo
    @State private var exporting: ExportFile?

    struct ExportFile: Identifiable {
        let id = UUID()
        let document: JSONFile
        let name: String
    }

    var body: some View {
        NodeCanvas(editor: editor)
            .overlay(alignment: .topLeading) { breadcrumb }
            .overlay(alignment: .bottomLeading) { saveButton }
            .overlay(alignment: .bottom) { status }
            .overlay(alignment: .top) {
                if editor.search != nil {
                    NodeSearch(editor: editor).padding(.top, 40)
                }
            }
            .navigationTitle(editor.entry.name)
            .toolbar { toolbar }
            .alert(
                "Node Editor",
                isPresented: Binding(get: { editor.problem != nil }, set: { if !$0 { editor.problem = nil } })
            ) {
                Button("OK") { editor.problem = nil }
            } message: {
                Text(editor.problem ?? "")
            }
            .fileExporter(
                isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                document: exporting?.document, contentType: .json, defaultFilename: exporting?.name
            ) { _ in exporting = nil }
            .onDisappear { undo?.removeAllActions(withTarget: editor) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Gallery", systemImage: "chevron.backward") { app.workflows.close() }
                .help("Back to the gallery; the workflow is kept")
        }
        ToolbarItemGroup {
            Button("Add Node", systemImage: "plus") {
                editor.search = .init(position: editor.viewCenter)
            }
            .disabled(editor.isReadOnly)
            .help("Add a node (or double-click the canvas)")
            Menu("Edit", systemImage: "ellipsis.circle") {
                Button("Bypass", systemImage: "arrow.uturn.right") { editor.toggleMode(.bypass, undo: undo) }
                    .keyboardShortcut("b")
                Button("Mute", systemImage: "speaker.slash") { editor.toggleMode(.never, undo: undo) }
                    .keyboardShortcut("m", modifiers: .control)
                Button("Duplicate", systemImage: "plus.square.on.square") { editor.duplicateSelection(undo: undo) }
                    .keyboardShortcut("d")
                Button("Group Selection", systemImage: "rectangle.dashed") {
                    editor.addGroup(at: editor.viewCenter, catalog: app.catalog, undo: undo)
                }
                .keyboardShortcut("g")
                Divider()
                Button("Export Workflow…", systemImage: "square.and.arrow.up") {
                    if let data = editor.exportData() {
                        exporting = ExportFile(document: JSONFile(data: data), name: "\(editor.entry.name).json")
                    }
                }
                Button("Export for the API…", systemImage: "square.and.arrow.up.on.square") {
                    if let data = editor.exportAPI(catalog: app.catalog) {
                        exporting = ExportFile(document: JSONFile(data: data), name: "\(editor.entry.name)_api.json")
                    }
                }
                Button("Make a Preset", systemImage: "slider.horizontal.3") { makePreset() }
            }
            .disabled(editor.isReadOnly)
            if editor.isRunning {
                Button("Stop", systemImage: "stop.fill") { editor.stop() }
                    .help("Stop the run on the server")
            } else {
                Button("Run", systemImage: "play.fill") { editor.run(app) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.isConnected)
                    .help(app.isConnected ? "Queue the workflow (⌘↩)" : "Connect to ComfyUI first")
            }
        }
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if !editor.path.isEmpty {
            HStack(spacing: 6) {
                Button(editor.entry.name) { editor.leave() }
                ForEach(Array(editor.pathNames.enumerated()), id: \.offset) { i, name in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(name) { editor.leave(to: i + 1) }
                        .disabled(i == editor.pathNames.count - 1)
                }
                Text("read-only").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
        }
    }

    private var saveButton: some View {
        Button(editor.unsaved ? "Save" : "Saved", systemImage: "square.and.arrow.down") { editor.save() }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderless)
            .keyboardShortcut("s")
            .help(editor.unsaved ? "Save the workflow (⌘S)" : "All changes are saved")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
    }

    @ViewBuilder
    private var status: some View {
        if editor.isRunning || editor.savedCount > 0 {
            HStack(spacing: 8) {
                if editor.isRunning {
                    ProgressView().controlSize(.small)
                    Text(runningText)
                } else {
                    Image(systemName: "photo.on.rectangle")
                    Text(
                        editor.savedCount == 1
                            ? "1 picture saved to the gallery" : "\(editor.savedCount) pictures saved to the gallery")
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
        }
    }

    private var runningText: String {
        guard let path = editor.executing else { return "Queued…" }
        let node = editor.doc.graph.node(path.subgraphs.first ?? path.node)
        let name = node.map { $0.title ?? app.catalog.nodes[$0.type]?.displayName ?? $0.type } ?? "#\(path.apiID)"
        return editor.totalSteps > 0 ? "\(name): \(editor.step) / \(editor.totalSteps)" : name
    }

    /// A preset with the checkpoint, sampling and prompts this workflow uses.
    private func makePreset() {
        guard let data = editor.exportAPI(catalog: app.catalog) else { return }
        do {
            let result = try WorkflowImport.read(data, name: editor.entry.name)
            app.library.presets.append(result.preset)
            app.library.knownCheckpoints.insert(result.preset.checkpoint)
            app.generation.presetID = result.preset.id
            if !result.prompt.isEmpty { app.generation.prompt = result.prompt }
            editor.problem = "The preset “\(result.preset.name)” was added; it is picked in Generate."
        } catch {
            editor.problem = "\(error)"
        }
    }
}

/// A JSON file for `fileExporter`.
struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Find a node to add: by name, kind or category; filtered to nodes that
/// fit the link being dropped, if any.
struct NodeSearch: View {
    @Bindable var editor: NodeEditorModel
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Entry: Hashable {
        let type: String
        let name: String
        let category: String
    }

    var body: some View {
        let results = matches
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search nodes", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { pick(results.isEmpty ? nil : results[min(highlighted, results.count - 1)]) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(0, results.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(0, highlighted - 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        editor.search = nil
                        return .handled
                    }
                Button("Close", systemImage: "xmark.circle.fill") { editor.search = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.prefix(200).enumerated()), id: \.element) { i, entry in
                        Button {
                            pick(entry)
                        } label: {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                Text(entry.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(i == highlighted ? Color.accentColor.opacity(0.3) : Color.clear)
                        .id(i)
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
            .frame(height: 320)
        }
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private var matches: [Entry] {
        let request = editor.search
        var all = app.catalog.nodes.compactMap { type, spec -> Entry? in
            guard !spec.isDeprecated else { return nil }
            if let from = request?.fromOutput {
                guard
                    spec.inputs.values.contains(where: { NodeGraph.accepts($0.type, from: from.type) && !$0.isWidget })
                else { return nil }
            }
            if let to = request?.toInput {
                guard spec.outputs.contains(where: { NodeGraph.accepts(to.type, from: $0.type) }) else { return nil }
            }
            return Entry(type: type, name: spec.displayName ?? type, category: spec.category)
        }
        if request?.fromOutput == nil, request?.toInput == nil {
            all += [
                Entry(type: "Note", name: "Note", category: "utils"),
                Entry(type: "MarkdownNote", name: "Markdown Note", category: "utils"),
                Entry(type: "PrimitiveNode", name: "Primitive", category: "utils"),
            ]
        }
        if request?.fromOutput != nil || request?.toInput != nil || query.isEmpty {
            all.append(Entry(type: "Reroute", name: "Reroute", category: "utils"))
        }
        let words = query.lowercased().split(separator: " ").map(String.init)
        let found = all.filter { e in
            let hay = "\(e.name) \(e.type) \(e.category)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        // Names starting with the query first, then shorter names.
        let q = query.lowercased()
        return found.sorted { a, b in
            let pa = a.name.lowercased().hasPrefix(q)
            let pb = b.name.lowercased().hasPrefix(q)
            if pa != pb { return pa }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name < b.name
        }
    }

    private func pick(_ entry: Entry?) {
        guard let entry else { return }
        editor.add(entry.type, catalog: app.catalog, undo: undo)
    }
}

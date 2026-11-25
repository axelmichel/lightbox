import ComfyKit
import CoreGraphics
import Foundation
import LightboxCore
import Observation

/// The node editor's workflows (in the gallery folder), and the one open.
@MainActor @Observable
public final class WorkflowsModel {
    public private(set) var list: [WorkflowEntry] = []
    public private(set) var editor: NodeEditorModel?
    public var problem: String?

    let store: WorkflowStore
    private let gallery: GalleryModel

    init(store: WorkflowStore, gallery: GalleryModel) {
        self.store = store
        self.gallery = gallery
        do {
            list = try store.list()
        } catch {
            problem = "Could not read the workflows: \(AppModel.describe(error))"
        }
    }

    /// A new, empty workflow, opened.
    public func create() {
        open(WorkflowDocument(), name: store.uniqueName("Workflow"))
    }

    /// A ComfyUI file: UI format, API format, or a picture with a workflow in it.
    public func importFile(_ data: Data, name: String, catalog: ComfyCatalog) {
        do {
            open(try Self.document(from: data, catalog: catalog), name: store.uniqueName(name))
        } catch {
            problem = "\(error)"
        }
    }

    static func document(from data: Data, catalog: ComfyCatalog) throws -> WorkflowDocument {
        let text = GalleryStore.pngText(data)
        if let ui = text["workflow"], let doc = try? WorkflowDocument(data: Data(ui.utf8)) { return doc }
        if let api = text["prompt"] { return try WorkflowDocument(api: Data(api.utf8), catalog: catalog) }
        if !text.isEmpty || GalleryStore.pixelSize(data) != nil {
            throw WorkflowDocumentError.notAWorkflow
        }
        if let doc = try? WorkflowDocument(data: data) { return doc }
        return try WorkflowDocument(api: data, catalog: catalog)
    }

    /// The workflow a gallery picture was made with, as it was run.
    public func openRun(of pictureID: UUID, catalog: ComfyCatalog) {
        guard let run = gallery.item(pictureID)?.workflow, let data = gallery.workflowRun(of: pictureID),
            let json = JSONValue.parse(data), let workflow = json["workflow"]
        else {
            problem = "The workflow of this picture is missing."
            return
        }
        // The library's workflow if it is still there and unchanged since.
        do {
            open(try WorkflowDocument(json: workflow), name: store.uniqueName(run.name))
        } catch {
            problem = "\(error)"
        }
    }

    private func open(_ doc: WorkflowDocument, name: String) {
        let entry = WorkflowEntry(name: name)
        let editor = NodeEditorModel(entry: entry, doc: doc, store: store, gallery: gallery, owner: self)
        self.editor?.close()
        self.editor = editor
        editor.save()
    }

    public func open(_ id: UUID) {
        guard editor?.entry.id != id, let entry = list.first(where: { $0.id == id }) else { return }
        do {
            let doc = try WorkflowDocument(data: try store.load(id))
            editor?.close()
            editor = NodeEditorModel(entry: entry, doc: doc, store: store, gallery: gallery, owner: self)
        } catch {
            problem = "Could not open “\(entry.name)”: \(error)"
        }
    }

    public func close() {
        editor?.close()
        editor = nil
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let editor, editor.entry.id == id { editor.entry.name = trimmed }
        try? store.rename(id, to: trimmed)
        list = (try? store.list()) ?? list
    }

    public func duplicate(_ id: UUID) {
        guard let entry = list.first(where: { $0.id == id }), let data = try? store.load(id),
            let doc = try? WorkflowDocument(data: data)
        else { return }
        open(doc, name: store.uniqueName(entry.name))
    }

    public func delete(_ id: UUID) {
        if editor?.entry.id == id {
            editor?.discard()
            editor = nil
        }
        try? store.delete(id)
        list.removeAll { $0.id == id }
    }

    /// The file for Export.
    public func data(of id: UUID) -> Data? { try? store.load(id) }

    func saved(_ entry: WorkflowEntry) {
        list.removeAll { $0.id == entry.id }
        list.insert(entry, at: 0)
    }
}

/// A workflow being edited: undo, selection, running it.
@MainActor @Observable
public final class NodeEditorModel {
    public internal(set) var entry: WorkflowEntry
    public private(set) var doc: WorkflowDocument
    /// The subgraph nodes entered, outermost first; shown read-only for now.
    public private(set) var path: [Int] = []
    public var selection: Set<Int> = []
    public private(set) var unsaved = false
    public var problem: String?
    /// Node search, at a place on the canvas; with a link to connect.
    public var search: SearchRequest?
    /// The canvas point in the middle of the view, for nodes added from the toolbar.
    @ObservationIgnored var viewCenter = CGPoint.zero

    public struct SearchRequest: Identifiable {
        public let id = UUID()
        /// Canvas position for the new node.
        public var position: CGPoint
        /// Connect the new node to this output…
        public var fromOutput: (node: Int, slot: Int, type: String)?
        /// …or to this input.
        public var toInput: (node: Int, slot: Int, type: String)?
    }

    // MARK: Running

    public private(set) var isRunning = false
    /// The node running now.
    public private(set) var executing: NodePath?
    public private(set) var step = 0
    public private(set) var totalSteps = 0
    public private(set) var done: Set<NodePath> = []
    public private(set) var nodeErrors: [NodePath: [String]] = [:]
    /// Pictures each output node showed on the last run.
    public private(set) var outputs: [NodePath: [CGImage]] = [:]
    /// Load Image's pictures, by file name on the server.
    public private(set) var inputImages: [String: CGImage] = [:]
    public private(set) var savedCount = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadingImages: Set<String> = []
    @ObservationIgnored private var closed = false
    /// Copied nodes, for pasting in any workflow.
    static var clipboard: NodeGraph?

    private let store: WorkflowStore
    private let gallery: GalleryModel
    private weak var owner: WorkflowsModel?

    init(
        entry: WorkflowEntry, doc: WorkflowDocument, store: WorkflowStore, gallery: GalleryModel, owner: WorkflowsModel
    ) {
        self.entry = entry
        self.doc = doc
        self.store = store
        self.gallery = gallery
        self.owner = owner
    }

    /// The graph shown: the workflow's, or the subgraph entered.
    public var graph: NodeGraph {
        var g = doc.graph
        for id in path {
            guard let node = g.node(id), let def = doc.subgraph(node.type) else { return g }
            g = def.graph
        }
        return g
    }

    public var isReadOnly: Bool { !path.isEmpty }

    public func enter(_ node: Int) {
        guard let n = graph.node(node), doc.subgraph(n.type) != nil else { return }
        path.append(node)
        selection = []
    }

    public func leave(to depth: Int = 0) {
        path = Array(path.prefix(depth))
        selection = []
    }

    /// The subgraph names along `path`, for the breadcrumb.
    public var pathNames: [String] {
        var g = doc.graph
        var names: [String] = []
        for id in path {
            guard let node = g.node(id), let def = doc.subgraph(node.type) else { break }
            names.append(node.title ?? def.name)
            g = def.graph
        }
        return names
    }

    func kind(_ node: GraphNode, catalog: ComfyCatalog) -> NodeKind {
        NodeKind(node, doc: doc, graph: graph, catalog: catalog)
    }

    /// The node's id path, for run state.
    func nodePath(_ id: Int) -> NodePath { NodePath(id, in: path) }

    // MARK: - Undo

    /// An undoable change of the graph shown (only the top level can be changed).
    public func change(_ name: String, undo: UndoManager?, _ edit: (inout NodeGraph) -> Void) {
        guard !isReadOnly else { return }
        let before = doc
        edit(&doc.graph)
        commit(since: before, name, undo: undo)
    }

    /// For drags: change without undo, then `commit` once.
    public func live(_ edit: (inout NodeGraph) -> Void) {
        guard !isReadOnly else { return }
        edit(&doc.graph)
    }

    public func commit(since before: WorkflowDocument, _ name: String, undo: UndoManager?) {
        guard doc != before else { return }
        register(restoring: before, name, undo)
        changed()
    }

    var snapshot: WorkflowDocument { doc }

    private func register(restoring old: WorkflowDocument, _ name: String, _ undo: UndoManager?) {
        undo?.registerUndo(withTarget: self) { editor in
            let current = editor.doc
            editor.doc = old
            editor.selection = editor.selection.filter { editor.graph.node($0) != nil }
            editor.register(restoring: current, name, undo)
            editor.changed()
        }
        undo?.setActionName(name)
    }

    /// The view moved or zoomed: saved, but not undoable.
    func setViewport(scale: Double, offset: CGPoint) {
        guard doc.scale != scale || doc.offset != offset else { return }
        doc.scale = scale
        doc.offset = offset
        changed()
    }

    private func changed() {
        unsaved = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    // MARK: - Saving

    public func save() {
        guard !closed else { return }
        saveTask?.cancel()
        do {
            entry = try store.save(entry, data: try doc.data())
            unsaved = false
            owner?.saved(entry)
        } catch {
            problem = "Could not save the workflow: \(AppModel.describe(error))"
        }
    }

    func close() {
        if unsaved { save() }
        task?.cancel()
        closed = true
    }

    func discard() {
        saveTask?.cancel()
        task?.cancel()
        closed = true
    }

    /// The workflow as ComfyUI saves it, for Export.
    public func exportData() -> Data? { try? doc.data() }

    /// The prompt as `/prompt` takes it ("Export (API)").
    public func exportAPI(catalog: ComfyCatalog) -> Data? {
        try? WorkflowCompiler.compile(doc, catalog: catalog).graph.jsonData()
    }

    // MARK: - Editing

    func value(_ node: GraphNode, _ name: String, kind: NodeKind) -> JSONValue? {
        switch kind.role {
        case .note, .primitive: node.widgetsValues?.array?.first
        default: node.widgetValue(name, spec: kind.spec)
        }
    }

    func setValue(_ id: Int, _ name: String, _ value: JSONValue, kind: NodeKind, undo: UndoManager?) {
        change("Change \(name)", undo: undo) { g in
            guard let i = g.index(of: id) else { return }
            switch kind.role {
            case .note, .primitive:
                var a = g.nodes[i].widgetsValues?.array ?? []
                if a.isEmpty { a = [value] } else { a[0] = value }
                // A primitive feeding a seed has a control after it.
                if case .primitive(let spec?) = kind.role, spec.controlAfterGenerate, a.count < 2 {
                    a.append(.string("fixed"))
                }
                g.nodes[i].widgetsValues = .array(a)
            default:
                g.nodes[i].setWidgetValue(name, value, spec: kind.spec)
            }
        }
    }

    func setControl(_ id: Int, _ name: String, _ value: String, kind: NodeKind, undo: UndoManager?) {
        change("Change Seed Control", undo: undo) { g in
            guard let i = g.index(of: id) else { return }
            if case .primitive = kind.role {
                var a = g.nodes[i].widgetsValues?.array ?? [.int(0)]
                if a.count < 2 { a.append(.string(value)) } else { a[1] = .string(value) }
                g.nodes[i].widgetsValues = .array(a)
            } else {
                g.nodes[i].setControlValue(name, value, spec: kind.spec)
            }
        }
    }

    public func connect(from: Int, _ fromSlot: Int, to: Int, _ toSlot: Int, undo: UndoManager?) {
        change("Connect", undo: undo) { $0.connect(from: from, fromSlot, to: to, toSlot) }
    }

    public func disconnect(input node: Int, _ slot: Int, undo: UndoManager?) {
        change("Disconnect", undo: undo) { $0.disconnect(input: node, slot) }
    }

    /// Add a node from search, linked as the search asked.
    public func add(_ type: String, catalog: ComfyCatalog, undo: UndoManager?) {
        guard let request = search else { return }
        search = nil
        change("Add Node", undo: undo) { g in
            let id: Int
            switch type {
            case "Note", "MarkdownNote":
                var n = GraphNode(id: 0, type: type, size: CGSize(width: 400, height: 200))
                n.widgetsValues = .array([.string("")])
                id = g.addNode(n)
            case "Reroute":
                var n = GraphNode(id: 0, type: "Reroute", size: CGSize(width: 75, height: 26))
                n.inputs = [NodeInputSlot(name: "", type: "*")]
                n.outputs = [NodeOutputSlot(name: "", type: request.fromOutput?.type ?? request.toInput?.type ?? "*")]
                id = g.addNode(n)
            case "PrimitiveNode":
                var n = GraphNode(id: 0, type: "PrimitiveNode", size: CGSize(width: 260, height: 60))
                n.outputs = [NodeOutputSlot(name: "connect to widget input", type: "*")]
                id = g.addNode(n)
            default:
                guard let spec = catalog.nodes[type] else { return }
                id = g.addNode(type, spec: spec, at: .zero)
            }
            guard let i = g.index(of: id) else { return }
            g.nodes[i].position = request.position
            let kind = NodeKind(g.nodes[i], doc: doc, graph: g, catalog: catalog)
            g.nodes[i].size.height = max(
                g.nodes[i].size.height, NodeLayout(g.nodes[i], kind: kind, showsImages: false).minHeight)
            if let from = request.fromOutput,
                let slot = g.nodes[i].inputs.firstIndex(where: { NodeGraph.accepts($0.type, from: from.type) })
            {
                g.connect(from: from.node, from.slot, to: id, slot)
            } else if let to = request.toInput,
                let slot = g.nodes[i].outputs.firstIndex(where: { NodeGraph.accepts(to.type, from: $0.type) })
            {
                g.connect(from: id, slot, to: to.node, to.slot)
            }
            selection = [id]
        }
    }

    public func deleteSelection(undo: UndoManager?) {
        let ids = selection
        guard !ids.isEmpty else { return }
        change(ids.count == 1 ? "Delete Node" : "Delete Nodes", undo: undo) { $0.removeNodes(ids) }
        selection = []
    }

    public func copySelection() {
        var g = NodeGraph()
        g.duplicate(selection, from: graph, offset: .zero)
        Self.clipboard = g
    }

    public func paste(at point: CGPoint?, undo: UndoManager?) {
        guard let clip = Self.clipboard, !clip.nodes.isEmpty else { return }
        let left = clip.nodes.map(\.position.x).min() ?? 0
        let top = clip.nodes.map(\.position.y).min() ?? 0
        let offset = point.map { CGVector(dx: $0.x - left, dy: $0.y - top) } ?? CGVector(dx: 40, dy: 40)
        change("Paste", undo: undo) { g in
            let ids = g.duplicate(Set(clip.nodes.map(\.id)), from: clip, offset: offset)
            selection = Set(ids)
        }
    }

    public func duplicateSelection(undo: UndoManager?) {
        let ids = selection
        guard !ids.isEmpty else { return }
        change("Duplicate", undo: undo) { g in
            selection = Set(g.duplicate(ids, offset: CGVector(dx: 30, dy: 30)))
        }
    }

    /// Bypass or mute the selection; again sets it back to normal.
    public func toggleMode(_ mode: NodeMode, undo: UndoManager?) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let all = graph.nodes.filter { ids.contains($0.id) }.allSatisfy { $0.mode == mode }
        change(mode == .bypass ? "Bypass" : "Mute", undo: undo) { g in
            for i in g.nodes.indices where ids.contains(g.nodes[i].id) { g.nodes[i].mode = all ? .always : mode }
        }
    }

    public func edit(_ ids: Set<Int>, _ name: String, undo: UndoManager?, _ body: (inout GraphNode) -> Void) {
        change(name, undo: undo) { g in
            for i in g.nodes.indices where ids.contains(g.nodes[i].id) { body(&g.nodes[i]) }
        }
    }

    /// A group around the selection (or an empty one at `point`).
    public func addGroup(at point: CGPoint, catalog: ComfyCatalog, undo: UndoManager?) {
        let nodes = graph.nodes.filter { selection.contains($0.id) }
        var frame = CGRect(origin: point, size: CGSize(width: 400, height: 300))
        if !nodes.isEmpty {
            frame = nodes.map { NodeLayout($0, kind: kind($0, catalog: catalog), showsImages: false).bounds }
                .reduce(CGRect.null) { $0.union($1) }
                .insetBy(dx: -10, dy: -10)
            frame.origin.y -= 34
            frame.size.height += 34
        }
        change("Add Group", undo: undo) { g in
            g.lastGroupID += 1
            var group = GraphGroup(id: g.lastGroupID, title: "Group", frame: frame)
            group.color = "#3f789e"
            g.groups.append(group)
        }
    }

    public func selectAll() { selection = Set(graph.nodes.map(\.id)) }

    // MARK: - Pictures

    /// Load Image's picture on the server, loaded once.
    func inputImage(_ name: String, client: ComfyClient?) -> CGImage? {
        if let image = inputImages[name] { return image }
        guard let client, !name.isEmpty, loadingImages.insert(name).inserted else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let ref = ImageRef(
            file: String(parts.last ?? ""), subfolder: parts.dropLast().joined(separator: "/"), type: "input")
        Task {
            guard let data = try? await client.image(ref) else { return }
            let image = await Task.detached { ImageCoding.decodeUpright(data, maxSide: 1024) }.value
            self.inputImages[name] = image
        }
        return nil
    }

    /// Upload a picture and use it in a Load Image node.
    func useImage(_ data: Data, filename: String, node: Int, kind: NodeKind, client: ComfyClient?, undo: UndoManager?) {
        guard let client else {
            problem = "Connect to ComfyUI to upload pictures."
            return
        }
        guard let name = kind.widgets.first(where: { $0.spec.imageUpload })?.name else { return }
        Task {
            do {
                let png = ImageCoding.decodeUpright(data).flatMap(ImageCoding.encodePNG) ?? data
                let stem = (filename as NSString).deletingPathExtension
                let uploaded = try await client.upload(image: png, filename: "\(stem).png")
                inputImages[uploaded] = ImageCoding.decodeUpright(png, maxSide: 1024)
                setValue(node, name, .string(uploaded), kind: kind, undo: undo)
            } catch {
                problem = "Could not upload the picture: \(AppModel.describe(error))"
            }
        }
    }

    // MARK: - Running

    /// Check the workflow, put it through the content guard, queue it and
    /// follow it; pictures from Save Image nodes go to the gallery.
    public func run(_ app: AppModel) {
        guard !isRunning else { return }
        guard let client = app.client else {
            problem = "Connect to ComfyUI first (Settings)."
            return
        }
        var compiled = WorkflowCompiler.compile(doc, catalog: app.catalog)
        nodeErrors = [:]
        guard compiled.problems.isEmpty else {
            for p in compiled.problems { if let n = p.node { nodeErrors[n, default: []].append(p.message) } }
            problem = compiled.problems.map(\.message).joined(separator: "\n")
            return
        }
        // Every text in the workflow is checked, like a typed prompt.
        let rating = app.library.rating
        let result: GuardResult
        do {
            result = try ContentGuard.check(
                GuardInput(
                    positive: compiled.positiveTexts, negative: compiled.negativeTexts,
                    loraNames: compiled.loraNames, rating: rating))
        } catch {
            problem = error.description
            return
        }
        compiled.addNegative(result.forcedNegatives)
        let sent = ComposedPrompt(
            positive: compiled.positiveTexts.joined(separator: "\n"),
            negative: compiled.negativeTexts.joined(separator: "\n"),
            loras: compiled.loraNames.map { LoraUse(name: $0, weight: 1) }, minorSignal: result.minorSignal)
        let workflow = doc.json()
        let graph = compiled.graph
        let server = app.serverAddress
        let name = entry.name
        let workflowID = entry.id

        isRunning = true
        executing = nil
        done = []
        step = 0
        totalSteps = 0
        task = Task {
            var saved: [(png: Data, node: String)] = []
            defer {
                isRunning = false
                executing = nil
            }
            do {
                for try await event in client.run(graph, workflow: workflow) {
                    switch event {
                    case .queued:
                        // As ComfyUI does: seeds change after queueing.
                        doc.graph.applySeedControls(catalog: app.catalog)
                        changed()
                    case .executing(let node):
                        if let current = executing { done.insert(current) }
                        executing = NodePath(apiID: node)
                        step = 0
                        totalSteps = 0
                    case .cached(let nodes):
                        done.formUnion(nodes.compactMap(NodePath.init(apiID:)))
                    case .progress(_, let s, let total):
                        step = s
                        totalSteps = total
                    case .preview:
                        break
                    case .executed(let node, let refs):
                        var images: [CGImage] = []
                        for ref in refs {
                            let data = try await client.image(ref)
                            if ref.type == "output" { saved.append((data, node)) }
                            if let image = await Task.detached(operation: {
                                ImageCoding.decodeUpright(data, maxSide: 1024)
                            })
                            .value {
                                images.append(image)
                            }
                        }
                        if let path = NodePath(apiID: node) { outputs[path] = images }
                    case .finished, .cancelled:
                        if let current = executing { done.insert(current) }
                    }
                }
                if !saved.isEmpty {
                    let run = try JSONValue.object(["workflow": workflow, "prompt": JSONValue(graph.jsonObject())])
                        .data()
                    let ids = gallery.saveWorkflowResults(
                        saved, run: run, workflow: (workflowID, name), prompt: try graph.jsonData(), sent: sent,
                        rating: rating, server: server)
                    savedCount += ids.count
                }
            } catch let error as WorkflowRunError {
                switch error {
                case .rejected(_, let nodes):
                    for (id, messages) in nodes { if let p = NodePath(apiID: id) { nodeErrors[p] = messages } }
                case .failed(let node, _, let message):
                    if let p = node.flatMap(NodePath.init(apiID:)) { nodeErrors[p] = [message] }
                }
                problem = error.description
            } catch {
                if !(error is CancellationError) { problem = AppModel.describe(error) }
            }
        }
    }

    public func stop() {
        task?.cancel()
    }
}

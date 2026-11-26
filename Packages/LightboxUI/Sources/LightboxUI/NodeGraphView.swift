import ComfyKit
import LightboxCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The graph the Generate form would send, drawn as ComfyUI shows it: the
/// standard one, or a saved workflow brought up to date with the form. It
/// follows every change in the form. Nodes can be moved (the layout is kept
/// in the workflow); values are still changed in the form.
struct NodeGraphView: View {
    /// A name being typed for a workflow.
    private enum Naming: Identifiable {
        case new
        case rename(WorkflowEntry)

        var id: String {
            switch self {
            case .new: "new"
            case .rename(let e): e.id.uuidString
            }
        }
    }

    @Environment(AppModel.self) private var app
    @AppStorage(PanelKeys.generate) private var showGenerate = true
    @AppStorage(PanelKeys.nodes) private var showNodes = false
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: WorkflowEntry?
    /// Renewed when another workflow is picked, so the canvas starts fitted;
    /// not when moving a node saves the standard graph as a workflow.
    @State private var canvasID = UUID()
    @Environment(\.undoManager) private var undo
    @State private var exporting: JSONFile?
    @State private var exportName = "Workflow"

    var body: some View {
        let graph = app.generation.graph(app)
        let state = try? graph.get()
        Group {
            switch graph {
            case .success(let state):
                NodeCanvas(
                    state: state, catalog: app.catalog, running: app.generation.runningNode,
                    errors: app.generation.nodeErrors, onMove: { keepLayout($0, of: state) },
                    onEdit: { edit($0, $1, to: $2, in: state) },
                    onStructure: { change in structure(change, in: state) }
                )
                .id(canvasID)
            case .failure(let problem):
                ContentUnavailableView(
                    "No Graph", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(problem.message))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header(state)
                if let state, let was = state.madeFor, let workflow = state.workflow {
                    rebuiltNotice(workflow, was: was, now: state.shownFor ?? "this preset", state: state)
                }
            }
        }
        .alert(
            namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
            presenting: naming
        ) { naming in
            TextField("Name", text: $name)
            Button(namingAction(naming)) { finish(naming, state: state) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { entry in
            Button("Delete Workflow", role: .destructive) {
                app.workflows.delete(entry.id)
                app.generation.forgetWorkflow(entry.id)
            }
        } message: { _ in
            Text("The graph goes back to the preset's standard one.")
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
            contentType: .json, defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result {
                app.workflows.problem = "Could not export the workflow: \(error.localizedDescription)"
            }
        }
        .alert(
            "Workflows",
            isPresented: Binding(
                get: { app.workflows.problem != nil }, set: { if !$0 { app.workflows.problem = nil } })
        ) {
            Button("OK") { app.workflows.problem = nil }
        } message: {
            Text(app.workflows.problem ?? "")
        }
    }

    /// Like the gallery's bar, with the workflow shown and the way back to the gallery.
    private func header(_ state: GenerationModel.GraphState?) -> some View {
        HStack(spacing: 10) {
            Text("Nodes").font(.headline)
            if let preset = app.generation.preset(in: app.library) {
                workflowMenu(preset, shown: state?.workflow, canSave: state != nil, state: state)
            }
            Spacer()
            Button("Show the Gallery", systemImage: "photo.on.rectangle.angled") { showNodes = false }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
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

    private func workflowMenu(
        _ preset: GenerationPreset, shown: WorkflowEntry?, canSave: Bool, state: GenerationModel.GraphState?
    ) -> some View {
        let gen = app.generation
        let own = app.workflows.entries(for: preset.id)
        let loose = app.workflows.withoutPreset(app.library.presets)
        return Menu {
            Picker(
                "Workflow",
                selection: Binding(
                    get: { shown?.id },
                    set: {
                        gen.showWorkflow($0, app)
                        canvasID = UUID()
                    })
            ) {
                Text("Standard").tag(UUID?.none)
                if !own.isEmpty {
                    Section(preset.name) {
                        ForEach(own) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if !loose.isEmpty {
                    Section("Without a Preset") {
                        ForEach(loose) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Save as Workflow…", systemImage: "square.and.arrow.down") {
                name = app.workflows.uniqueName(preset.name)
                naming = .new
            }
            .disabled(!canSave)
            Button("Export for ComfyUI…", systemImage: "square.and.arrow.up") {
                export(state, named: shown?.name ?? preset.name)
            }
            .disabled(!canSave)
            if let shown {
                Button("Rename “\(shown.name)”…", systemImage: "pencil") {
                    name = shown.name
                    naming = .rename(shown)
                }
                Button("Delete “\(shown.name)”…", systemImage: "trash", role: .destructive) { deleting = shown }
            }
        } label: {
            Label(shown?.name ?? "Standard", systemImage: "point.3.connected.trianglepath.dotted")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The workflow shown: the preset's standard graph, or one saved with its layout")
    }

    /// The graph shown as a ComfyUI file. It can be run in ComfyUI as it is,
    /// so it is checked like sending: refused prompts aren't exported.
    private func export(_ state: GenerationModel.GraphState?, named name: String) {
        guard let state else { return }
        switch GraphSend.prepare(state.doc, catalog: app.catalog, rating: app.library.rating) {
        case .failure(let problem):
            app.workflows.problem = "Not exported: \(problem.message)"
        case .success:
            guard state.refusal == nil, let data = try? state.doc.data() else {
                app.workflows.problem = "Not exported: the prompt was refused."
                return
            }
            exportName = name
            exporting = JSONFile(data: data)
        }
    }

    /// The workflow was saved for another kind of model than its preset now
    /// uses: it is shown rebuilt, and stays as saved until rebuilt here.
    private func rebuiltNotice(_ workflow: WorkflowEntry, was: String, now: String, state: GenerationModel.GraphState)
        -> some View
    {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            Text("“\(workflow.name)” was made for \(was); shown rebuilt for \(now). Your nodes are kept.")
                .font(.callout).lineLimit(2)
            Spacer()
            Button("Rebuild, Keep a Copy") { rebuild(workflow, was: was, state: state) }
                .controlSize(.small)
                .help("Save the old version as a copy, then keep the rebuilt graph in “\(workflow.name)”")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Keep the old version as a copy, then the rebuilt graph in the
    /// workflow; its model overrides belonged to the old kind and go.
    private func rebuild(_ workflow: WorkflowEntry, was: String, state: GenerationModel.GraphState) {
        let workflows = app.workflows
        guard let old = workflows.document(workflow.id), let preset = app.generation.preset(in: app.library) else {
            return
        }
        let kind = was.hasPrefix("a ") ? String(was.dropFirst(2)) : was
        _ = workflows.save(old, name: workflows.uniqueName("\(workflow.name) (\(kind))"), presetID: preset.id)
        workflows.change(workflow.id, to: state.doc, "Rebuild Workflow", undo: undo)
        var overrides = workflow.overrides
        overrides.checkpoint = nil
        overrides.vae = nil
        overrides.textEncoders = nil
        workflows.setOverrides(workflow.id, overrides)
    }

    /// Nodes were moved: keep the layout in the workflow shown. The standard
    /// graph becomes a workflow of the preset first.
    private func keepLayout(_ moved: WorkflowDocument, of state: GenerationModel.GraphState) {
        guard moved != state.doc, let id = state.workflow?.id ?? saveStandard(state) else { return }
        app.generation.showWorkflow(id, app)
        app.workflows.change(id, to: moved, "Move Nodes", undo: undo)
    }

    /// Nodes added, deleted or linked: kept in the workflow shown (the
    /// standard graph becomes one first), with an undo step.
    private func structure(_ change: StructureChange, in state: GenerationModel.GraphState) {
        var doc = state.doc
        let name: String
        switch change {
        case .connect(let origin, let slot, let target, let input, let replacing):
            if let replacing { doc.graph.removeLink(replacing) }
            guard doc.graph.connect(from: origin, slot, to: target, input) != nil else { return }
            name = "Connect"
            // A LoRA hung into the model chain becomes one of the form's; Lightbox makes its node from then on.
            let hooked = NodeEditing.hookedLoras(doc, catalog: app.catalog)
            if !hooked.isEmpty {
                doc.graph.removeNodes(Set(hooked.map(\.node)))
                save(doc, name, state)
                app.generation.applyGraph(hooked.map(\.change), app) { saveStandard(state) }
                return
            }
        case .disconnect(let link):
            doc.graph.removeLink(link)
            name = "Disconnect"
        case .add(let type, let point):
            guard let spec = app.catalog.nodes[type] else { return }
            doc.graph.addNode(type, spec: spec, at: point)
            name = "Add Node"
        case .document(let changed, let action):
            doc = changed
            name = action
        case .delete(let nodes):
            // Added nodes go; Lightbox's that stand for a setting switch it off.
            var switches: [GraphChange] = []
            var removed: Set<Int> = []
            for node in nodes {
                switch NodeEditing.deletion(node, in: doc) {
                case .remove: removed.insert(node)
                case .switchOff(let change): switches.append(change)
                case .keep: break
                }
            }
            doc.graph.removeNodes(removed)
            save(doc, nodes.count == 1 ? "Delete Node" : "Delete Nodes", state)
            if !switches.isEmpty { app.generation.applyGraph(switches, app) { saveStandard(state) } }
            return
        }
        save(doc, name, state)
    }

    /// Keep `doc` in the workflow shown (the standard graph becomes one first).
    private func save(_ doc: WorkflowDocument, _ name: String, _ state: GenerationModel.GraphState) {
        guard doc != state.doc, let id = state.workflow?.id ?? saveStandard(state) else { return }
        app.generation.showWorkflow(id, app)
        app.workflows.change(id, to: doc, name, undo: undo)
    }

    /// A value changed in the graph: it goes into the form, which makes the
    /// graph anew. The document itself isn't changed here.
    private func edit(_ node: Int, _ input: String, to value: JSONValue, in state: GenerationModel.GraphState) {
        var edited = state.doc
        guard let i = edited.graph.index(of: node) else { return }
        edited.graph.nodes[i].setWidgetValue(input, value, spec: app.catalog.nodes[edited.graph.nodes[i].type])
        let changes = GraphChange.changes(
            from: ManagedGraph(state.doc, catalog: app.catalog).settings,
            to: ManagedGraph(edited, catalog: app.catalog).settings)
        app.generation.applyGraph(changes, app) { saveStandard(state) }
    }

    /// The standard graph as a new workflow of the preset, for a change
    /// that has to be kept in one.
    private func saveStandard(_ state: GenerationModel.GraphState) -> UUID? {
        guard let preset = app.generation.preset(in: app.library) else { return nil }
        return app.workflows.save(state.doc, name: app.workflows.uniqueName(preset.name), presetID: preset.id)?.id
    }

    private var namingTitle: String {
        switch naming {
        case .rename?: "Rename the Workflow"
        default: "Save as Workflow"
        }
    }

    private func namingAction(_ naming: Naming) -> String {
        switch naming {
        case .new: "Save"
        case .rename: "Rename"
        }
    }

    private func finish(_ naming: Naming, state: GenerationModel.GraphState?) {
        switch naming {
        case .new:
            guard let state, let preset = app.generation.preset(in: app.library),
                let entry = app.workflows.save(state.doc, name: name, presetID: preset.id)
            else { return }
            app.generation.showWorkflow(entry.id, app)
        case .rename(let entry):
            app.workflows.rename(entry.id, to: name)
        }
    }
}

/// A change to the graph's structure, from the canvas.
enum StructureChange {
    /// `replacing`: the link it was dragged off.
    case connect(origin: Int, slot: Int, target: Int, input: Int, replacing: Int?)
    case disconnect(Int)
    /// A node of the server's at a point on the canvas.
    case add(String, CGPoint)
    case delete([Int])
    /// The document as changed by the canvas (pasted, duplicated, muted…).
    case document(WorkflowDocument, name: String)
}

/// A document's nodes and links. Click a node to select it (⇧ or ⌘ for
/// several) and drag to move them; drag the background to move the view,
/// pinch (or on the Mac, scroll the wheel) to zoom. Until then all of it is in view.
struct NodeCanvas: View {
    /// Nodes being dragged, and how far (canvas units).
    private struct NodeDrag {
        var nodes: Set<Int>
        var delta = CGSize.zero
    }

    let state: GenerationModel.GraphState
    let catalog: ComfyCatalog
    /// The node running now, when generating through the graph.
    var running: Int?
    /// What the server said about which node in the last run.
    var errors: [Int: String] = [:]
    /// The document with nodes moved, once a drag ends.
    var onMove: (WorkflowDocument) -> Void = { _ in }
    /// A widget's new value: node, input, value.
    var onEdit: (Int, String, JSONValue) -> Void = { _, _, _ in }
    /// Nodes added, deleted or linked.
    var onStructure: (StructureChange) -> Void = { _ in }

    /// A link being drawn from an output, or pulled off an input.
    private struct LinkDrag {
        var origin: Int
        var slot: Int
        var type: String
        /// The link pulled off, if it was one.
        var replacing: Int?
        /// The pointer, on the canvas.
        var point: CGPoint
    }

    private struct GroupDrag {
        var id: Int
        var nodes: Set<Int>
        var reroutes: Set<Int>
        var delta = CGSize.zero
    }

    /// Where a node is to be added.
    private struct AddRequest: Identifiable {
        let id = UUID()
        var point: CGPoint
    }

    /// `nil`: fitted to the view.
    @State private var viewport: NodeViewport?
    @State private var panStart: NodeViewport?
    @State private var zoomStart: NodeViewport?
    @State private var selection: Set<Int> = []
    @State private var nodeDrag: NodeDrag?
    /// The widget being edited, over its row.
    @State private var editing: RowEdit.Target?
    @State private var linkDrag: LinkDrag?
    /// A group being dragged by its title, with what it takes along.
    @State private var groupDrag: GroupDrag?
    @State private var selectedGroup: Int?
    /// A group being renamed, and the name typed.
    @State private var renamingGroup: Int?
    @State private var groupTitle = ""
    @State private var adding: AddRequest?
    /// Why something was refused, shown for a moment.
    @State private var hint: String?
    @FocusState private var focused: Bool

    /// The document as shown: with the nodes being dragged where they are now.
    private var doc: WorkflowDocument {
        if let drag = groupDrag {
            return NodeEditing.movedGroup(
                state.doc, drag.id, nodes: drag.nodes, reroutes: drag.reroutes, by: drag.delta)
        }
        return nodeDrag.map { NodeEditing.moved(state.doc, $0.nodes, by: $0.delta) } ?? state.doc
    }

    /// ⇧ or ⌘ held: a click adds to the selection.
    private var extendsSelection: Bool {
        #if os(macOS)
            !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty
        #else
            false
        #endif
    }

    var body: some View {
        let doc = doc
        let layouts = Dictionary(
            doc.graph.nodes.map { ($0.id, NodeLayout($0, spec: catalog.nodes[$0.type])) },
            uniquingKeysWith: { a, _ in a })
        let roles = doc.roles
        let bounds = layouts.values.reduce(CGRect.null) { $0.union($1.bounds) }
        GeometryReader { geometry in
            let size = geometry.size
            let shown = viewport ?? NodeViewport.fit(bounds, in: size)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(NodeColors.canvas))
                context.translateBy(x: shown.offset.x, y: shown.offset.y)
                context.scaleBy(x: shown.scale, y: shown.scale)
                // Only what is in view.
                let seen = CGRect(
                    origin: shown.toCanvas(.zero),
                    size: CGSize(width: size.width / shown.scale, height: size.height / shown.scale))
                for group in doc.graph.groups { draw(group, selected: group.id == selectedGroup, in: context) }
                for link in doc.graph.links where link.id != linkDrag?.replacing {
                    draw(link, layouts, through: NodeEditing.reroutePoints(link, in: doc.graph), in: context)
                }
                for reroute in doc.graph.reroutes {
                    let p = reroute.position
                    context.fill(
                        Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                        with: .color(NodeColors.label))
                }
                for node in doc.graph.nodes {
                    guard let layout = layouts[node.id], layout.bounds.intersects(seen) else { continue }
                    draw(node, layout, role: roles[node.id], in: context)
                    if selection.contains(node.id) {
                        context.stroke(
                            Path(roundedRect: layout.bounds.insetBy(dx: -3, dy: -3), cornerRadius: 10),
                            with: .color(NodeColors.selection), lineWidth: 2 / shown.scale)
                    }
                    if node.id == running {
                        context.stroke(
                            Path(roundedRect: layout.bounds.insetBy(dx: -6, dy: -6), cornerRadius: 12),
                            with: .color(NodeColors.running), lineWidth: 3 / shown.scale)
                    }
                    if let message = errors[node.id] {
                        context.stroke(
                            Path(roundedRect: layout.bounds.insetBy(dx: -6, dy: -6), cornerRadius: 12),
                            with: .color(NodeColors.error), lineWidth: 3 / shown.scale)
                        // The server's words under the node.
                        context.draw(
                            Text(message).font(.system(size: 12)).foregroundStyle(NodeColors.error),
                            in: CGRect(
                                x: layout.bounds.minX, y: layout.bounds.maxY + 10, width: layout.bounds.width,
                                height: 120))
                    }
                }
                if let drag = linkDrag, let outputs = layouts[drag.origin]?.outputPoints,
                    outputs.indices.contains(drag.slot)
                {
                    let from = outputs[drag.slot]
                    // The inputs it fits into, then the link to the pointer.
                    for node in doc.graph.nodes where node.id != drag.origin {
                        guard let points = layouts[node.id]?.inputPoints else { continue }
                        for (i, input) in node.inputs.enumerated()
                        where i < points.count && NodeGraph.accepts(input.type, from: drag.type) {
                            let p = points[i]
                            context.stroke(
                                Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                                with: .color(NodeColors.selection), lineWidth: 2 / shown.scale)
                        }
                    }
                    context.stroke(curve(from, drag.point), with: .color(NodeColors.type(drag.type)), lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            // A drag on a node moves it (with the selection); on the background it moves the view.
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if panStart == nil, nodeDrag == nil, linkDrag == nil {
                            let start = shown.toCanvas(value.startLocation)
                            if let socket = socketDrag(at: start, doc, layouts, roles) {
                                // A socket: draw (or pull off) a link. Hold the view still.
                                viewport = shown
                                linkDrag = socket
                            } else if let hit = NodeEditing.node(at: start, in: doc.graph.nodes, layouts: layouts) {
                                if !selection.contains(hit) {
                                    selection = NodeEditing.select(hit, in: selection, extend: extendsSelection)
                                }
                                // Hold the view still while the graph's bounds change.
                                viewport = shown
                                nodeDrag = NodeDrag(nodes: NodeEditing.dragged(hit, selection: selection))
                            } else if let group = NodeEditing.group(at: start, in: doc) {
                                // A group's title: the group and what is inside it move.
                                let inside = NodeEditing.groupContents(group, in: doc)
                                viewport = shown
                                selectedGroup = group
                                groupDrag = GroupDrag(id: group, nodes: inside.nodes, reroutes: inside.reroutes)
                            } else {
                                panStart = shown
                            }
                        }
                        if linkDrag != nil {
                            linkDrag?.point = shown.toCanvas(value.location)
                        } else if groupDrag != nil {
                            groupDrag?.delta = CGSize(
                                width: value.translation.width / shown.scale,
                                height: value.translation.height / shown.scale)
                        } else if nodeDrag != nil {
                            nodeDrag?.delta = CGSize(
                                width: value.translation.width / shown.scale,
                                height: value.translation.height / shown.scale)
                        } else if let start = panStart {
                            viewport = start.panned(by: value.translation)
                        }
                    }
                    .onEnded { _ in
                        if let drag = linkDrag {
                            dropLink(drag, doc, layouts)
                        } else if let drag = groupDrag, drag.delta != .zero {
                            onMove(
                                NodeEditing.movedGroup(
                                    state.doc, drag.id, nodes: drag.nodes, reroutes: drag.reroutes, by: drag.delta))
                        } else if let drag = nodeDrag, drag.delta != .zero {
                            onMove(NodeEditing.moved(state.doc, drag.nodes, by: drag.delta))
                        }
                        linkDrag = nil
                        groupDrag = nil
                        nodeDrag = nil
                        panStart = nil
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { tap in
                        let point = shown.toCanvas(tap.location)
                        let hit = NodeEditing.node(at: point, in: doc.graph.nodes, layouts: layouts)
                        focused = true
                        selection = NodeEditing.select(hit, in: selection, extend: extendsSelection)
                        // A group is selected by its title, alone.
                        selectedGroup = hit == nil ? NodeEditing.group(at: point, in: doc) : nil
                        if selectedGroup != nil { selection = [] }
                        if let hit, let node = doc.graph.node(hit), let layout = layouts[hit] {
                            editing = RowEdit.target(node, layout, role: roles[hit], at: point, catalog: catalog)
                        }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { tap in
                        let point = shown.toCanvas(tap.location)
                        guard NodeEditing.node(at: point, in: doc.graph.nodes, layouts: layouts) == nil else { return }
                        if let group = NodeEditing.group(at: point, in: doc) {
                            groupTitle = doc.graph.groups.first { $0.id == group }?.title ?? ""
                            renamingGroup = group
                        } else {
                            adding = AddRequest(point: point)
                        }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = zoomStart ?? shown
                        zoomStart = start
                        viewport = start.zoomed(by: value.magnification, around: value.startLocation)
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            #if os(macOS)
                .background {
                    ScrollCatcher { scroll in
                        let current = viewport ?? NodeViewport.fit(bounds, in: size)
                        if scroll.isPrecise && !scroll.command {
                            // Trackpad: two fingers move the canvas.
                            viewport = current.panned(by: scroll.delta)
                        } else {
                            // Wheel notches (or ⌘ + trackpad) zoom under the pointer.
                            let amount = scroll.isPrecise ? scroll.delta.height / 100 : scroll.delta.height / 10
                            viewport = current.zoomed(by: pow(2, amount), around: scroll.location)
                        }
                    }
                }
            #endif
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            #if os(macOS)
                .onDeleteCommand {
                    if let group = selectedGroup, selection.isEmpty {
                        deleteGroup(group, doc)
                    } else {
                        deleteSelection(doc)
                    }
                }
                .onCopyCommand { copySelection(doc) }
                .onPasteCommand(of: [.json, .plainText, .utf8PlainText]) { providers in paste(providers, into: doc) }
            #endif
            .onKeyPress(phases: .down) { press in
                // ⌘D duplicates; ⌃M mutes and ⌃B bypasses, as in ComfyUI (⌘M minimizes the window).
                switch (press.characters.lowercased(), press.modifiers) {
                case ("d", .command): duplicateSelection(doc)
                case ("g", .command): groupSelection(doc, layouts)
                case ("m", .control): mode(.never, doc)
                case ("b", .control): mode(.bypass, doc)
                default: return .ignored
                }
                return .handled
            }
            .overlay(alignment: .bottomTrailing) { controls(shown, size: size, doc: doc, layouts: layouts) }
            .overlay(alignment: .top) {
                if let hint {
                    Text(hint)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                        .transition(.opacity)
                        .task(id: hint) {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { self.hint = nil }
                        }
                }
            }
            .alert(
                "Rename the Group",
                isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })
            ) {
                TextField("Title", text: $groupTitle)
                Button("Rename") { renameGroup(doc) }.keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $adding) { request in
                NodePicker(catalog: catalog) { type in
                    adding = nil
                    onStructure(.add(type, request.point))
                }
            }
            .overlay(alignment: .topLeading) {
                if let target = editing,
                    let row = layouts[target.node]?.rows.first(where: {
                        $0.name == target.input && $0.kind == .value
                    })
                {
                    // Over the row, as drawn: inset, then into the view.
                    let r = row.rect.insetBy(dx: 12, dy: 0)
                    let origin = shown.toView(r.origin)
                    RowEditor(target: target) { value in
                        editing = nil
                        if let value { onEdit(target.node, target.input, value) }
                    }
                    .frame(width: max(r.width * shown.scale, 140), height: max(r.height * shown.scale, 24))
                    .offset(x: origin.x, y: origin.y)
                    .id(target)
                }
            }
        }
    }

    private func controls(
        _ shown: NodeViewport, size: CGSize, doc: WorkflowDocument, layouts: [Int: NodeLayout]
    ) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 2) {
            Button("Add Node", systemImage: "plus") { adding = AddRequest(point: shown.toCanvas(center)) }
                .help("Add a node of the server's (or double-click the background)")
            Button("Delete", systemImage: "trash") { deleteSelection(doc) }
                .help("Delete the selected nodes you added")
                .disabled(!selection.contains { NodeEditing.canDelete($0, in: doc) })
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Duplicate", systemImage: "plus.square.on.square") { duplicateSelection(doc) }
                Button("Mute", systemImage: "speaker.slash") { mode(.never, doc) }
                Button("Bypass", systemImage: "arrow.uturn.forward") { mode(.bypass, doc) }
                Divider()
                Button("Group", systemImage: "rectangle.dashed") { groupSelection(doc, layouts) }
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(selection.isEmpty)
            .help("Duplicate (⌘D), mute (⌃M), bypass (⌃B) or group (⌘G) the selected nodes")
            Divider().frame(height: 16)
            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                viewport = shown.zoomed(by: 1 / 1.25, around: center)
            }
            Text(shown.scale.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().frame(minWidth: 44)
            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                viewport = shown.zoomed(by: 1.25, around: center)
            }
            Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") { viewport = nil }
                .help("Show the whole graph")
                .disabled(viewport == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    /// A link, through its reroutes if it has any.
    private func draw(
        _ link: GraphLink, _ layouts: [Int: NodeLayout], through reroutes: [CGPoint], in context: GraphicsContext
    ) {
        guard let from = layouts[link.origin]?.outputPoints, from.indices.contains(link.originSlot),
            let to = layouts[link.target]?.inputPoints, to.indices.contains(link.targetSlot)
        else { return }
        let points = [from[link.originSlot]] + reroutes + [to[link.targetSlot]]
        for (a, b) in zip(points, points.dropFirst()) {
            context.stroke(curve(a, b), with: .color(NodeColors.type(link.type)), lineWidth: 3)
        }
    }

    /// A group: a tinted frame with its title, behind the nodes.
    private func draw(_ group: GraphGroup, selected: Bool, in context: GraphicsContext) {
        let color = NodeColors.group(group.color)
        let frame = Path(roundedRect: group.frame, cornerRadius: 6)
        context.fill(frame, with: .color(color.opacity(0.22)))
        context.stroke(frame, with: .color(selected ? NodeColors.selection : color.opacity(0.6)), lineWidth: 2)
        let size = group.fontSize ?? 24
        context.draw(
            Text(group.title).font(.system(size: size)).foregroundStyle(NodeColors.text),
            at: CGPoint(x: group.frame.minX + 10, y: group.frame.minY + NodeEditing.groupTitleHeight(group) / 2),
            anchor: .leading)
    }

    /// A group around the selected nodes, to be named.
    private func groupSelection(_ doc: WorkflowDocument, _ layouts: [Int: NodeLayout]) {
        let bounds = selection.compactMap { layouts[$0]?.bounds }.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return }
        let (changed, id) = NodeEditing.grouping(doc, around: bounds, title: "Group")
        onStructure(.document(changed, name: "Group Nodes"))
        selection = []
        selectedGroup = id
        groupTitle = "Group"
        renamingGroup = id
    }

    private func renameGroup(_ doc: WorkflowDocument) {
        guard let id = renamingGroup else { return }
        let title = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = doc
        for i in changed.graph.groups.indices where changed.graph.groups[i].id == id && !title.isEmpty {
            changed.graph.groups[i].title = title
        }
        onStructure(.document(changed, name: "Rename Group"))
        renamingGroup = nil
    }

    /// The group goes; its nodes stay.
    private func deleteGroup(_ id: Int, _ doc: WorkflowDocument) {
        var changed = doc
        changed.graph.groups.removeAll { $0.id == id }
        onStructure(.document(changed, name: "Delete Group"))
        selectedGroup = nil
    }

    /// LiteGraph's curve: handles a quarter of the distance long, level.
    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        let handle = hypot(b.x - a.x, b.y - a.y) * 0.25
        var path = Path()
        path.move(to: a)
        path.addCurve(
            to: b, control1: CGPoint(x: a.x + handle, y: a.y), control2: CGPoint(x: b.x - handle, y: b.y))
        return path
    }

    /// A drag starting on an output draws a link; on a linked input it
    /// pulls the link off, unless Lightbox makes that link.
    private func socketDrag(
        at point: CGPoint, _ doc: WorkflowDocument, _ layouts: [Int: NodeLayout], _ roles: [Int: NodeRole]
    ) -> LinkDrag? {
        for node in doc.graph.nodes.reversed() {
            guard let hit = layouts[node.id]?.hit(point) else { continue }
            switch hit {
            case .output(let i):
                return LinkDrag(origin: node.id, slot: i, type: node.outputs[i].type, replacing: nil, point: point)
            case .input(let i):
                guard let id = node.inputs[i].link, let link = doc.graph.link(id) else { return nil }
                if roles[link.origin] != nil, roles[node.id] != nil {
                    hint = "Lightbox links its own nodes; change them in the Generate panel."
                    return nil
                }
                return LinkDrag(
                    origin: link.origin, slot: link.originSlot, type: link.type, replacing: id, point: point)
            default:
                return nil
            }
        }
        return nil
    }

    /// The link drawn ends on an input: connect it if it fits. A link pulled
    /// off and dropped elsewhere is gone.
    private func dropLink(_ drag: LinkDrag, _ doc: WorkflowDocument, _ layouts: [Int: NodeLayout]) {
        for node in doc.graph.nodes.reversed() {
            guard case .input(let i)? = layouts[node.id]?.hit(drag.point) else { continue }
            if let problem = NodeEditing.linkProblem(doc, from: drag.origin, drag.slot, to: node.id, i) {
                withAnimation { hint = problem }
            } else {
                onStructure(
                    .connect(origin: drag.origin, slot: drag.slot, target: node.id, input: i, replacing: drag.replacing)
                )
            }
            return
        }
        if let id = drag.replacing { onStructure(.disconnect(id)) }
    }

    private func duplicateSelection(_ doc: WorkflowDocument) {
        guard let clip = NodeEditing.clipboard(selection, from: doc) else { return ownOnly() }
        let (changed, ids) = NodeEditing.pasted(clip, into: doc, offset: CGVector(dx: 40, dy: 40))
        onStructure(.document(changed, name: "Duplicate"))
        selection = Set(ids)
    }

    private func mode(_ mode: NodeMode, _ doc: WorkflowDocument) {
        guard !NodeEditing.ownNodes(selection, in: doc).isEmpty else { return ownOnly() }
        onStructure(.document(NodeEditing.toggled(mode, selection, in: doc), name: mode == .never ? "Mute" : "Bypass"))
    }

    private func ownOnly() {
        withAnimation { hint = "Only nodes you added can be copied, muted or bypassed." }
    }

    #if os(macOS)
        private func copySelection(_ doc: WorkflowDocument) -> [NSItemProvider] {
            guard let clip = NodeEditing.clipboard(selection, from: doc), let data = try? clip.data(),
                let text = String(data: data, encoding: .utf8)
            else { return [] }
            return [NSItemProvider(object: text as NSString)]
        }

        private func paste(_ providers: [NSItemProvider], into doc: WorkflowDocument) {
            for provider in providers {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, let clip = try? WorkflowDocument(data: Data(text.utf8)) else { return }
                    Task { @MainActor in
                        let (changed, ids) = NodeEditing.pasted(clip, into: doc, offset: CGVector(dx: 40, dy: 40))
                        onStructure(.document(changed, name: "Paste"))
                        selection = Set(ids)
                    }
                }
            }
        }
    #endif

    /// Delete the selected nodes: added ones go, Lightbox's switch their
    /// setting off (a LoRA, a fix, a guide), the required ones stay.
    private func deleteSelection(_ doc: WorkflowDocument) {
        let deletable = selection.filter { NodeEditing.canDelete($0, in: doc) }
        if deletable.count < selection.count {
            withAnimation { hint = "The loaders, prompts, sampler and output stay; the graph can't work without them." }
        }
        guard !deletable.isEmpty else { return }
        onStructure(.delete(Array(deletable)))
        selection.subtract(deletable)
    }

    private func draw(_ node: GraphNode, _ layout: NodeLayout, role: NodeRole?, in context: GraphicsContext) {
        let corner = 8.0
        // Muted nodes faded, bypassed ones tinted, as ComfyUI draws them.
        var context = context
        if node.mode == .never { context.opacity = 0.4 }
        context.fill(Path(roundedRect: layout.bounds, cornerRadius: corner), with: .color(NodeColors.body))
        if node.mode == .bypass {
            context.fill(
                Path(roundedRect: layout.bounds, cornerRadius: corner), with: .color(NodeColors.bypass.opacity(0.35)))
        }
        let title = UnevenRoundedRectangle(
            topLeadingRadius: corner, bottomLeadingRadius: node.collapsed ? corner : 0,
            bottomTrailingRadius: node.collapsed ? corner : 0, topTrailingRadius: corner)
        context.fill(title.path(in: layout.titleRect), with: .color(NodeColors.title))
        let name = node.title ?? catalog.nodes[node.type]?.displayName ?? node.type
        context.draw(
            Text(name).font(.system(size: 14)).foregroundStyle(NodeColors.text),
            at: CGPoint(x: layout.titleRect.minX + 12, y: layout.titleRect.midY), anchor: .leading)
        guard !node.collapsed else { return }

        let spec = catalog.nodes[node.type]
        for row in layout.rows { draw(row, of: node, spec: spec, role: role, in: context) }
        // Sockets of widgets show only when something is linked in.
        let rowNames = Set(layout.rows.map(\.name))
        for (i, input) in node.inputs.enumerated() where i < layout.inputPoints.count {
            let onRow = rowNames.contains(input.widget ?? input.name)
            if onRow && input.link == nil { continue }
            socket(layout.inputPoints[i], type: input.type, linked: input.link != nil, in: context)
            if !onRow {
                context.draw(
                    Text(input.label ?? input.name).font(.system(size: 11)).foregroundStyle(NodeColors.label),
                    at: CGPoint(x: layout.inputPoints[i].x + 10, y: layout.inputPoints[i].y), anchor: .leading)
            }
        }
        for (i, output) in node.outputs.enumerated() where i < layout.outputPoints.count {
            socket(layout.outputPoints[i], type: output.type, linked: !output.links.isEmpty, in: context)
            context.draw(
                Text(output.label ?? output.name).font(.system(size: 11)).foregroundStyle(NodeColors.label),
                at: CGPoint(x: layout.outputPoints[i].x - 10, y: layout.outputPoints[i].y), anchor: .trailing)
        }
    }

    private func draw(
        _ row: NodeLayout.Row, of node: GraphNode, spec: NodeSpec?, role: NodeRole?, in context: GraphicsContext
    ) {
        let rect = row.rect.insetBy(dx: 12, dy: 0)
        context.fill(
            Path(roundedRect: rect, cornerRadius: row.multiline ? 6 : rect.height / 2), with: .color(NodeColors.widget))
        let locked = row.kind == .value && NodeRowText.isLocked(role, input: row.name)
        let inset = rect.insetBy(dx: 10, dy: 0)
        if locked {
            var lock = context.resolve(Image(systemName: "lock.fill"))
            lock.shading = .color(NodeColors.label)
            let at = row.multiline ? CGPoint(x: inset.maxX, y: rect.minY + 10) : CGPoint(x: inset.maxX, y: rect.midY)
            context.draw(lock, in: CGRect(x: at.x - 9, y: at.y - 5, width: 9, height: 10))
        }
        let name = row.kind == .control ? "control after generate" : row.name
        let value: String
        if row.kind == .control {
            value = node.controlValue(row.name, spec: spec) ?? "—"
        } else if state.randomSeed && ["seed", "noise_seed"].contains(row.name) {
            value = "random"
        } else {
            value = NodeRowText.value(node.widgetValue(row.name, spec: spec))
        }
        let small = Font.system(size: 11)
        if row.multiline {
            context.draw(
                Text(name).font(small).foregroundStyle(NodeColors.label),
                at: CGPoint(x: inset.minX, y: rect.minY + 10), anchor: .leading)
            // The composed prompt, or why the guard refused it.
            let refused = state.refusal.flatMap { role?.kind == .positive ? $0 : nil }
            let text = Text(refused ?? (value.isEmpty ? "—" : value)).font(small)
                .foregroundStyle(refused == nil ? NodeColors.text : NodeColors.error)
            context.draw(
                text, in: CGRect(x: inset.minX, y: rect.minY + 20, width: inset.width, height: rect.height - 24))
        } else {
            // ComfyUI's row: the name on the left, the value on the right.
            let room = inset.width - (locked ? 14 : 0)
            let label = Self.fitted(name, width: room * 0.45, font: small, in: context)
            context.draw(
                Text(label).font(small).foregroundStyle(NodeColors.label),
                at: CGPoint(x: inset.minX, y: rect.midY), anchor: .leading)
            let shown = Self.fitted(value, width: room * 0.55 - 6, font: small, in: context)
            context.draw(
                Text(shown).font(small).foregroundStyle(NodeColors.text),
                at: CGPoint(x: inset.minX + room, y: rect.midY), anchor: .trailing)
        }
    }

    /// `text` shortened in the middle ("checkpo…v1.safetensors") to fit.
    static func fitted(_ text: String, width: Double, font: Font, in context: GraphicsContext) -> String {
        func fits(_ s: String) -> Bool {
            // No letter of the 11-point font is wider than 11 points: short texts need no measuring.
            if Double(s.count) * 11 <= width { return true }
            return context.resolve(Text(s).font(font)).measure(in: CGSize(width: CGFloat.infinity, height: 100)).width
                <= width
        }
        guard !fits(text) else { return text }
        func cut(_ keep: Int) -> String {
            let head = keep - keep / 2
            return String(text.prefix(head)) + "…" + String(text.suffix(keep / 2))
        }
        var (low, high) = (0, text.count - 1)
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(cut(mid)) { low = mid } else { high = mid - 1 }
        }
        return cut(low)
    }

    private func socket(_ p: CGPoint, type: String, linked: Bool, in context: GraphicsContext) {
        let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        if linked {
            context.fill(dot, with: .color(NodeColors.type(type)))
        } else {
            context.stroke(dot, with: .color(NodeColors.type(type)), lineWidth: 1.5)
        }
    }
}

/// ComfyUI's dark theme.
enum NodeColors {
    static let canvas = Color(hex: 0x202020)
    static let body = Color(hex: 0x353535)
    static let title = Color(hex: 0x222222)
    static let text = Color(hex: 0xdddddd)
    static let label = Color(hex: 0xaaaaaa)
    static let widget = Color(hex: 0x222222)
    static let error = Color(hex: 0xFF6E6E)
    static let selection = Color(hex: 0xFFFFFF)
    static let running = Color(hex: 0x00FF00)
    static let bypass = Color(hex: 0x9F40FF)

    /// A group's colour as ComfyUI stores it ("#3f789e", "#a1309b", …).
    static func group(_ hex: String?) -> Color {
        var s = (hex ?? "#3f789e").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return Color(hex: 0x3F789E) }
        return Color(hex: v)
    }

    /// ComfyUI's colours for link types.
    static func type(_ type: String) -> Color {
        switch type.split(separator: ",").first.map(String.init) ?? type {
        case "CLIP": Color(hex: 0xFFD500)
        case "CLIP_VISION": Color(hex: 0xA8DADC)
        case "CLIP_VISION_OUTPUT": Color(hex: 0xAD7452)
        case "CONDITIONING": Color(hex: 0xFFA931)
        case "CONTROL_NET": Color(hex: 0x6EE7B7)
        case "IMAGE": Color(hex: 0x64B5F6)
        case "LATENT": Color(hex: 0xFF9CF9)
        case "MASK": Color(hex: 0x81C784)
        case "MODEL": Color(hex: 0xB39DDB)
        case "VAE": Color(hex: 0xFF6E6E)
        case "NOISE": Color(hex: 0xB0B0B0)
        case "GUIDER": Color(hex: 0x66FFFF)
        case "SAMPLER": Color(hex: 0xECB4B4)
        case "SIGMAS": Color(hex: 0xCDFFCD)
        case "INT", "FLOAT", "BOOLEAN": Color(hex: 0x7F9FBF)
        case "STRING": Color(hex: 0x77BB77)
        default: Color(hex: 0x99AA99)
        }
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
}

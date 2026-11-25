import LightboxCore
import SwiftUI

/// The layers, top first, and the settings of the selected one; with no
/// layer selected, the canvas's.
struct ComposeSidePanel: View {
    @Bindable var doc: ComposeDocument
    /// Hides the panel; its button sits in the panel's own header.
    var close: (() -> Void)?
    @AppStorage(PanelKeys.generate) private var showGenerate = true
    @Environment(\.undoManager) private var undo

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                AddLayerMenu(doc: doc)
                    .labelStyle(.iconOnly)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .buttonStyle(.borderless)
                if let close {
                    PanelButton(title: "Hide the layers", systemImage: "square.3.layers.3d", action: close)
                }
                if !showGenerate {
                    // The Generate panel's button, where it was while open.
                    PanelButton(title: "Show the Generate panel", systemImage: "sidebar.trailing") {
                        showGenerate = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: PanelHeader.height)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            // ⌘- or ⇧-click selects several, to merge or delete them together.
            List(selection: Binding(get: { doc.selectedLayers }, set: { doc.selectLayers($0) })) {
                Section {
                    ForEach(doc.composition.layerList) { layer in
                        LayerRow(layer: layer, image: doc.images[layer.image]) {
                            doc.change(layer.visible ? "Hide Layer" : "Show Layer", undo: undo) {
                                $0.update(layer.id) { $0.visible.toggle() }
                            }
                        }
                        .tag(layer.id)
                        .contextMenu { rowMenu(layer) }
                    }
                    .onMove { from, to in
                        doc.change("Reorder Layers", undo: undo) { $0.moveLayers(fromOffsets: from, toOffset: to) }
                    }
                }
            }
            .frame(minHeight: 140, idealHeight: 240)
            .overlay {
                if doc.composition.layers.isEmpty {
                    Text(
                        "Add a layer with + above: an empty one, gallery pictures, or picture files. Files can also be dropped on the canvas."
                    )
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            Divider()
            Form {
                if doc.area != nil {
                    ModelEditSection(doc: doc, layer: nil)
                    InstructionSection(doc: doc)
                }
                if doc.selectedLayers.count > 1 {
                    SelectedLayersSection(doc: doc)
                } else if let layer = doc.selectedLayer {
                    LayerInspector(doc: doc, layer: layer)
                } else {
                    CanvasInspector(doc: doc)
                }
            }
            .formStyle(.grouped)
        }
    }
}

extension ComposeSidePanel {
    /// On a layer of a selection of several: merge or delete them all; on
    /// another layer: that layer.
    @ViewBuilder fileprivate func rowMenu(_ layer: CompositionLayer) -> some View {
        let several = doc.selectedLayers.count > 1 && doc.selectedLayers.contains(layer.id)
        if several {
            Button("Merge \(doc.selectedLayers.count) Layers", systemImage: "square.2.layers.3d.bottom.filled") {
                Task { await doc.mergeSelected(undo: undo) }
            }
            .disabled(!doc.canMergeSelected || doc.busy)
            Divider()
            Button("Delete \(doc.selectedLayers.count) Layers", systemImage: "trash", role: .destructive) {
                doc.removeSelectedLayers(undo: undo)
            }
        } else {
            Button("Center on Canvas", systemImage: "arrow.down.right.and.arrow.up.left") {
                doc.centerOnCanvas(layer.id, undo: undo)
            }
            Button("Fit to Canvas", systemImage: "rectangle.arrowtriangle.2.inward") {
                doc.place(layer.id, fill: false, undo: undo)
            }
            Divider()
            Button("Merge…", systemImage: "square.2.layers.3d.bottom.filled") {}
                .disabled(true)
                .help("Select the layers to merge first: ⌘- or ⇧-click them in the list")
            Divider()
            Button("Delete Layer", systemImage: "trash", role: .destructive) { doc.removeLayer(layer.id, undo: undo) }
        }
    }
}

/// Several layers selected: merge or delete them together.
private struct SelectedLayersSection: View {
    @Bindable var doc: ComposeDocument
    @Environment(\.undoManager) private var undo

    var body: some View {
        let count = doc.selectedLayers.count
        let hidden = count - doc.mergeable.count
        Section("\(count) Layers Selected") {
            Button("Merge Layers", systemImage: "square.2.layers.3d.bottom.filled") {
                Task { await doc.mergeSelected(undo: undo) }
            }
            .disabled(!doc.canMergeSelected || doc.busy)
            .keyboardShortcut("e", modifiers: .command)
            .help("Merge the selected layers into one, as they look now, in the lowest one's place (⌘E)")
            if hidden > 0 {
                Text(
                    hidden == 1
                        ? "One of them is hidden; it stays out of the merge."
                        : "\(hidden) of them are hidden; they stay out of the merge."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "The merged layer is drawn as the layers look (opacity and gray included), so the magic wand, the "
                    + "brush and Edit with Model work across it."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Delete Layers", systemImage: "trash", role: .destructive) { doc.removeSelectedLayers(undo: undo) }
            Button("Deselect") { doc.selectLayers([]) }
        }
    }
}

private struct LayerRow: View {
    let layer: CompositionLayer
    let image: CGImage?
    let toggleVisible: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(layer.visible ? "Hide" : "Show", systemImage: layer.visible ? "eye" : "eye.slash") {
                toggleVisible()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(layer.visible ? .primary : .tertiary)
            ZStack {
                Checkerboard()
                if let image { FittedImage(image: image) }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(layer.name).lineLimit(1)
                .foregroundStyle(layer.visible ? .primary : .secondary)
        }
    }
}

/// A slider that changes the composition live and makes one undo step
/// when let go.
private struct LiveSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let text: String
    let doc: ComposeDocument
    let set: (inout Composition, Double) -> Void
    @Environment(\.undoManager) private var undo
    @State private var before: Composition?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(
                        get: { value },
                        set: { v in
                            if before == nil { before = doc.composition }
                            doc.live { set(&$0, v) }
                        }),
                    in: range,
                    onEditingChanged: { editing in
                        guard !editing, let b = before else { return }
                        doc.commit(since: b, title, undo: undo)
                        before = nil
                    })
                Text(text).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct LayerInspector: View {
    @Bindable var doc: ComposeDocument
    let layer: CompositionLayer
    @Environment(\.undoManager) private var undo

    var body: some View {
        let id = layer.id
        Section("Layer") {
            TextField(
                "Name",
                text: Binding(
                    get: { layer.name },
                    set: { name in doc.change("Rename Layer", undo: nil) { $0.update(id) { $0.name = name } } }))
            LiveSlider(
                title: "Opacity", value: layer.opacity, range: 0...1, text: "\(Int((layer.opacity * 100).rounded())) %",
                doc: doc
            ) { c, v in c.update(id) { $0.opacity = v } }
            Toggle(
                "Grayscale",
                isOn: Binding(
                    get: { layer.grayscale },
                    set: { on in doc.change("Grayscale", undo: undo) { $0.update(id) { $0.grayscale = on } } }))
            Toggle(
                "Visible",
                isOn: Binding(
                    get: { layer.visible },
                    set: { on in
                        doc.change(on ? "Show Layer" : "Hide Layer", undo: undo) { $0.update(id) { $0.visible = on } }
                    }))
        }
        Section("Size and Position") {
            LiveSlider(
                title: "Size", value: layer.scale, range: 0.05...4, text: "\(Int((layer.scale * 100).rounded())) %",
                doc: doc
            ) { c, v in c.setScale(id, to: v) }
            LabeledContent("Frame") {
                Text(
                    "\(Int(layer.frame.width.rounded())) × \(Int(layer.frame.height.rounded())) at "
                        + "\(Int(layer.frame.x.rounded())), \(Int(layer.frame.y.rounded()))"
                )
                .monospacedDigit().foregroundStyle(.secondary)
            }
            if !doc.isOnCanvas(id) {
                Label("The layer is outside the canvas.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Center on Canvas", systemImage: "arrow.down.right.and.arrow.up.left") {
                    doc.centerOnCanvas(id, undo: undo)
                }
            }
            HStack {
                Button("Fit") { doc.place(id, fill: false, undo: undo) }
                    .help("Show all of the picture on the canvas")
                Button("Fill") { doc.place(id, fill: true, undo: undo) }
                    .help("Cover the whole canvas")
                Button("100 %") { doc.actualSize(id, undo: undo) }
                    .help("The picture's own size")
            }
            HStack {
                let i = doc.composition.layers.firstIndex { $0.id == id } ?? 0
                Button("Move Up", systemImage: "arrow.up") {
                    doc.change("Move Layer Up", undo: undo) { $0.moveLayer(id, by: 1) }
                }
                .disabled(i == doc.composition.layers.count - 1)
                Button("Move Down", systemImage: "arrow.down") {
                    doc.change("Move Layer Down", undo: undo) { $0.moveLayer(id, by: -1) }
                }
                .disabled(i == 0)
            }
        }
        ShadowSection(doc: doc, layer: layer)
        if doc.area == nil {
            ModelEditSection(doc: doc, layer: layer)
        }
        Section {
            Button("Remove Background", systemImage: "person.and.background.dotted") {
                Task { await doc.removeBackground(of: id, undo: undo) }
            }
            .disabled(doc.busy)
            .help("Cut out the people, animals or objects with Vision; the gallery picture stays as it is")
            Button("Delete Layer", systemImage: "trash", role: .destructive) { doc.removeLayer(id, undo: undo) }
            Button("Deselect") { doc.selection = nil }
                .help("Show the canvas settings")
        }
    }
}

private struct CanvasInspector: View {
    @Bindable var doc: ComposeDocument
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo

    var body: some View {
        let c = doc.composition
        if doc.area == nil { InstructionSection(doc: doc) }
        Section("Canvas") {
            TextField(
                "Name",
                text: Binding(get: { c.name }, set: { name in doc.change("Rename", undo: nil) { $0.name = name } }))
            // The format menu leads the row; a label beside it doesn't fit the panel.
            SizeFields(
                width: Binding(
                    get: { c.width },
                    set: { w in doc.change("Canvas Size", undo: undo) { $0.setCanvas(width: w, height: $0.height) } }),
                height: Binding(
                    get: { c.height },
                    set: { h in doc.change("Canvas Size", undo: undo) { $0.setCanvas(width: $0.width, height: h) } }),
                size: { $0.size(area: c.width * c.height, step: 8) }
            )
            .help("Canvas size")
            Button("Fit Canvas to Layers") {
                doc.change("Fit Canvas to Layers", undo: undo) { $0.fitCanvasToLayers() }
            }
            .disabled(!c.layers.contains(where: \.visible))
            .help("Crop or grow the canvas to just hold the visible layers")
            Picker(
                "Background",
                selection: Binding(
                    get: { c.background }, set: { b in doc.change("Background", undo: undo) { $0.background = b } })
            ) {
                ForEach(Composition.Background.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle(
                "Whole Picture in Gray",
                isOn: Binding(
                    get: { c.grayscale }, set: { on in doc.change("Grayscale", undo: undo) { $0.grayscale = on } }))
        }
        Section {
            Button("Save to Gallery", systemImage: "square.and.arrow.down.on.square") {
                Task { await doc.saveToGallery(rating: app.library.rating) }
            }
            .disabled(doc.busy || c.layers.isEmpty)
            .help("Add the picture to the gallery; each save adds a new one")
        }
    }
}

/// Paint the selected part of the layer again with a model (inpainting).
/// Painting with the model: the selected pixels of a layer (`layer`), or
/// with `layer` nil the area dragged with the area tool, across all layers.
struct ModelEditSection: View {
    @Bindable var doc: ComposeDocument
    let layer: CompositionLayer?
    /// Shown in the card over the canvas, with room for a longer prompt.
    var overCanvas = false
    @AppStorage(PanelKeys.modelEditOpen) private var openOverCanvas = false
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo

    private var title: String { layer == nil ? "Redraw Area" : "Edit with Model" }

    var body: some View {
        if openOverCanvas && !overCanvas {
            Section(title) {
                Label("Open over the canvas.", systemImage: "macwindow").foregroundStyle(.secondary)
                Button("Put Back in the Panel", systemImage: "arrow.down.right.and.arrow.up.left") {
                    withAnimation { openOverCanvas = false }
                }
            }
        } else {
            section
        }
    }

    private var section: some View {
        let preset = doc.editPreset(app)
        return Section {
            Picker(
                "Preset",
                selection: Binding(get: { preset?.id }, set: { doc.editPresetID = $0 })
            ) {
                ForEach(app.library.presets) { Text($0.name).tag(Optional($0.id)) }
            }
            PromptField(
                title: "What should be there", text: $doc.editPrompt,
                placeholder: preset?.dialect == .tags ? "red scarf, smiling" : "a red scarf around her neck",
                height: overCanvas ? 180 : 64)
            LabeledContent("Strength") {
                HStack {
                    Slider(value: $doc.editStrength, in: 0.2...1)
                    Text("\(Int((doc.editStrength * 100).rounded())) %").monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .help("How much the selected part may change: low keeps its shapes and colors, 100 % paints it anew")
            if doc.editing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(doc.editStatus).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { doc.cancelEdit() }
                }
            } else if layer == nil {
                Button("Redraw Area", systemImage: "paintbrush") { doc.redrawArea(app, undo: undo) }
                    .disabled(doc.busy || !app.isConnected)
                    .help(
                        app.isConnected
                            ? "Send this part of the whole picture to ComfyUI; the result becomes a new layer on top"
                            : "Needs the ComfyUI server")
                Text("The result goes on a new layer, so the layers below stay as they are; each try adds one.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Paint Selection Again", systemImage: "paintbrush") { doc.editWithModel(app, undo: undo) }
                    .disabled(!doc.hasMask || doc.busy || !app.isConnected)
                    .help(
                        !app.isConnected
                            ? "Needs the ComfyUI server"
                            : doc.hasMask
                                ? "Send the selected part to ComfyUI and put the result in its place"
                                : "Select a part first, with the magic wand or the brush")
                Text(
                    "Only the selected part of this layer changes. To redraw a part of the whole picture, use the "
                        + "area tool."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let edits = layer?.edits, !edits.isEmpty {
                Text(edits.count == 1 ? "Painted again once." : "Painted again \(edits.count) times.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button(
                    overCanvas ? "Put Back in the Panel" : "Open over the Canvas",
                    systemImage: overCanvas
                        ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                ) { withAnimation { openOverCanvas = !overCanvas } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(overCanvas ? "Put it back in the layer panel" : "Open it larger, over the canvas")
            }
        }
    }
}

/// A shadow from what the layer shows: dropped behind it, or cast on the ground.
private struct ShadowSection: View {
    @Bindable var doc: ComposeDocument
    let layer: CompositionLayer
    @Environment(\.undoManager) private var undo

    var body: some View {
        let id = layer.id
        Section("Shadow") {
            Picker(
                "Shadow",
                selection: Binding(
                    get: { layer.shadow?.style },
                    set: { style in
                        doc.change(style == nil ? "Remove Shadow" : "Shadow", undo: undo) {
                            $0.update(id) { $0.shadow = style.map(LayerShadow.init(style:)) }
                        }
                    })
            ) {
                Text("None").tag(LayerShadow.Style?.none)
                ForEach(LayerShadow.Style.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            if let shadow = layer.shadow {
                if shadow.style == .drop {
                    slider("Direction", \.angle, 0...360, "\(Int(shadow.angle))°", shadow)
                    slider("Distance", \.distance, 0...0.3, percent(shadow.distance), shadow)
                } else {
                    slider("Lean", \.angle, -70...70, "\(Int(shadow.angle))°", shadow)
                    slider("Length", \.distance, -1...1, percent(shadow.distance), shadow)
                }
                slider("Softness", \.blur, 0...0.1, percent(shadow.blur), shadow)
                slider("Opacity", \.opacity, 0...1, percent(shadow.opacity), shadow)
                Text(
                    shadow.style == .drop
                        ? "Made from what the layer shows: cut the subject out first (Remove Background or the magic wand)."
                        : "Lies on the ground from the layer's lowest visible point; negative lengths fall towards you. For a shadow that fits the scene, use Edit with Instruction."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func slider(
        _ title: String, _ key: WritableKeyPath<LayerShadow, Double>, _ range: ClosedRange<Double>, _ text: String,
        _ shadow: LayerShadow
    ) -> some View {
        let id = layer.id
        return LiveSlider(title: title, value: shadow[keyPath: key], range: range, text: text, doc: doc) { c, v in
            c.update(id) { $0.shadow?[keyPath: key] = v }
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
}

/// Changing the whole picture by instruction with Flux 2: a shadow or light
/// that fits the scene, a change of season, …
private struct InstructionSection: View {
    @Bindable var doc: ComposeDocument
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo

    var body: some View {
        let preset = doc.instructionPreset(app)
        Section("Edit with Instruction") {
            PromptField(
                title: "What should change", text: $doc.instruction,
                placeholder: "add a soft shadow of the woman on the floor, light from the window on the left",
                height: 64)
            if doc.area != nil {
                Toggle("Only inside the area", isOn: $doc.instructionInArea)
                    .help("Keep the rest of the picture exactly as it is")
            }
            if doc.editing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(doc.editStatus).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { doc.cancelEdit() }
                }
            } else {
                Button("Edit Picture", systemImage: "wand.and.stars") { doc.editWithInstruction(app, undo: undo) }
                    .disabled(doc.busy || !app.isConnected || preset == nil)
                    .help(
                        preset == nil
                            ? "Needs a Flux 2 (Klein) preset"
                            : "Send the whole picture to ComfyUI with this instruction; the result becomes a new layer")
            }
            Text(
                preset.map {
                    "With “\($0.name)”. The model sees the whole picture, so shadows and light fit the scene. The result is a new layer on top."
                } ?? "Needs a Flux 2 (Klein) preset."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

import ComfyKit
import LightboxCore
import SwiftUI

/// What a node needs from the canvas: its drags go there, in canvas
/// ("canvas" coordinate space) points.
struct NodeActions {
    var select: (_ id: Int, _ extend: Bool) -> Void
    var move: (_ id: Int, _ translation: CGSize) -> Void
    var endMove: () -> Void
    var resize: (_ id: Int, _ translation: CGSize) -> Void
    var endResize: () -> Void
    /// A drag started on a socket: output (`isOutput`) or input.
    var dragSocket: (_ id: Int, _ slot: Int, _ isOutput: Bool, _ location: CGPoint) -> Void
    var endSocket: (_ location: CGPoint) -> Void
    var open: (_ id: Int) -> Void
}

/// One node, drawn at its layout's bounds (title bar included).
struct NodeView: View {
    let node: GraphNode
    let layout: NodeLayout
    let kind: NodeKind
    let selected: Bool
    let actions: NodeActions
    @Bindable var editor: NodeEditorModel
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undo
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var pickingFromGallery = false
    @State private var importingFile = false

    private var origin: CGPoint { layout.bounds.origin }
    private var path: NodePath { editor.nodePath(node.id) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if node.type == "Reroute" {
                reroute
            } else {
                chrome
                if !node.collapsed {
                    slots
                    widgets
                }
            }
            sockets
        }
        .frame(width: layout.bounds.width, height: layout.bounds.height, alignment: .topLeading)
        .opacity(node.mode == .never ? 0.45 : 1)
        .overlay(alignment: .topLeading) { errors }
        .contextMenu { menu }
        .alert("Rename Node", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                let t = newTitle.trimmingCharacters(in: .whitespaces)
                editor.edit([node.id], "Rename Node", undo: undo) { $0.title = t.isEmpty ? nil : t }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $pickingFromGallery) {
            PicturePicker(single: true) { ids in
                guard let id = ids.first, let data = try? Data(contentsOf: app.gallery.store.imageURL(id)) else {
                    return
                }
                editor.useImage(
                    data, filename: "lightbox-\(id.uuidString.prefix(8))", node: node.id, kind: kind,
                    client: app.client,
                    undo: undo)
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, let data = try? readPickedFile(url) else { return }
            editor.useImage(
                data, filename: url.lastPathComponent, node: node.id, kind: kind, client: app.client, undo: undo)
        }
    }

    // MARK: - Chrome

    private var title: String {
        if let t = node.title { return t }
        switch kind.role {
        case .regular(let spec): return spec.displayName ?? node.type
        case .subgraph(let def): return def.name
        case .note: return node.type == "MarkdownNote" ? "Markdown Note" : "Note"
        case .primitive: return "Primitive"
        default: return node.type
        }
    }

    private var titleColor: Color {
        if node.mode == .bypass { return NodeColors.bypass.opacity(0.8) }
        if case .missing = kind.role { return Color(hex: "#a33") }
        return node.color.map(Color.init(hex:)) ?? NodeColors.title
    }

    private var bodyColor: Color {
        if node.mode == .bypass { return NodeColors.bypass.opacity(0.35) }
        return node.bgcolor.map(Color.init(hex:)) ?? NodeColors.body
    }

    private var border: (Color, Double)? {
        if editor.nodeErrors[path] != nil { return (NodeColors.error, 3) }
        if editor.executing == path { return (NodeColors.running, 3) }
        if selected { return (NodeColors.selection, 2) }
        return nil
    }

    private var chrome: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#999")).frame(width: 8, height: 8)
                    .onTapGesture { editor.edit([node.id], "Collapse", undo: undo) { $0.collapsed.toggle() } }
                Text(title).font(.system(size: 13)).foregroundStyle(NodeColors.text).lineLimit(1)
                Spacer(minLength: 0)
                if case .subgraph = kind.role {
                    Image(systemName: "square.on.square").font(.caption).foregroundStyle(.secondary)
                }
                if editor.done.contains(path), editor.isRunning {
                    Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: NodeLayout.title)
            .background(titleColor)
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .simultaneousGesture(TapGesture(count: 2).onEnded { doubleClick() })
            .simultaneousGesture(TapGesture().onEnded { actions.select(node.id, Self.extendSelection) })
            .overlay(alignment: .bottom) {
                if editor.executing == path, editor.totalSteps > 0 {
                    GeometryReader { g in
                        Rectangle().fill(NodeColors.running)
                            .frame(width: g.size.width * Double(editor.step) / Double(max(editor.totalSteps, 1)))
                    }
                    .frame(height: 3)
                }
            }
            if !node.collapsed {
                bodyColor
                    .contentShape(Rectangle())
                    .onTapGesture { actions.select(node.id, Self.extendSelection) }
            }
        }
        .clipShape(shape)
        .overlay {
            if let (color, width) = border { shape.stroke(color, lineWidth: width) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !node.collapsed {
                Image(systemName: "line.diagonal")
                    .rotationEffect(.degrees(-90))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                            .onChanged { actions.resize(node.id, $0.translation) }
                            .onEnded { _ in actions.endResize() })
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    private var reroute: some View {
        Capsule()
            .fill(NodeColors.body)
            .overlay(Capsule().stroke(selected ? NodeColors.selection : Color(hex: "#555"), lineWidth: 1.5))
            .frame(width: layout.titleRect.width, height: 22)
            .offset(y: (NodeLayout.title - 22) / 2)
            .contentShape(Capsule())
            .gesture(moveGesture)
            .simultaneousGesture(TapGesture().onEnded { actions.select(node.id, Self.extendSelection) })
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { actions.move(node.id, $0.translation) }
            .onEnded { _ in actions.endMove() }
    }

    private func doubleClick() {
        if case .subgraph = kind.role {
            actions.open(node.id)
        } else {
            newTitle = title
            renaming = true
        }
    }

    static var extendSelection: Bool {
        #if os(macOS)
            NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
        #else
            false
        #endif
    }

    // MARK: - Slots

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }

    /// Labels of sockets without a widget, and of the outputs.
    private var slots: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(node.inputs.enumerated()), id: \.offset) { i, input in
                if let p = layout.inputPoints[i], kind.widgetName(for: input) == nil {
                    Text(input.label ?? input.name)
                        .font(.system(size: 11)).foregroundStyle(Color(hex: "#aaa")).lineLimit(1)
                        .frame(width: layout.frame.width / 2 - 14, alignment: .leading)
                        .offset(x: local(p).x + 12, y: local(p).y - 7)
                }
            }
            ForEach(Array(node.outputs.enumerated()), id: \.offset) { i, output in
                let p = local(layout.outputPoints[i])
                Text(output.label ?? output.name)
                    .font(.system(size: 11)).foregroundStyle(Color(hex: "#aaa")).lineLimit(1)
                    .frame(width: layout.frame.width / 2 - 14, alignment: .trailing)
                    .offset(x: p.x - layout.frame.width / 2 + 2, y: p.y - 7)
            }
        }
        .allowsHitTesting(false)
    }

    private var sockets: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(node.inputs.enumerated()), id: \.offset) { i, input in
                if let p = layout.inputPoints[i] {
                    socket(type: input.type, linked: input.link != nil, at: local(p), slot: i, isOutput: false)
                        .opacity(input.widget != nil && input.link == nil && !node.collapsed ? 0.35 : 1)
                }
            }
            ForEach(Array(node.outputs.enumerated()), id: \.offset) { i, output in
                socket(
                    type: output.type, linked: !output.links.isEmpty, at: local(layout.outputPoints[i]), slot: i,
                    isOutput: true)
            }
        }
    }

    private func socket(type: String, linked: Bool, at p: CGPoint, slot: Int, isOutput: Bool) -> some View {
        let color = NodeColors.type(type)
        return ZStack {
            Circle().fill(linked ? color : Color.clear)
            Circle().stroke(color, lineWidth: 1.5)
        }
        .frame(width: 10, height: 10)
        .frame(width: 20, height: 20)
        .contentShape(Circle())
        .offset(x: p.x - 10, y: p.y - 10)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { actions.dragSocket(node.id, slot, isOutput, $0.location) }
                .onEnded { actions.endSocket($0.location) }
        )
        .help(type)
    }

    // MARK: - Widgets

    private var widgets: some View {
        ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, entry in
            let rect = entry.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            Group {
                switch entry.row {
                case .widget(let name, let input, let multiline):
                    widgetRow(name: name, input: input, multiline: multiline)
                case .images:
                    images
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
    }

    @ViewBuilder
    private func widgetRow(name: String, input: Int?, multiline: Bool) -> some View {
        let linked = input.flatMap { node.inputs[$0].link } != nil
        if let w = kind.widgets.first(where: { $0.name == name }) {
            Group {
                if linked {
                    HStack {
                        Text(name).foregroundStyle(.secondary)
                        Spacer()
                        Text("linked").foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .widgetBackground()
                } else if multiline {
                    TextWidget(value: stringValue(name), multiline: true) {
                        editor.setValue(node.id, name, .string($0), kind: kind, undo: undo)
                    }
                } else {
                    ValueWidget(
                        name: name, spec: w.spec, value: editor.value(node, name, kind: kind),
                        control: controlBinding(name, spec: w.spec), readOnly: editor.isReadOnly
                    ) { editor.setValue(node.id, name, $0, kind: kind, undo: undo) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, multiline ? 4 : 2)
        }
    }

    private func stringValue(_ name: String) -> String {
        editor.value(node, name, kind: kind)?.string ?? ""
    }

    private func controlBinding(_ name: String, spec: InputSpec) -> Binding<String>? {
        guard spec.controlAfterGenerate || (kindIsPrimitive && spec.type == "INT") else { return nil }
        return Binding(
            get: {
                if kindIsPrimitive, let a = node.widgetsValues?.array, a.count > 1 { return a[1].string ?? "fixed" }
                if kindIsPrimitive { return "fixed" }
                return node.controlValue(name, spec: kind.spec) ?? "fixed"
            },
            set: { editor.setControl(node.id, name, $0, kind: kind, undo: undo) })
    }

    private var kindIsPrimitive: Bool {
        if case .primitive = kind.role { true } else { false }
    }

    // MARK: - Pictures

    @ViewBuilder
    private var images: some View {
        let shown = editor.outputs[path] ?? []
        let inputName = kind.widgets.first(where: { $0.spec.imageUpload }).flatMap {
            editor.value(node, $0.name, kind: kind)?.string
        }
        VStack(spacing: 4) {
            if let image = shown.first ?? inputName.flatMap({ editor.inputImage($0, client: app.client) }) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if shown.count > 1 {
                            Text("\(shown.count)").font(.caption2).padding(4).background(
                                .black.opacity(0.6), in: Capsule()
                            )
                            .padding(4)
                        }
                    }
            } else {
                Spacer()
            }
            if kind.showsImageWidget, !editor.isReadOnly {
                Menu("Choose Picture") {
                    Button("From the Gallery…", systemImage: "photo.on.rectangle") { pickingFromGallery = true }
                    Button("From a File…", systemImage: "folder") { importingFile = true }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var errors: some View {
        if let messages = editor.nodeErrors[path] {
            Text(messages.joined(separator: "\n"))
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(NodeColors.error.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                .frame(width: max(layout.bounds.width, 220), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: layout.bounds.height + 6)
        } else if case .missing = kind.role, !node.collapsed {
            Text("“\(node.type)” isn't installed on the server.")
                .font(.caption)
                .foregroundStyle(Color(hex: "#f99"))
                .padding(10)
                .offset(y: NodeLayout.title)
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menu: some View {
        let ids = selected ? editor.selection : [node.id]
        if case .subgraph = kind.role {
            Button("Open Subgraph", systemImage: "arrow.down.right.square") { actions.open(node.id) }
        }
        if !editor.isReadOnly {
            Button("Rename…", systemImage: "pencil") {
                newTitle = title
                renaming = true
            }
            Button(node.collapsed ? "Expand" : "Collapse", systemImage: "rectangle.compress.vertical") {
                editor.edit(ids, "Collapse", undo: undo) { $0.collapsed.toggle() }
            }
            Button(node.pinned ? "Unpin" : "Pin", systemImage: "pin") {
                editor.edit(ids, "Pin", undo: undo) { $0.pinned.toggle() }
            }
            Divider()
            Button(node.mode == .bypass ? "Stop Bypassing" : "Bypass", systemImage: "arrow.uturn.right") {
                editor.edit(ids, "Bypass", undo: undo) { $0.mode = node.mode == .bypass ? .always : .bypass }
            }
            Button(node.mode == .never ? "Unmute" : "Mute", systemImage: "speaker.slash") {
                editor.edit(ids, "Mute", undo: undo) { $0.mode = node.mode == .never ? .always : .never }
            }
            Menu("Colour") {
                Button("No Colour") {
                    editor.edit(ids, "Colour", undo: undo) {
                        $0.color = nil
                        $0.bgcolor = nil
                    }
                }
                ForEach(NodeColors.palette, id: \.0) { name, title, body in
                    Button(name) {
                        editor.edit(ids, "Colour", undo: undo) {
                            $0.color = title
                            $0.bgcolor = body
                        }
                    }
                }
            }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square") {
                editor.selection = ids
                editor.duplicateSelection(undo: undo)
            }
            Button("Copy", systemImage: "doc.on.doc") {
                editor.selection = ids
                editor.copySelection()
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                editor.selection = ids
                editor.deleteSelection(undo: undo)
            }
        }
    }
}

extension View {
    func widgetBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NodeColors.widget, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Number, combo, toggle and one-line text widgets.
private struct ValueWidget: View {
    let name: String
    let spec: InputSpec
    let value: JSONValue?
    let control: Binding<String>?
    let readOnly: Bool
    let set: (JSONValue) -> Void

    var body: some View {
        HStack(spacing: 4) {
            switch spec.type {
            case "INT", "FLOAT":
                number
            case "BOOLEAN":
                Text(name).foregroundStyle(.secondary)
                Spacer()
                Toggle(name, isOn: Binding(get: { value?.bool ?? false }, set: { set(.bool($0)) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            case "COMBO":
                combo
            default:
                Text(name).foregroundStyle(.secondary)
                TextWidget(value: value?.string ?? "", multiline: false) { set(.string($0)) }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .widgetBackground()
        .disabled(readOnly)
        .help(spec.tooltip ?? name)
    }

    private var isInt: Bool { spec.type == "INT" }

    private func formatted(_ d: Double) -> String {
        if isInt { return String(Int(d)) }
        let step = spec.step ?? 0.01
        let digits = max(0, min(4, Int((-log10(step)).rounded(.up))))
        return String(format: "%.\(digits)f", d)
    }

    private func clamp(_ d: Double) -> Double {
        var v = d
        if let min = spec.min { v = Swift.max(min, v) }
        if let max = spec.max { v = Swift.min(max, v) }
        return v
    }

    private func store(_ d: Double) {
        let v = clamp(d)
        set(isInt ? .int(Int(v)) : .double(v))
    }

    @ViewBuilder
    private var number: some View {
        let current = value?.double ?? 0
        let step = isInt ? Swift.max(1, spec.step ?? 1) : (spec.step ?? 0.1)
        Button {
            store(current - step)
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        Text(name).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        NumberField(text: formatted(current)) { text in
            if let d = Double(text.replacingOccurrences(of: ",", with: ".")) { store(d) }
        }
        if let control {
            Menu {
                Picker("After Each Run", selection: control) {
                    ForEach(WidgetLayout.controlValues, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: control.wrappedValue == "fixed" ? "lock" : "dice")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("After each run: \(control.wrappedValue)")
        }
        Button {
            store(current + step)
        } label: {
            Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
    }

    private var combo: some View {
        let current = value?.string ?? ""
        let options = spec.options.contains(current) || current.isEmpty ? spec.options : [current] + spec.options
        return Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { set(.string(option)) }
            }
        } label: {
            HStack {
                Text(name).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(current).foregroundStyle(spec.options.contains(current) ? NodeColors.text : .orange)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

/// A number typed in; taken on Return or when leaving the field.
private struct NumberField: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .frame(minWidth: 40)
            .onAppear { draft = text }
            .onChange(of: text) { if !focused { draft = text } }
            .onChange(of: focused) { _, now in if !now { commit(draft) } }
            .onSubmit { commit(draft) }
    }
}

/// Text, typed into a draft and taken after a short pause or when leaving
/// the field, so typing a word is one undo step.
private struct TextWidget: View {
    let value: String
    let multiline: Bool
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var pause: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $draft)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .widgetBackground()
            } else {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit { commit(draft) }
            }
        }
        .focused($focused)
        .onAppear { draft = value }
        .onChange(of: value) { if !focused { draft = value } }
        .onChange(of: focused) { _, now in if !now { take() } }
        .onChange(of: draft) {
            pause?.cancel()
            pause = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { take() }
            }
        }
    }

    private func take() {
        pause?.cancel()
        if draft != value { commit(draft) }
    }
}

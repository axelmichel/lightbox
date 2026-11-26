import ComfyKit
import LightboxCore
import SwiftUI

/// Preset, size, seed, guides, LoRAs and the face/hand fix. The prompt and
/// Generate are in `PromptPanel`, under the gallery.
struct GenerateView: View {
    /// What the file picker is open for.
    enum Picking {
        case newGuide(ControlKind)
        case replace(Guide.ID)
    }

    @Environment(AppModel.self) private var app
    @State private var showSent = false
    @State private var showGuidePicker = false
    /// Kept apart from `importing`: the picker resets its binding before it
    /// calls back, so the action must outlive it.
    @State private var picking: Picking?
    @State private var importing = false
    @State private var showLoraInfo = false
    @State private var addingLora = false
    @State private var choosingPreset = false
    @AppStorage(PanelKeys.nodes) private var showNodes = false
    /// Closes the panel; its button sits in the panel's own header.
    var close: (() -> Void)?

    var body: some View {
        @Bindable var app = app
        @Bindable var gen = app.generation
        let preset = gen.preset(in: app.library)
        Form {
            if let notice = gen.notice {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle").foregroundStyle(.tint)
                        Text(notice).font(.callout)
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { gen.notice = nil }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
            if !app.isConnected {
                Section {
                    Label(connectionText, systemImage: "bolt.horizontal.circle").foregroundStyle(.secondary)
                    #if os(macOS)
                        SettingsLink { Text("Open Settings…") }
                    #endif
                }
            }

            Section {
                presetPicker(preset)
            }

            // What the workflow shown in the node graph changes; the preset stays as it is.
            if let preset, let workflow = gen.shownWorkflow(app, preset: preset), !workflow.overrides.isEmpty {
                Section {
                    ForEach(workflow.overrides.entries(for: preset), id: \.text) { entry in
                        HStack {
                            Text(entry.text)
                            Spacer()
                            Button("Reset", systemImage: "arrow.uturn.backward") { gen.resetOverride(entry.field, app) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Back to the preset's value")
                        }
                    }
                    HStack {
                        Button("Reset All") { gen.resetOverride(nil, app) }
                        Spacer()
                        Button("Save to Preset") { gen.saveOverridesToPreset(app) }
                            .help("Make these the preset's own values, for every workflow of “\(preset.name)”")
                    }
                } header: {
                    Text("Changed in “\(workflow.name)”")
                } footer: {
                    Text("Set in the node graph. The preset itself stays as it is until you save these to it.")
                }
            }

            // Nodes added in the graph: what is sent isn't only the preset's any more.
            if let preset, let workflow = gen.shownWorkflow(app, preset: preset),
                let added = app.workflows.document(workflow.id)?.addedNodes, !added.isEmpty
            {
                Section {
                    Label(
                        added.count == 1 ? "1 node added in the graph" : "\(added.count) nodes added in the graph",
                        systemImage: "point.3.connected.trianglepath.dotted")
                } header: {
                    Text("Custom Workflow")
                } footer: {
                    Text(
                        "“\(workflow.name)” is generated through the node graph; every text in it is checked like a prompt."
                    )
                }
            }

            Section("Picture") {
                if let preset {
                    Toggle(
                        "Preset size (\(preset.width) × \(preset.height))",
                        isOn: Binding(
                            get: { gen.size == nil },
                            set: { gen.size = $0 ? nil : ImageSize(width: preset.width, height: preset.height) }))
                    if let size = gen.size {
                        SizeFields(
                            width: Binding(get: { size.width }, set: { gen.size?.width = $0 }),
                            height: Binding(get: { size.height }, set: { gen.size?.height = $0 }),
                            size: { $0.size(for: preset.family) })
                    }
                }
                Stepper("Pictures per run: \(gen.batchSize)", value: $gen.batchSize, in: 1...8)
                HStack {
                    TextField("Seed", text: $gen.seedText, prompt: Text("random"))
                        .autocorrectionDisabled()
                    Button("Random", systemImage: "dice") { gen.seedText = "" }
                        .labelStyle(.iconOnly)
                        .help("A new random seed for every run")
                        .disabled(gen.seedText.isEmpty)
                }
            }

            Section {
                ForEach($gen.guides) { $guide in
                    GuideRow(guide: $guide) {
                        picking = .replace(guide.id)
                        importing = true
                    }
                }
                Button("Add Guide…", systemImage: "plus.circle") { showGuidePicker = true }
                    .disabled(!app.isConnected)
            } header: {
                Text("Guides")
            } footer: {
                if gen.guides.isEmpty {
                    Text(
                        "Guide the picture with a sketch, a pose, the depth of a scene, or a picture whose style or layout it should borrow. Gallery pictures: right-click → Use as Guide."
                    )
                }
            }

            Section {
                ForEach($app.library.extraLoras) { $slot in
                    LoraRow(slot: $slot, family: preset?.family) {
                        app.library.extraLoras.removeAll { $0.id == slot.id }
                    }
                }
                .onMove { app.library.extraLoras.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button("Add LoRA", systemImage: "plus.circle") { addingLora = true }
                    Spacer()
                    LoraInfoButton { showLoraInfo = true }
                }
            } header: {
                Text("LoRAs")
            } footer: {
                if let preset, !preset.loras.filter(\.isActive).isEmpty {
                    Text("The preset adds: \(preset.loras.filter(\.isActive).map(\.name).joined(separator: ", "))")
                } else {
                    Text("Effects or looks for these pictures, on top of the preset's LoRAs.")
                }
            }

            FinishSection()

            Section {
                sent
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .sheet(isPresented: $showLoraInfo) { LorasView(family: gen.preset(in: app.library)?.family) }
        .sheet(isPresented: $addingLora) {
            LorasView(
                pick: { name in
                    Task { app.library.extraLoras.append(await app.slot(forPicked: name)) }
                }, family: gen.preset(in: app.library)?.family)
        }
        // Open the file picker only once the guide list has fully closed;
        // presenting both at once can drop the picker.
        .sheet(isPresented: $showGuidePicker, onDismiss: { if picking != nil { importing = true } }) {
            GuidePicker { kind in picking = .newGuide(kind) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            let target = picking
            picking = nil
            switch result {
            case .success(let url):
                do {
                    let data = try readPickedFile(url)
                    switch target {
                    case .newGuide(let kind): gen.addGuide(kind, data: data, name: url.lastPathComponent)
                    case .replace(let id): gen.replacePicture(of: id, data: data, name: url.lastPathComponent)
                    case nil: break
                    }
                } catch {
                    gen.showError("Could not read “\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            case .failure(let error):
                gen.showError("Could not open the file: \(error.localizedDescription)")
            }
        }
    }

    private var connectionText: String {
        switch app.connection {
        case .idle: "Not connected. Enter the ComfyUI address in Settings."
        case .connecting: "Connecting…"
        case .failed(let message): message
        case .connected: ""
        }
    }

    @ViewBuilder private func presetPicker(_ preset: GenerationPreset?) -> some View {
        let gen = app.generation
        if app.library.presets.isEmpty {
            HStack {
                Text("No presets yet.")
                Spacer()
                Button("Detect from Server") {
                    Task { await app.addDetectedPresets(for: app.models) }
                }
                .disabled(!app.isConnected || !app.detecting.isEmpty)
            }
        } else {
            // Chosen in the presets dialog, with their pictures, as LoRAs are.
            Button {
                choosingPreset = true
            } label: {
                HStack(spacing: 10) {
                    LoraThumbnail(
                        image: preset.flatMap { app.presetPicture($0.id) }, size: 44, symbol: "slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset?.name ?? "Choose a Preset").font(.headline).lineLimit(1)
                        if let preset, !preset.checkpoint.isEmpty {
                            Text(PresetDetector.displayName(preset.checkpoint))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose the preset to generate with")
            .sheet(isPresented: $choosingPreset) {
                PresetsView(start: preset?.id) { gen.presetID = $0 }
            }
            if let preset {
                HStack(spacing: 6) {
                    Badge(text: preset.style.label, color: .accentColor)
                    Badge(text: preset.family.label, color: preset.family.isSupported ? .secondary : .red)
                    if preset.speed != .standard { Badge(text: preset.speed.label) }
                    Spacer()
                    Button("Reload Models", systemImage: "arrow.clockwise") { Task { await app.refreshCatalog() } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Reload the server's models; new checkpoints and diffusion models get a preset")
                    Button("Edit Presets…") { app.showingPresets = true }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder private var sent: some View {
        switch app.generation.previewPrompt(app) {
        case .success(let prompt):
            DisclosureGroup("Sent to ComfyUI", isExpanded: $showSent) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(prompt.positive.isEmpty ? "—" : prompt.positive).textSelection(.enabled)
                    Text("Negative: \(prompt.negative)").foregroundStyle(.secondary).textSelection(.enabled)
                    if !prompt.loras.isEmpty {
                        Text(prompt.loras.map(Self.describe).joined(separator: "\n")).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            if let signal = prompt.minorSignal {
                Label("Shows a minor (\(signal)): safety terms added to the negative prompt.", systemImage: "shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .failure(let error):
            Label(error.description, systemImage: "hand.raised").foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    static func describe(_ l: LoraUse) -> String {
        let w = l.weight.formatted(.number.precision(.fractionLength(2)))
        let c = l.clipWeight.formatted(.number.precision(.fractionLength(2)))
        return l.clipWeight == l.weight ? "\(l.name) @ \(w)" : "\(l.name) @ \(w), prompt \(c)"
    }
}

extension GenerateView {
    /// The panel's title with its Close button.
    fileprivate var header: some View {
        HStack(spacing: 10) {
            Text("Generate").font(.headline)
            Spacer()
            // The graph takes the middle; an open composition is saved and closed for it.
            Toggle(
                "Nodes", systemImage: "point.3.connected.trianglepath.dotted",
                isOn: Binding(
                    get: { showNodes && app.compositions.document == nil },
                    set: { on in
                        if on { app.compositions.close() }
                        showNodes = on
                    })
            )
            .toggleStyle(.button)
            .help(showNodes ? "Show the gallery" : "Show the node graph in place of the gallery")
            if let close {
                PanelButton(title: "Hide the Generate panel", systemImage: "sidebar.trailing", action: close)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: PanelHeader.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

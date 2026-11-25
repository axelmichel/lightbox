import ComfyKit
import LightboxCore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Server address and status, the prompt helper, content rating, and where
/// the gallery is.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(GenerationModel.throughGraphKey) private var throughGraph = false
    @AppStorage(GenerationModel.fullGraphKey) private var fullGraph = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                HStack {
                    TextField("Address", text: $app.serverAddress, prompt: Text("192.168.1.20:8188"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                        .onSubmit { Task { await app.connect() } }
                    Button("Connect") { Task { await app.connect() } }
                        .disabled(app.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                status
            } header: {
                Text("ComfyUI Server")
            } footer: {
                Text("Start ComfyUI with --listen so other devices can reach it. Each device keeps its own address.")
            }

            if app.isConnected {
                Section("On the Server") {
                    LabeledContent("Checkpoints", value: "\(app.catalog.checkpoints.count)")
                    LabeledContent("Diffusion models", value: "\(app.catalog.diffusionModels.count)")
                    LabeledContent("LoRAs", value: "\(app.catalog.loras.count)")
                    LabeledContent("ControlNets", value: "\(app.catalog.controlNets.count)")
                    LabeledContent("IP-Adapters", value: "\(app.catalog.ipAdapters.count)")
                    LabeledContent("VAEs", value: "\(app.catalog.vaes.count)")
                    Button("Reload Model Lists") { Task { await app.refreshCatalog() } }
                }
                Section("Custom Nodes") {
                    NodeStatus(
                        "Guide extraction", detail: "comfyui_controlnet_aux: lines, depth, pose from any picture",
                        ok: app.catalog.hasAuxPreprocessors)
                    NodeStatus(
                        "Reference, style, composition", detail: "ComfyUI_IPAdapter_plus", ok: app.catalog.hasIPAdapter)
                    NodeStatus(
                        "Face and hand fix",
                        detail: "ComfyUI-Impact-Pack + Impact-Subpack, "
                            + (app.catalog.faceDetector ?? "no face detector model"),
                        ok: app.catalog.hasDetailer && app.catalog.faceDetector != nil)
                }
                GuideAvailability()
            }

            Section {
                HStack {
                    TextField("Address", text: $app.ollamaAddress, prompt: Text(OllamaClient.defaultAddress))
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                        .onSubmit { Task { await app.checkOllama() } }
                    Button("Check") { Task { await app.checkOllama() } }
                }
                ollamaStatus
                if app.ollamaModels.isEmpty {
                    TextField("Model", text: $app.ollamaModel, prompt: Text("e.g. qwen3:8b; empty = off"))
                        .autocorrectionDisabled()
                } else {
                    Picker("Model", selection: $app.ollamaModel) {
                        Text("Off").tag("")
                        if !app.ollamaModel.isEmpty, !app.ollamaModels.contains(app.ollamaModel) {
                            Text("\(app.ollamaModel) (not installed)").tag(app.ollamaModel)
                        }
                        ForEach(app.ollamaModels, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Prompt Helper (Ollama)")
            } footer: {
                Text(
                    "Enhance on the prompt panel rewrites the prompt for the preset's model: tags for anime models, sentences for photo models. Install Ollama, run “ollama pull qwen3:8b” (or another model), and keep it running."
                )
            }

            Section {
                Picker("Content rating", selection: $app.library.rating) {
                    ForEach(ContentRating.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(
                    "Pictures may show children; sexual content involving minors is always refused, whatever the rating."
                )
            }

            Section {
                Toggle("Generate through the node graph", isOn: $throughGraph)
                Toggle("Save the full graph with each picture", isOn: $fullGraph)
                    .disabled(!throughGraph)
            } header: {
                Text("Node Graph")
            } footer: {
                Text(
                    "Sends the graph the Nodes view shows, with a saved workflow's nodes, instead of building it "
                        + "straight from the preset. Every text in it is checked like a prompt. The pictures should "
                        + "be the same either way. A picture names the workflow it was made with; with the full "
                        + "graph saved it can be made again exactly, even after the workflow changed (larger gallery)."
                )
            }

            Section("Gallery") {
                LabeledContent("Pictures", value: "\(app.gallery.index.items.count)")
                LabeledContent("Folders", value: "\(app.gallery.index.folders.count)")
                #if os(macOS)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.gallery.store.root])
                    }
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { if app.ollamaStatus == .idle { await app.checkOllama() } }
    }

    @ViewBuilder private var ollamaStatus: some View {
        switch app.ollamaStatus {
        case .idle:
            EmptyView()
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case .ready:
            Label(
                app.ollamaModels.isEmpty
                    ? "Running, but no models are installed" : "Running · \(app.ollamaModels.count) models",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(app.ollamaModels.isEmpty ? .orange : .green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var status: some View {
        switch app.connection {
        case .idle:
            Text("Not connected").foregroundStyle(.secondary)
        case .connecting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting…")
            }
        case .connected(let stats):
            VStack(alignment: .leading, spacing: 2) {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(
                    [stats.system.comfyuiVersion.map { "ComfyUI \($0)" }, stats.gpuSummary].compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct NodeStatus: View {
    let title: String
    let detail: String
    let ok: Bool

    init(_ title: String, detail: String, ok: Bool) {
        self.title = title
        self.detail = detail
        self.ok = ok
    }

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Which guides work with each model family the presets use.
private struct GuideAvailability: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let families = Set(app.library.presets.map(\.family).filter(\.supportsGuides))
        let archs = ModelArch.allCases.filter { arch in families.contains { $0.arch == arch } }
        ForEach(archs, id: \.self) { arch in
            Section {
                ForEach(ControlKind.allCases) { kind in
                    let result = ControlResolver.resolve(kind, arch: arch, catalog: app.catalog)
                    HStack(alignment: .firstTextBaseline) {
                        Label(kind.title, systemImage: kind.icon)
                        Spacer()
                        switch result {
                        case .success(.controlNet(let model, let union, _)):
                            Text(union.map { _ in "union: \(model)" } ?? model)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        case .success(.ipAdapter(let model, _, _)):
                            Text(model).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        case .failure(let missing):
                            Text(missing.message).font(.caption).foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            } header: {
                Text("Guides for \(families.filter { $0.arch == arch }.map(\.label).sorted().joined(separator: ", "))")
            }
        }
    }
}

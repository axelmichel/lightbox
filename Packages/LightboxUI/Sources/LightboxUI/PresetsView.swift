import ComfyKit
import LightboxCore
import SwiftUI
import UniformTypeIdentifiers

/// Create, detect, import and edit presets.
struct PresetsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var importing = false
    @State private var importProblem: String?

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(app.library.presets) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).lineLimit(1)
                        Text("\(p.style.label) · \(p.family.label)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(p.id)
                    .contextMenu {
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(p) }
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(p.id) }
                    }
                }
                .onMove { app.library.presets.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Menu("Add", systemImage: "plus") {
                        Section("Detect from a checkpoint") {
                            ForEach(app.catalog.checkpoints, id: \.self) { name in
                                Button(name) { Task { await addDetected(name) } }
                            }
                        }
                        Section("Detect from a diffusion model (Flux, Flux 2, Z-Image)") {
                            ForEach(app.catalog.diffusionModels, id: \.self) { name in
                                Button(name) { Task { await addDetected(name) } }
                            }
                        }
                        Button("Detect for All New Models") {
                            Task {
                                let added = await app.addDetectedPresets(for: app.models)
                                if let first = added.first { selection = first.id }
                            }
                        }
                        .disabled(app.models.isEmpty)
                        Divider()
                        Button("Import ComfyUI Workflow…", systemImage: "square.and.arrow.down") { importing = true }
                        Button("Empty Preset") {
                            let p = GenerationPreset(name: "New Preset")
                            app.library.presets.append(p)
                            selection = p.id
                        }
                    }
                }
            }
        } detail: {
            if let selection, app.library.presets.contains(where: { $0.id == selection }) {
                PresetEditor(id: selection)
            } else {
                ContentUnavailableView(
                    "No Preset Selected", systemImage: "slider.horizontal.3",
                    description: Text("Add one with + — Lightbox looks at the checkpoint and suggests its settings."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { selection = selection ?? app.generation.preset(in: app.library)?.id }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    try importWorkflow(readPickedFile(url), name: url.lastPathComponent)
                } catch let error as WorkflowImportError {
                    importProblem = error.description
                } catch {
                    importProblem = "Could not read “\(url.lastPathComponent)”: \(error.localizedDescription)"
                }
            case .failure(let error):
                importProblem = "Could not open the file: \(error.localizedDescription)"
            }
        }
        .alert(
            "Import Workflow",
            isPresented: Binding(get: { importProblem != nil }, set: { if !$0 { importProblem = nil } })
        ) {
            Button("OK") { importProblem = nil }
        } message: {
            Text(importProblem ?? "")
        }
        #if os(macOS)
            .frame(minWidth: 820, idealWidth: 960, minHeight: 600, idealHeight: 720)
        #endif
    }

    /// A new preset from a ComfyUI workflow file; its prompt goes into the
    /// prompt field.
    private func importWorkflow(_ data: Data, name: String) throws {
        let result = try WorkflowImport.read(data, name: name)
        var preset = result.preset
        let onServer = Set(app.models + app.catalog.textEncoders + app.catalog.loras)
        let missing = result.files.filter { !onServer.contains($0) }
        if app.isConnected, !missing.isEmpty {
            preset.detectionNotes.append("Not on the server: \(missing.joined(separator: ", ")).")
        }
        app.library.presets.append(preset)
        app.library.knownCheckpoints.insert(preset.checkpoint)
        selection = preset.id
        app.generation.presetID = preset.id
        if !result.prompt.isEmpty { app.generation.prompt = result.prompt }
    }

    private func addDetected(_ checkpoint: String) async {
        var preset = await app.detect(checkpoint: checkpoint).preset(checkpoint: checkpoint)
        app.fillSplitParts(&preset)
        app.library.presets.append(preset)
        selection = preset.id
    }

    private func duplicate(_ p: GenerationPreset) {
        var copy = p
        copy.id = UUID()
        copy.name += " copy"
        app.library.presets.append(copy)
        selection = copy.id
    }

    private func delete(_ id: UUID) {
        app.library.presets.removeAll { $0.id == id }
        if selection == id { selection = app.library.presets.first?.id }
    }
}

/// All settings of one preset.
struct PresetEditor: View {
    let id: UUID
    @Environment(AppModel.self) private var app
    @State private var addingLora = false
    @State private var showLoraInfo = false

    var body: some View {
        @Bindable var app = app
        if let i = app.library.presets.firstIndex(where: { $0.id == id }) {
            let p = $app.library.presets[i]
            let preset = app.library.presets[i]
            Form {
                Section {
                    TextField("Name", text: p.name)
                    if preset.family.isSplit {
                        CatalogPicker(
                            title: "Diffusion model", selection: p.checkpoint, options: app.catalog.diffusionModels)
                    } else {
                        CatalogPicker(title: "Checkpoint", selection: p.checkpoint, options: app.catalog.checkpoints)
                    }
                    HStack {
                        Button("Suggest Settings", systemImage: "wand.and.stars") {
                            Task { await app.suggestSettings(for: id) }
                        }
                        .disabled(preset.checkpoint.isEmpty)
                        if app.detecting.contains(preset.checkpoint) { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                } footer: {
                    Text(
                        "Looks at the model's name and the details stored in the file, and the LoRAs in use, "
                            + "then sets the family, style, sampler, steps, CFG, size and prompts to match. "
                            + "For Flux and Z-Image it also picks the text encoders and VAE.")
                }

                if !preset.detectionNotes.isEmpty {
                    Section("Why these settings") {
                        ForEach(preset.detectionNotes, id: \.self) { Text($0).font(.callout) }
                    }
                }

                Section("Model") {
                    Picker("Family", selection: p.family) {
                        ForEach(ModelFamily.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Style", selection: p.style) {
                        ForEach(PictureStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Speed", selection: p.speed) {
                        ForEach(SpeedVariant.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if preset.family.isSplit {
                        ForEach(0..<preset.family.textEncoderCount, id: \.self) { n in
                            CatalogPicker(
                                title: preset.family == .flux
                                    ? (n == 0 ? "T5 text encoder" : "CLIP-L text encoder")
                                    : "Text encoder",
                                selection: encoder(n, of: i), options: app.catalog.textEncoders)
                        }
                        CatalogPicker(title: "VAE", selection: p.vae.orEmpty, options: app.catalog.vaes)
                    } else {
                        CatalogPicker(
                            title: "VAE", selection: p.vae.orEmpty, options: app.catalog.vaes,
                            noneLabel: "From the checkpoint")
                    }
                }

                Section("Sampling") {
                    CatalogPicker(title: "Sampler", selection: p.sampler, options: app.catalog.samplers)
                    if preset.family != .flux2 {
                        // Flux 2 uses its own schedule, made for the picture's size.
                        CatalogPicker(title: "Scheduler", selection: p.scheduler, options: app.catalog.schedulers)
                    }
                    Stepper("Steps: \(preset.steps)", value: p.steps, in: 1...150)
                    HStack {
                        Text("CFG")
                        Slider(value: p.cfg, in: 1...15, step: 0.5)
                        Text(preset.cfg.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                            .frame(width: 36)
                    }
                    if preset.family == .flux {
                        HStack {
                            Text("Guidance")
                            Slider(value: p.guidance, in: 1...10, step: 0.5)
                            Text(preset.guidance.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                                .frame(width: 36)
                        }
                        .help("How closely Flux follows the prompt; it replaces CFG, which stays at 1")
                    } else if preset.family == .zImage {
                        HStack {
                            Text("Shift")
                            Slider(value: p.shift, in: 1...8, step: 0.5)
                            Text(preset.shift.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                                .frame(width: 36)
                        }
                        .help("Sampling shift (ModelSamplingAuraFlow); 3 is usual for Z-Image")
                    } else if !preset.family.isSplit {
                        Stepper("CLIP skip: \(preset.clipSkip)", value: p.clipSkip, in: 1...4)
                    }
                    LabeledContent("Size") {
                        SizeFields(width: p.width, height: p.height, size: { $0.size(for: preset.family) })
                    }
                }

                Section("Prompt") {
                    Picker("Written as", selection: p.dialect) {
                        ForEach(PromptDialect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    PromptField(title: "Style (put before every prompt)", text: p.stylePrompt, height: 64)
                    PromptField(title: "Negative", text: p.negativePrompt, height: 80)
                    TextField(
                        "Prompt helper hint", text: p.enhanceHint,
                        prompt: Text("optional, e.g. “keep the background simple”"))
                }

                Section("LoRAs") {
                    ForEach(p.loras) { $slot in
                        LoraRow(slot: $slot, family: preset.family) {
                            app.library.presets[i].loras.removeAll { $0.id == slot.id }
                        }
                    }
                    HStack {
                        Button("Add LoRA", systemImage: "plus") { addingLora = true }
                        Spacer()
                        LoraInfoButton { showLoraInfo = true }
                    }
                }

                if let problem = preset.problem(with: app.catalog) {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(preset.name)
            .sheet(isPresented: $showLoraInfo) { LorasView(start: preset.loras.first?.name) }
            .sheet(isPresented: $addingLora) {
                LorasView(
                    pick: { name in
                        Task {
                            let slot = await app.slot(forPicked: name)
                            if let i = app.library.presets.firstIndex(where: { $0.id == id }) {
                                app.library.presets[i].loras.append(slot)
                            }
                        }
                    }, family: preset.family)
            }
        }
    }

    /// The preset's `n`th text encoder, filling the list up as needed.
    private func encoder(_ n: Int, of i: Int) -> Binding<String> {
        Binding(
            get: {
                app.library.presets[i].textEncoders.indices.contains(n) ? app.library.presets[i].textEncoders[n] : ""
            },
            set: { value in
                var list = app.library.presets[i].textEncoders
                while list.count <= n { list.append("") }
                list[n] = value
                app.library.presets[i].textEncoders = list
            })
    }
}

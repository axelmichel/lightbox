import ComfyKit
import LightboxCore
import SwiftUI
import UniformTypeIdentifiers

/// Create, detect, import and edit presets. With `pick` it is also where
/// the preset to generate with is chosen, as LoRAs are in `LorasView`.
struct PresetsView: View {
    /// The preset to show first.
    var start: UUID?
    /// Choosing a preset: called with the one picked.
    var pick: ((UUID) -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var importing = false
    @State private var importProblem: String?
    /// A preset with workflows, asked about before it is deleted.
    @State private var deleting: GenerationPreset?
    /// The workflows saved on the server, to make a preset from.
    @State private var serverWorkflows: [String] = []

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(app.library.presets) { p in
                    HStack(spacing: 8) {
                        LoraThumbnail(image: app.presetPicture(p.id), size: 40, symbol: "slider.horizontal.3")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text("\(p.style.label) · \(p.family.label)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(p.id)
                    #if os(macOS)
                        .onTapGesture(count: 2) { if pick != nil { use(p.id) } }
                        .simultaneousGesture(TapGesture().onEnded { selection = p.id })
                    #endif
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
                        Menu("From a Server Workflow", systemImage: "point.3.connected.trianglepath.dotted") {
                            ForEach(serverWorkflows, id: \.self) { name in
                                Button((name as NSString).deletingPathExtension) {
                                    Task { await importFromServer(name) }
                                }
                            }
                        }
                        .disabled(serverWorkflows.isEmpty)
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
                PresetEditor(id: selection, use: pick == nil ? nil : { use(selection) }).id(selection)
            } else {
                ContentUnavailableView(
                    "No Preset Selected", systemImage: "slider.horizontal.3",
                    description: Text("Add one with + — Lightbox looks at the checkpoint and suggests its settings."))
            }
        }
        .navigationTitle(pick == nil ? "Presets" : "Choose a Preset")
        .toolbar {
            if pick != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Preset") { if let selection { use(selection) } }
                        .disabled(selection == nil)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { selection = selection ?? start ?? app.generation.preset(in: app.library)?.id }
        .task { serverWorkflows = (try? await app.client?.savedWorkflows()) ?? [] }
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
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { preset in
            Button("Delete Preset and Workflows", role: .destructive) { remove(preset.id, keepWorkflows: false) }
                .keyboardShortcut(.defaultAction)
            Button("Keep the Workflows") { remove(preset.id, keepWorkflows: true) }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            let count = app.workflows.entries(for: preset.id).count
            Text(
                count == 1
                    ? "It has a workflow. Kept, it stays in the node graph's list without a preset."
                    : "It has \(count) workflows. Kept, they stay in the node graph's list without a preset.")
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
        selection = try app.addPreset(fromWorkflow: data, name: name).id
    }

    private func importFromServer(_ name: String) async {
        do {
            guard let client = app.client else { return }
            try importWorkflow(try await client.savedWorkflow(name), name: name)
        } catch let error as WorkflowImportError {
            importProblem = error.description
        } catch {
            importProblem = "Could not read “\(name)” from the server: \(AppModel.describe(error))"
        }
    }

    private func addDetected(_ checkpoint: String) async {
        var preset = await app.detect(checkpoint: checkpoint).preset(checkpoint: checkpoint)
        app.fillSplitParts(&preset)
        app.library.presets.append(preset)
        selection = preset.id
    }

    private func use(_ id: UUID) {
        pick?(id)
        dismiss()
    }

    private func duplicate(_ p: GenerationPreset) {
        var copy = p
        copy.id = UUID()
        copy.name += " copy"
        // Its own picture, so removing one doesn't remove the other's.
        copy.picture = nil
        app.library.presets.append(copy)
        selection = copy.id
    }

    /// Asks first if the preset has workflows.
    private func delete(_ id: UUID) {
        if let preset = app.library.presets.first(where: { $0.id == id }), !app.workflows.entries(for: id).isEmpty {
            deleting = preset
        } else {
            remove(id, keepWorkflows: false)
        }
    }

    private func remove(_ id: UUID, keepWorkflows: Bool) {
        app.workflows.presetDeleted(id, keepWorkflows: keepWorkflows)
        app.removePresetPicture(id)
        app.library.presets.removeAll { $0.id == id }
        if selection == id { selection = app.library.presets.first?.id }
    }
}

/// All settings of one preset.
struct PresetEditor: View {
    let id: UUID
    /// Choosing: uses this preset and closes.
    var use: (() -> Void)?
    @Environment(AppModel.self) private var app
    @State private var addingLora = false
    @State private var showLoraInfo = false
    @State private var choosingFromGallery = false
    @State private var choosingFile = false

    var body: some View {
        @Bindable var app = app
        if let i = app.library.presets.firstIndex(where: { $0.id == id }) {
            let p = $app.library.presets[i]
            let preset = app.library.presets[i]
            Form {
                if let use {
                    Section {
                        Button("Use This Preset", systemImage: "checkmark.circle", action: use)
                            .buttonStyle(.borderedProminent)
                    }
                }
                pictureSection(preset)
                if let template = preset.template {
                    templateSection(template, usesTemplate: p.usesTemplate)
                }
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
            .sheet(isPresented: $choosingFromGallery) {
                PicturePicker(single: true) { ids in
                    if let first = ids.first, let png = app.gallery.pngData(first) {
                        app.setPresetPicture(id, image: png)
                    }
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result, let data = try? readPickedFile(url) {
                    app.setPresetPicture(id, image: data)
                }
            }
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

    /// The workflow the preset was made from, and whether it is filled in to generate.
    private func templateSection(_ template: UUID, usesTemplate: Binding<Bool>) -> some View {
        let entry = app.workflows.entry(template)
        let doc = app.workflows.document(template)
        let found = doc.map { Set($0.roles.values.map(\.kind)) } ?? []
        return Section {
            Toggle("Use the workflow as template", isOn: usesTemplate)
            if let doc {
                LabeledContent("Filled in", value: TemplateText.found(found))
                let added = doc.addedNodes
                if !added.isEmpty {
                    LabeledContent("Kept as it is", value: added.map(\.type).joined(separator: ", "))
                }
            } else {
                Label("The workflow is gone.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("From Workflow “\(entry?.name ?? "?")”")
        } footer: {
            Text(
                "With the template, Lightbox fills in the workflow as it was made in ComfyUI: prompt, seed, size, "
                    + "sampling and LoRAs. Guides and the face and hand fix are off then. Without it, Lightbox "
                    + "builds the graph itself, tuned for the model family.")
        }
    }

    /// An example picture, shown when choosing a preset.
    private func pictureSection(_ preset: GenerationPreset) -> some View {
        let latest = app.latestPicture(of: id)
        return Section("Picture") {
            HStack(alignment: .top, spacing: 12) {
                LoraThumbnail(image: app.presetPicture(id), size: 120, symbol: "slider.horizontal.3")
                VStack(alignment: .leading, spacing: 6) {
                    Button("Use Latest Picture", systemImage: "clock.arrow.circlepath") {
                        if let latest, let png = app.gallery.pngData(latest.id) { app.setPresetPicture(id, image: png) }
                    }
                    .disabled(latest == nil)
                    .help("The newest picture in the gallery made with “\(preset.name)”")
                    Button("Choose from Gallery…", systemImage: "photo.on.rectangle") { choosingFromGallery = true }
                        .disabled(app.gallery.index.items.isEmpty)
                    Button("Choose File…", systemImage: "square.and.arrow.down") { choosingFile = true }
                    if app.presetPicture(id) != nil {
                        Button("Remove Picture", systemImage: "trash", role: .destructive) {
                            app.removePresetPicture(id)
                        }
                    }
                    Text("Shown when choosing a preset.").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
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

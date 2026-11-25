import LightboxCore
import SwiftUI

/// What is known about each LoRA on the server: filled in from the file,
/// with room for your own notes and a picture. Picking an edited LoRA uses
/// its triggers and strength from here. With `pick` it is also where a
/// LoRA is chosen for a preset or a generation.
struct LorasView: View {
    /// The LoRA to show first.
    var start: String?
    /// Choosing a LoRA: called with the one picked.
    var pick: ((String) -> Void)?
    /// The family it is chosen for, to point out LoRAs that don't fit.
    var family: ModelFamily?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var search = ""
    /// Only the LoRAs made for `family` (and those whose family isn't known).
    @State private var onlyFitting = true

    var body: some View {
        let all = Array(Set(app.catalog.loras).union(app.library.loraNotes.keys)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let found = all.filter(matches)
        let filtering = family != nil && onlyFitting
        let fitting = found.filter { ownFamily($0) == family }
        let unknown = found.filter { ownFamily($0) == nil }
        let names = filtering ? fitting + unknown : found
        NavigationSplitView {
            List(selection: $selection) {
                if filtering {
                    if !fitting.isEmpty {
                        Section("For \(family!.label)") { rows(fitting) }
                    }
                    if !unknown.isEmpty {
                        Section("Family unknown") { rows(unknown) }
                    }
                } else {
                    rows(found)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Name, trigger word or note")
            .safeAreaInset(edge: .top, spacing: 0) {
                if let family {
                    Picker("Show", selection: $onlyFitting) {
                        Text("For \(family.label)").tag(true)
                        Text("All").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .help("Only the LoRAs made for the preset's model family, or all of them")
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .overlay {
                if names.isEmpty {
                    if all.isEmpty {
                        ContentUnavailableView(
                            "No LoRAs", systemImage: LoraInfoIcon.name,
                            description: Text("Connect to the server to list its LoRAs."))
                    } else if filtering, search.isEmpty {
                        ContentUnavailableView {
                            Label("No LoRAs for \(family!.label)", systemImage: LoraInfoIcon.name)
                        } description: {
                            Text("None of the server's LoRAs is known to be made for this model family.")
                        } actions: {
                            Button("Show All") { onlyFitting = false }
                        }
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
        } detail: {
            if let selection {
                LoraNoteEditor(name: selection, use: pick == nil ? nil : { use(selection) }).id(selection)
            } else {
                ContentUnavailableView(
                    "No LoRA Selected", systemImage: LoraInfoIcon.name,
                    description: Text("Trigger words, a good strength and what it is for, read from the file."))
            }
        }
        .navigationTitle(pick == nil ? "LoRA Info" : "Choose a LoRA")
        .toolbar {
            if pick != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This LoRA") { if let selection { use(selection) } }
                        .disabled(selection == nil)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { selection = selection ?? start.flatMap { $0.isEmpty ? nil : $0 } ?? names.first }
        // The family comes from each file; read them all so the filter knows.
        .task {
            guard family != nil else { return }
            for name in all where app.loraInfo[name] == nil && app.library.loraNotes[name]?.family == nil {
                await app.inspectLora(name)
            }
        }
        #if os(macOS)
            .frame(minWidth: 820, idealWidth: 940, minHeight: 560, idealHeight: 680)
        #endif
    }
}

extension LorasView {
    @ViewBuilder private func rows(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            LoraListRow(name: name, family: family)
                .tag(name)
                #if os(macOS)
                    .onTapGesture(count: 2) { if pick != nil { use(name) } }
                    .simultaneousGesture(TapGesture().onEnded { selection = name })
                #endif
        }
    }

    /// What the LoRA was made for: as written on its info page, else as its file says.
    private func ownFamily(_ name: String) -> ModelFamily? {
        app.library.loraNotes[name]?.family ?? app.loraInfo[name]?.family
    }

    private func use(_ name: String) {
        pick?(name)
        dismiss()
    }

    /// Found by its name, trigger words or notes.
    private func matches(_ name: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let note = app.library.loraNotes[name]
        let text = [name, PresetDetector.displayName(name), note?.triggers ?? "", note?.notes ?? ""]
            .joined(separator: " ")
        return q.split(separator: " ").allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// A LoRA in the list: its picture, name and what is known about it.
private struct LoraListRow: View {
    let name: String
    let family: ModelFamily?
    @Environment(AppModel.self) private var app

    var body: some View {
        let note = app.library.loraNotes[name]
        let own = note?.family ?? app.loraInfo[name]?.family
        HStack(spacing: 8) {
            LoraThumbnail(image: app.loraPicture(name), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(PresetDetector.displayName(name)).lineLimit(1)
                HStack(spacing: 4) {
                    if let own { Badge(text: own.label) }
                    if note?.edited == true { Badge(text: "edited", color: .accentColor) }
                    if !app.catalog.loras.isEmpty, !app.catalog.loras.contains(name) {
                        Badge(text: "not on server", color: .orange)
                    }
                    if let family, let info = app.loraInfo[name], info.mismatch(with: family) != nil {
                        Badge(text: "other family", color: .orange)
                    }
                }
            }
        }
        .help(name)
    }
}

/// A LoRA's picture, or its symbol while it has none.
struct LoraThumbnail: View {
    let image: CGImage?
    var size = 40.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: LoraInfoIcon.name).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct LoraNoteEditor: View {
    let name: String
    /// Choosing: uses this LoRA and closes.
    var use: (() -> Void)?
    @Environment(AppModel.self) private var app
    @State private var lookingUp = false
    @State private var lookup: String?
    @State private var choosingFromGallery = false
    @State private var choosingFile = false

    var body: some View {
        let info = app.loraInfo[name]
        let note = app.library.loraNotes[name] ?? info.map { LoraNote(detected: $0, name: name) }
        Form {
            if let use {
                Section {
                    Button("Use This LoRA", systemImage: "checkmark.circle", action: use)
                        .buttonStyle(.borderedProminent)
                }
            }
            Section("Picture") {
                HStack(alignment: .top, spacing: 12) {
                    LoraThumbnail(image: app.loraPicture(name), size: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Choose from Gallery…", systemImage: "photo.on.rectangle") { choosingFromGallery = true }
                            .disabled(app.gallery.index.items.isEmpty)
                        Button("Choose File…", systemImage: "square.and.arrow.down") { choosingFile = true }
                        if app.loraPicture(name) != nil {
                            Button("Remove Picture", systemImage: "trash", role: .destructive) {
                                app.removeLoraPicture(name)
                            }
                        }
                        Text(
                            "Shown when choosing a LoRA. *Look Up on Civitai* adds an example picture if there is none."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section {
                HStack {
                    Button("Look Up on Civitai", systemImage: "magnifyingglass") {
                        lookingUp = true
                        Task {
                            lookup = await app.lookUpOnCivitai(name)
                            lookingUp = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lookingUp)
                    if lookingUp { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let lookup { Text(lookup).font(.callout).foregroundStyle(.secondary) }
            } footer: {
                Text(
                    "Fills in the description, trigger words, base model, link and a sample prompt from Civitai. "
                        + "Sends the file's weight hash or its name to civitai.com.")
            }

            Section {
                LabeledContent("File", value: name)
                TextField("Trigger words", text: field(\.triggers), prompt: Text("added to the prompt"))
                    .autocorrectionDisabled()
                LabeledContent("Strength: \(note?.strength ?? 1, specifier: "%.2f")") {
                    Slider(value: field(\.strength), in: -2...2, step: 0.05)
                }
                Toggle("Separate strength for the prompt", isOn: separateClip)
                if let clip = note?.clipStrength {
                    LabeledContent("Prompt strength: \(clip, specifier: "%.2f")") {
                        Slider(
                            value: Binding(get: { clip }, set: { v in edit { $0.clipStrength = v } }), in: -2...2,
                            step: 0.05)
                    }
                }
                Picker("Made for", selection: field(\.family)) {
                    Text("Unknown").tag(ModelFamily?.none)
                    ForEach(ModelFamily.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
            } header: {
                Text("Best settings")
            } footer: {
                Text("Adding this LoRA to a preset or a generation fills in these trigger words and strength.")
            }

            Section("Notes") {
                PromptField(title: "What it does, what works with it", text: field(\.notes), height: 96)
                PromptField(title: "Sample prompt", text: field(\.samplePrompt), height: 56)
                HStack {
                    TextField("Link", text: field(\.link), prompt: Text("https://civitai.com/models/…"))
                        .autocorrectionDisabled()
                    if let url = URL(string: note?.link ?? ""), url.scheme?.hasPrefix("http") == true {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Open the link")
                    }
                }
                if let sample = note?.samplePrompt, !sample.isEmpty {
                    Button("Use Sample Prompt", systemImage: "text.insert") {
                        app.generation.prompt = sample
                    }
                }
            }

            if let info {
                Section {
                    LabeledContent("Kind", value: info.kind.label)
                    if let family = info.family { LabeledContent("Family", value: family.label) }
                    if !info.triggers.isEmpty {
                        LabeledContent("Trigger words", value: info.triggers.joined(separator: ", "))
                    }
                    if !info.suggestions.isEmpty {
                        LabeledContent("Telling tags", value: info.suggestions.joined(separator: ", "))
                    }
                    LabeledContent("Strength", value: info.strength.formatted(.number.precision(.fractionLength(2))))
                    ForEach(info.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    if let preset = app.generation.preset(in: app.library),
                        let problem = info.mismatch(with: preset.family)
                    {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Button("Reset to Detected", systemImage: "arrow.counterclockwise") {
                        Task { await app.resetLoraNote(name) }
                    }
                    .disabled(note?.edited != true)
                } header: {
                    Text("What the file says")
                }
            } else {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading the file…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(PresetDetector.displayName(name))
        .task(id: name) { await app.inspectLora(name) }
        .sheet(isPresented: $choosingFromGallery) {
            PicturePicker(single: true) { ids in
                if let id = ids.first, let png = app.gallery.pngData(id) { app.setLoraPicture(name, image: png) }
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let data = try? readPickedFile(url) {
                app.setLoraPicture(name, image: data)
            }
        }
    }

    /// Change the note, making it first if needed, and mark it edited.
    private func edit(_ change: (inout LoraNote) -> Void) {
        var note =
            app.library.loraNotes[name] ?? app.loraInfo[name].map { LoraNote(detected: $0, name: name) }
            ?? LoraNote(name: name)
        change(&note)
        note.edited = true
        app.library.loraNotes[name] = note
    }

    private func field<T>(_ key: WritableKeyPath<LoraNote, T>) -> Binding<T> {
        Binding(
            get: {
                let note =
                    app.library.loraNotes[name] ?? app.loraInfo[name].map { LoraNote(detected: $0, name: name) }
                    ?? LoraNote(name: name)
                return note[keyPath: key]
            },
            set: { value in edit { $0[keyPath: key] = value } })
    }

    private var separateClip: Binding<Bool> {
        Binding(
            get: { app.library.loraNotes[name]?.clipStrength != nil },
            set: { on in edit { $0.clipStrength = on ? $0.strength : nil } })
    }
}

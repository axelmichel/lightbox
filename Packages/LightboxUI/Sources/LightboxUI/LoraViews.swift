import LightboxCore
import SwiftUI

/// A LoRA: file, strength and trigger words, and under "More" a separate
/// prompt strength, as in a ComfyUI LoRA chain. Picking a file reads its
/// metadata: the trigger words and a starting strength are filled in, other
/// telling training tags are offered, and a LoRA made for another model
/// family is pointed out.
struct LoraRow: View {
    @Binding var slot: LoraSlot
    /// The preset's family, to check the LoRA against.
    var family: ModelFamily?
    let remove: () -> Void
    @Environment(AppModel.self) private var app
    @State private var showMore = false
    @State private var choosing = false

    var body: some View {
        let info = app.loraInfo[slot.name]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("On", isOn: $slot.enabled).labelsHidden()
                Text(slot.name.isEmpty ? "No LoRA chosen" : PresetDetector.displayName(slot.name))
                    .lineLimit(1)
                    .foregroundStyle(slot.name.isEmpty ? .secondary : .primary)
                    .help(slot.name)
                Spacer(minLength: 4)
                // Opens the LoRA Info page to choose another; what it does shows on hover.
                Button {
                    choosing = true
                } label: {
                    LoraThumbnail(image: app.loraPicture(slot.name), size: 28)
                }
                .buttonStyle(.plain)
                .help(slot.name.isEmpty ? "Choose a LoRA" : "Choose another LoRA (LoRA Info)")
                .accessibilityLabel("Choose a LoRA")
                Button("Remove", systemImage: "minus.circle", action: remove)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if let info { summary(info) }
            Group {
                LabeledContent("Strength: \(slot.strength, specifier: "%.2f")") {
                    Slider(value: $slot.strength, in: -2...2, step: 0.05)
                }
                TextField("Trigger words", text: $slot.triggers, prompt: Text("added to the prompt"))
                    .autocorrectionDisabled()
                if let info { offers(info) }
                DisclosureGroup("More", isExpanded: $showMore) {
                    Toggle("Separate strength for the prompt", isOn: separateClip)
                    if let clip = slot.clipStrength {
                        LabeledContent("Prompt strength: \(clip, specifier: "%.2f")") {
                            Slider(value: clipBinding, in: -2...2, step: 0.05)
                        }
                    }
                    Text(
                        "Strength acts on the image model, prompt strength on how the LoRA changes the meaning of words. Negative values reverse “slider” LoRAs."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if let info, !info.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What the file says").font(.caption.weight(.semibold))
                            ForEach(info.notes, id: \.self) { Text($0) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if let notes = app.library.loraNotes[slot.name]?.notes, !notes.isEmpty {
                        Text(notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!slot.enabled)
            .opacity(slot.enabled ? 1 : 0.5)
        }
        .padding(.vertical, 2)
        .task(id: slot.name) { await app.inspectLora(slot.name) }
        // Only a file picked here fills in the triggers and strength; a row
        // that just appears keeps what it has. What was written on the LoRA
        // info page wins over what the file says.
        .onChange(of: slot.name) { _, name in
            Task {
                let info = await app.inspectLora(name)
                guard slot.name == name else { return }
                if let note = app.library.loraNotes[name], note.edited {
                    slot.triggers = note.triggers
                    slot.strength = note.strength
                    slot.clipStrength = note.clipStrength
                } else if let info {
                    slot.triggers = info.triggers.first ?? ""
                    slot.strength = info.strength
                }
            }
        }
        .sheet(isPresented: $choosing) {
            LorasView(start: slot.name, pick: { slot.name = $0 }, family: family)
        }
    }

    private func summary(_ info: LoraInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let own = info.family { Badge(text: own.label) }
                Badge(text: info.kind.label)
            }
            if let family, let problem = info.mismatch(with: family) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .help(info.notes.joined(separator: "\n"))
    }

    /// Further trigger words and telling training tags, one click to add.
    @ViewBuilder private func offers(_ info: LoraInfo) -> some View {
        let used = Set(slot.triggers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let more = (info.triggers + info.suggestions).filter { !used.contains($0.lowercased()) }
        if !more.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    Text("Add:").font(.caption).foregroundStyle(.secondary)
                    ForEach(more, id: \.self) { tag in
                        Button(tag) { add(tag) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .help("Add “\(tag)” to the trigger words")
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func add(_ tag: String) {
        let current = slot.triggers.trimmingCharacters(in: .whitespaces)
        slot.triggers = current.isEmpty ? tag : "\(current), \(tag)"
    }

    private var separateClip: Binding<Bool> {
        Binding(get: { slot.clipStrength != nil }, set: { slot.clipStrength = $0 ? slot.strength : nil })
    }

    private var clipBinding: Binding<Double> {
        Binding(get: { slot.clipStrength ?? slot.strength }, set: { slot.clipStrength = $0 })
    }
}

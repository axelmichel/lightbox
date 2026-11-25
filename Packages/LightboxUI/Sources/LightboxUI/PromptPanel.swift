import LightboxCore
import SwiftUI

/// The prompt and negative under the gallery, as tabs, with the styles,
/// the prompt helper and Generate.
struct PromptPanel: View {
    enum Tab: Hashable {
        case prompt
        case negative
    }

    @Environment(AppModel.self) private var app
    @State private var tab = Tab.prompt

    var body: some View {
        @Bindable var gen = app.generation
        let preset = gen.preset(in: app.library)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Prompt", selection: $tab) {
                    Text("Prompt").tag(Tab.prompt)
                    Text(gen.negative.isEmpty ? "Negative" : "Negative •").tag(Tab.negative)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if tab == .prompt { helper }
            }
            if tab == .prompt, let suggestion = gen.suggestion {
                SuggestionBar(text: suggestion)
            }
            Group {
                switch tab {
                case .prompt:
                    PromptEditor(
                        text: $gen.prompt, title: "Prompt",
                        placeholder: preset?.dialect == .tags
                            ? "1girl, red scarf, snowy forest, looking at viewer"
                            : "A red fox in a snowy forest at dawn")
                case .negative:
                    PromptEditor(text: $gen.negative, title: "Negative", placeholder: "Added to the preset's negative")
                }
            }
            .frame(maxHeight: .infinity)
            actionBar(preset)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Enhance, with an optional wish, and Undo after a suggestion was used.
    @ViewBuilder private var helper: some View {
        @Bindable var gen = app.generation
        let ready = !app.ollamaModel.isEmpty
        if gen.promptBeforeSuggestion != nil {
            Button("Undo", systemImage: "arrow.uturn.backward") { gen.undoSuggestion() }
                .help("Back to the prompt before the suggestion")
        }
        TextField("Wish", text: $gen.enhanceDirection, prompt: Text("optional: make it rainy"))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
            .disabled(!ready)
            .onSubmit { Task { await gen.enhance(app) } }
        if gen.enhancing {
            ProgressView().controlSize(.small)
        }
        Button("Enhance", systemImage: "sparkles") { Task { await gen.enhance(app) } }
            .disabled(!ready || gen.enhancing)
            .help(
                ready
                    ? "Rewrite the prompt for the preset's model with \(app.ollamaModel)"
                    : "Choose a model for the prompt helper (Ollama) in the Settings")
    }

    private func actionBar(_ preset: GenerationPreset?) -> some View {
        let gen = app.generation
        let preview = gen.previewPrompt(app)
        let blocked: String? = if case .failure(let e) = preview { e.description } else { nil }
        return VStack(alignment: .leading, spacing: 6) {
            if case .failed(let message) = gen.state {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { gen.dismissError() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            } else if let blocked {
                Label(blocked, systemImage: "hand.raised").font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 6) {
                if let preset {
                    ForEach(ModifierCategory.active(for: preset.style), id: \.self) { category in
                        ModifierPicker(category: category)
                    }
                }
                Spacer(minLength: 8)
                Text("Saves to \(app.gallery.targetFolder?.name ?? "All Pictures")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if gen.isRunning {
                    Button("Cancel", role: .cancel) { gen.cancel() }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("Generate") { gen.generate(app) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!app.isConnected || preset == nil || blocked != nil)
                }
            }
        }
    }
}

/// A prompt box that fills the space it gets.
private struct PromptEditor: View {
    @Binding var text: String
    let title: String
    let placeholder: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
            .accessibilityLabel(title)
    }
}

/// The prompt helper's rewrite, to use or throw away.
private struct SuggestionBar: View {
    let text: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let gen = app.generation
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            ScrollView {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
            VStack(alignment: .trailing, spacing: 4) {
                Button("Use") { gen.useSuggestion() }
                    .buttonStyle(.borderedProminent)
                HStack(spacing: 4) {
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await gen.enhance(app) } }
                        .labelStyle(.iconOnly)
                        .help("Ask for another rewrite")
                        .disabled(gen.enhancing)
                    Button("Discard", systemImage: "xmark") { gen.suggestion = nil }
                        .labelStyle(.iconOnly)
                        .help("Keep the prompt as it is")
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One category of styles (camera, light, film, comic): the choice, and a
/// popover with the styles and their previews.
struct ModifierPicker: View {
    let category: ModifierCategory
    @Environment(AppModel.self) private var app
    @State private var open = false
    @State private var editing: StylesView.Start?

    var body: some View {
        let gen = app.generation
        let chosen = gen.modifier(for: category, in: app.library)
        Button {
            open = true
        } label: {
            Label(chosen?.name ?? category.label, systemImage: category.icon)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(chosen == nil ? nil : .accentColor)
        .help(chosen.map { "\(category.label): \($0.positive)" } ?? "Choose a \(category.label.lowercased()) style")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ModifierGrid(category: category) { start in
                open = false
                editing = start
            }
        }
        .sheet(item: $editing) { start in
            StylesView(start: start)
        }
    }
}

/// The styles of one category as cards with their previews.
private struct ModifierGrid: View {
    let category: ModifierCategory
    let edit: (StylesView.Start) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let gen = app.generation
        let styles = app.library.modifiers.filter { $0.category == category }
        VStack(alignment: .leading, spacing: 10) {
            Text(category.label).font(.headline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    card(
                        name: "None", image: nil, icon: "nosign",
                        selected: gen.modifier(for: category, in: app.library) == nil
                    ) {
                        gen.modifierIDs[category] = nil
                    }
                    ForEach(styles) { m in
                        card(
                            name: m.name, image: app.previews[m.id], icon: category.icon,
                            selected: gen.modifierIDs[category] == m.id
                        ) {
                            gen.modifierIDs[category] = m.id
                        }
                        .help(m.positive)
                    }
                }
            }
            .frame(maxHeight: 360)
            Divider()
            HStack {
                Button("New Style…", systemImage: "plus") { edit(.new(category)) }
                Spacer()
                Button("Edit Styles…") { edit(.existing(gen.modifierIDs[category] ?? styles.first?.id)) }
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(width: 340)
    }

    private func card(name: String, image: CGImage?, icon: String, selected: Bool, pick: @escaping () -> Void)
        -> some View
    {
        Button(action: pick) {
            VStack(spacing: 4) {
                StylePreview(image: image, icon: icon)
                    .frame(width: 96, height: 96)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                Text(name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: 96)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A style's preview picture, or its category's symbol when it has none.
struct StylePreview: View {
    let image: CGImage?
    let icon: String

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: icon).font(.title2).foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

import ComfyKit
import LightboxCore
import SwiftUI

/// Everything a picture was made with, and buttons to make another like it.
struct RecipeInfoView: View {
    let item: GalleryItem
    /// Called after loading the settings into the Generate form.
    var onUse: () -> Void = {}
    @Environment(AppModel.self) private var app
    @State private var showSent = false
    /// The guide pictures, by file name.
    @State private var guideImages: [String: CGImage] = [:]

    var body: some View {
        let r = item.recipe
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    HStack {
                        Badge(text: r.preset.style.label, color: .accentColor)
                        Badge(text: "\(item.width) × \(item.height)")
                        if item.isCutOut { Badge(text: "Cut-out") }
                        if item.folderID != nil {
                            Badge(text: app.gallery.index.path(of: item.folderID!))
                        }
                    }
                    if let run = item.workflow {
                        Label(
                            run.file == nil ? "Workflow “\(run.name)”" : "Workflow “\(run.name)”, graph saved",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        .help(
                            run.file == nil
                                ? "Made with this node-graph workflow; later changes to it aren't recorded here"
                                : "The graph sent is kept with the picture")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags").font(.subheadline).foregroundStyle(.secondary)
                    TagEditor(ids: [item.id])
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button("Use Settings", systemImage: "slider.horizontal.3") { use(seed: true) }
                        .buttonStyle(.borderedProminent)
                        .help("Fill the Generate form with these settings, including the seed")
                    HStack {
                        Button("New Seed", systemImage: "dice") { use(seed: false) }
                            .help("Same settings, a new seed")
                        Button("Use Seed", systemImage: "number") { app.useSeed(of: r) }
                    }
                    .buttonStyle(.bordered)
                }

                text("Prompt", r.prompt)
                if !r.negative.isEmpty { text("Negative", r.negative) }

                if !r.guides.isEmpty { guides(r.guides) }

                DisclosureGroup("Sent to ComfyUI", isExpanded: $showSent) {
                    VStack(alignment: .leading, spacing: 12) {
                        text("Positive", r.sent.positive)
                        text("Negative", r.sent.negative)
                    }
                    .padding(.top, 6)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(r.details.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)

                Button("Copy All Settings", systemImage: "doc.on.clipboard") { Pasteboard.copy(Self.json(r)) }
                    .buttonStyle(.bordered)
                    .help("Copy the settings as JSON")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task(id: item.id) {
            let store = app.gallery.store
            let recipe = item.recipe
            let data = await Task.detached { store.guideImages(of: recipe) }.value
            guideImages = data.compactMapValues { decode($0) }
        }
    }

    private func guides(_ uses: [GenerationRecipe.GuideUse]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Guides").font(.subheadline.weight(.semibold))
            ForEach(Array(uses.enumerated()), id: \.offset) { _, use in
                let kind = ControlKind(rawValue: use.kind)
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if let image = guideImages[use.image] {
                            FittedImage(image: image)
                        } else {
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Label(kind?.title ?? use.kind, systemImage: kind?.icon ?? "questionmark")
                        Text(Self.describe(use, kind)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func describe(_ use: GenerationRecipe.GuideUse, _ kind: ControlKind?) -> String {
        var parts = ["\(kind?.strengthLabel ?? "Strength") \(Int((use.strength * 100).rounded()))%"]
        if use.startPercent > 0 || use.endPercent < 1 {
            parts.append("from \(Int(use.startPercent * 100))% until \(Int(use.endPercent * 100))%")
        }
        if kind?.extractLabel != nil { parts.append(use.extract ? "extracted from the picture" : "picture used as is") }
        return parts.joined(separator: " · ")
    }

    private func text(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(value) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy \(title.lowercased())")
            }
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func use(seed: Bool) {
        app.useSettings(of: item.recipe, includingSeed: seed)
        onUse()
    }

    static func json(_ recipe: GenerationRecipe) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(recipe)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

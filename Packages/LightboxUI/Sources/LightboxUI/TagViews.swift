import LightboxCore
import SwiftUI

/// The tags of one or more pictures: each as a chip that takes it off
/// them, a field to add one, and the gallery's other tags to pick from.
struct TagEditor: View {
    let ids: Set<UUID>
    @Environment(AppModel.self) private var app
    @State private var text = ""

    var body: some View {
        let gallery = app.gallery
        let items = gallery.index.items.filter { ids.contains($0.id) }
        let present = tags(on: items)
        VStack(alignment: .leading, spacing: 8) {
            if present.isEmpty {
                Text(ids.count == 1 ? "No tags yet." : "None of these pictures has a tag yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(present, id: \.tag) { entry in
                        TagChip(
                            tag: entry.tag,
                            note: ids.count > 1 && entry.count < items.count ? "\(entry.count) of \(items.count)" : nil
                        ) { gallery.removeTag(entry.tag, from: ids) }
                    }
                }
            }
            HStack {
                TextField("Add a tag", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(gallery.index.normalized(tag: text) == nil)
            }
            let suggestions = suggestions(excluding: present, items: items)
            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button("#\(tag)") { gallery.addTag(tag, to: ids) }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                }
            }
        }
    }

    private func add() {
        // Several at once, separated by commas.
        for part in text.split(separator: ",") { app.gallery.addTag(String(part), to: ids) }
        text = ""
    }

    /// The tags on any of the pictures, with how many have each.
    private func tags(on items: [GalleryItem]) -> [(tag: String, count: Int)] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for item in items {
            for tag in item.tagList { counts[tag.lowercased(), default: (tag, 0)].count += 1 }
        }
        return counts.values.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// The gallery's tags not yet on all the pictures, starting with what
    /// is typed, most used first.
    private func suggestions(excluding present: [(tag: String, count: Int)], items: [GalleryItem]) -> [String] {
        let full = Set(present.filter { $0.count == items.count }.map { $0.tag.lowercased() })
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return app.gallery.index.allTags
            .filter { !full.contains($0.tag.lowercased()) && (typed.isEmpty || $0.tag.lowercased().hasPrefix(typed)) }
            .sorted { $0.count > $1.count }
            .prefix(12)
            .map(\.tag)
    }
}

/// A tag with a button that removes it.
private struct TagChip: View {
    let tag: String
    var note: String?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
            if let note { Text(note).foregroundStyle(.secondary) }
            Button("Remove", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Take “\(tag)” off")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

/// Tags for the pictures a menu was opened on.
struct TagsSheet: View {
    let ids: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TagEditor(ids: ids)
            }
            .formStyle(.grouped)
            .navigationTitle(ids.count == 1 ? "Tags" : "Tags for \(ids.count) Pictures")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 280)
        #endif
    }
}

/// Lays its views out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing = 6.0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * Double(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width = 0.0
        var height = 0.0
    }

    private func rows(_ subviews: Subviews, width: Double) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra =
                rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

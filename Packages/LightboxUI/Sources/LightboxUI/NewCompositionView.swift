import LightboxCore
import SwiftUI

/// Starting a composition: a blank canvas of a chosen size, or pictures
/// from the gallery as its first layers (the first sets the size).
struct NewCompositionView: View {
    private enum Start: Hashable {
        case blank, gallery
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var start = Start.blank
    @State private var width = 1024
    @State private var height = 1024
    @State private var search = ""
    /// In the order clicked: the first is the lowest layer.
    @State private var picked: [UUID] = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("Start", selection: $start) {
                Text("Blank").tag(Start.blank)
                Text("From the Gallery").tag(Start.gallery)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            Divider()
            switch start {
            case .blank: blank
            case .gallery: gallery
            }
            Divider()
            HStack {
                if start == .gallery {
                    Text(picked.isEmpty ? "Click pictures to add them." : "\(picked.count) selected")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    if start == .blank {
                        app.compositions.create(size: (width, height))
                    } else {
                        app.compositions.create(with: picked)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(start == .gallery && picked.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: start == .blank ? 220 : 520)
    }

    private var blank: some View {
        Form {
            LabeledContent("Size") {
                SizeFields(width: $width, height: $height)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 120)
    }

    private var gallery: some View {
        let items = app.gallery.index.items.filter { $0.matches(search) }
        return VStack(spacing: 0) {
            TextField("Search prompt, model, seed or #tag", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)], spacing: 8) {
                    ForEach(items) { item in
                        ThumbnailCell(item: item, selected: picked.contains(item.id))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .topTrailing) {
                                if let n = picked.firstIndex(of: item.id) {
                                    Text("\(n + 1)")
                                        .font(.caption.bold()).monospacedDigit()
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor, in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(6)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(item.id) }
                    }
                }
                .padding(10)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No Pictures" : "Nothing Found", systemImage: "photo.on.rectangle.angled")
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
    }
}

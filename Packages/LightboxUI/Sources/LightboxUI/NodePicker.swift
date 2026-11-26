import ComfyKit
import SwiftUI

/// Picks a node of the server's to add to the graph: a few useful ones
/// first, any of them by search (`NodeSearch`).
struct NodePicker: View {
    let catalog: ComfyCatalog
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let results = NodeSearch.results(query, in: catalog)
        NavigationStack {
            List {
                Section(query.isEmpty ? "Suggested" : "Found") {
                    ForEach(results, id: \.self) { type in
                        Button {
                            pick(type)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(catalog.nodes[type]?.displayName ?? type)
                                Text(
                                    [type, catalog.nodes[type]?.category ?? ""].filter { !$0.isEmpty }.joined(
                                        separator: " · ")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search all of the server's nodes")
            .overlay {
                if results.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "No Nodes", systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("Connect to the server to see its nodes."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Add Node")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 480)
        #endif
    }
}

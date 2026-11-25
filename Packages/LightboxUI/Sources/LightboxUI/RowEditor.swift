import ComfyKit
import SwiftUI

/// Edits one widget of the node graph, over its row: a field for numbers
/// (Return or clicking elsewhere takes it, Esc doesn't), a list for choices.
struct RowEditor: View {
    let target: RowEdit.Target
    /// The new value, or `nil` when the edit is given up.
    let done: (JSONValue?) -> Void

    @State private var text = ""
    @State private var choosing = true
    @State private var filter = ""
    @FocusState private var focused: Bool
    @State private var finished = false

    var body: some View {
        switch target.kind {
        case .number(let isInteger):
            TextField(target.input, text: $text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .focused($focused)
                .onAppear {
                    text = target.value
                    focused = true
                }
                .onSubmit { finish(RowEdit.number(text, isInteger: isInteger)) }
                #if os(macOS)
                    .onExitCommand { finish(nil) }
                #endif
                // Clicking elsewhere takes the value, as Return does.
                .onChange(of: focused) { _, now in
                    if !now { finish(RowEdit.number(text, isInteger: isInteger)) }
                }
        case .choice(let options):
            Color.clear
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    choices(options)
                }
                .onChange(of: choosing) { _, open in
                    if !open { finish(nil) }
                }
        }
    }

    private func choices(_ options: [String]) -> some View {
        let shown = filter.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(filter) }
        return VStack(spacing: 0) {
            if options.count > 8 {
                TextField("Search", text: $filter).textFieldStyle(.roundedBorder).padding(8)
            }
            List(shown, id: \.self) { option in
                Button {
                    finish(.string(option))
                } label: {
                    HStack {
                        Text(option).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if option == target.value { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 320, height: min(400, CGFloat(shown.count) * 28 + (options.count > 8 ? 60 : 16)))
    }

    /// Once only: Return, then the focus loss it causes, would finish twice.
    private func finish(_ value: JSONValue?) {
        guard !finished else { return }
        finished = true
        choosing = false
        done(value)
    }
}

/// Which widget of the graph can be edited and how, without the view.
enum RowEdit {
    struct Target: Hashable {
        enum Kind: Hashable {
            case number(isInteger: Bool)
            case choice([String])
        }

        var node: Int
        var input: String
        var kind: Kind
        var value: String
    }

    /// The row under `point` (canvas units), if it can be edited there.
    static func target(
        _ node: GraphNode, _ layout: NodeLayout, role: NodeRole?, at point: CGPoint, catalog: ComfyCatalog
    ) -> Target? {
        // By the row's rect: the seed's control row has the seed's name.
        guard let row = layout.rows.first(where: { $0.rect.contains(point) }), row.kind == .value,
            NodeRowText.isEditable(role, input: row.name), let spec = catalog.nodes[node.type],
            let input = spec.inputs[row.name]
        else { return nil }
        let value = NodeRowText.value(node.widgetValue(row.name, spec: spec))
        switch input.type {
        case "INT": return Target(node: node.id, input: row.name, kind: .number(isInteger: true), value: value)
        case "FLOAT": return Target(node: node.id, input: row.name, kind: .number(isInteger: false), value: value)
        case "COMBO" where !input.options.isEmpty:
            return Target(node: node.id, input: row.name, kind: .choice(input.options), value: value)
        default: return nil
        }
    }

    /// A typed number as the widget's value; `nil` if it isn't one.
    static func number(_ text: String, isInteger: Bool) -> JSONValue? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let d = Double(t), d.isFinite else { return nil }
        return isInteger ? .int(Int(d.rounded())) : .double(d)
    }
}

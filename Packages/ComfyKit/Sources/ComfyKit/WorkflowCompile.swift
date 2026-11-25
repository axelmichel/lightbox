// A UI-format workflow → the API format `/prompt` takes, as ComfyUI's
// frontend does it ("graphToPrompt"):
// - muted nodes (mode 2) are left out, and so are notes, reroutes and
//   primitive nodes, which only exist in the editor; a primitive's value
//   goes into the inputs it is linked to;
// - a link from a bypassed node (mode 4) comes from the bypassed node's
//   input of the same type instead;
// - a subgraph's nodes are put in its place with ids "<node>:<inner>";
// - only inputs the server lists are sent, plus linked ones.
// It also collects what the content guard needs: every text value, and
// whether it only reaches a sampler's negative input, and the LoRAs.

import Foundation

/// A node in the editor: the subgraph nodes it is inside, outermost
/// first, and its id there.
public struct NodePath: Hashable, Sendable {
    public var subgraphs: [Int]
    public var node: Int

    public init(_ node: Int, in subgraphs: [Int] = []) {
        self.subgraphs = subgraphs
        self.node = node
    }

    /// The id in the API format: "12" or "5:12".
    public var apiID: String { (subgraphs + [node]).map(String.init).joined(separator: ":") }

    public init?(apiID: String) {
        let parts = apiID.split(separator: ":").compactMap { Int($0) }
        guard let last = parts.last, parts.count == apiID.split(separator: ":").count else { return nil }
        self.init(last, in: Array(parts.dropLast()))
    }
}

public struct CompiledWorkflow: Equatable, Sendable {
    public struct Text: Equatable, Sendable {
        public var node: NodePath
        public var input: String
        public var text: String
        /// Reaches only `negative` inputs (of samplers, guiders).
        public var isNegative: Bool
    }

    public struct Problem: Equatable, Sendable {
        public var node: NodePath?
        public var message: String
    }

    public var graph = WorkflowGraph()
    public var texts: [Text] = []
    public var loraNames: [String] = []
    /// Why it can't run; empty = it can be queued.
    public var problems: [Problem] = []

    public var positiveTexts: [String] { texts.filter { !$0.isNegative }.map(\.text) }
    public var negativeTexts: [String] { texts.filter(\.isNegative).map(\.text) }

    /// Add terms to every negative prompt (what the content guard requires).
    /// Returns false if the workflow has no negative prompt to add them to.
    @discardableResult
    public mutating func addNegative(_ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        var added = false
        for (i, t) in texts.enumerated() where t.isNegative {
            let id = t.node.apiID
            guard var node = graph.nodes[id], case .string(let old)? = node.inputs[t.input] else { continue }
            let missing = terms.filter { !old.localizedCaseInsensitiveContains($0) }
            let text =
                ([old.trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespacesAndNewlines))]
                + missing).filter { !$0.isEmpty }.joined(separator: ", ")
            node.inputs[t.input] = .string(text)
            graph.set(id, node)
            texts[i].text = text
            added = true
        }
        return added
    }
}

public enum WorkflowCompiler {
    /// Node kinds that only exist in the editor.
    public static let virtualTypes: Set<String> = ["Note", "MarkdownNote", "Reroute", "PrimitiveNode"]

    public static func compile(_ doc: WorkflowDocument, catalog: ComfyCatalog) -> CompiledWorkflow {
        var c = Compiler(doc: doc, catalog: catalog)
        c.compile(Scope(graph: doc.graph, path: [], parent: nil, instance: nil))
        c.collectTexts()
        if !c.out.graph.nodes.isEmpty,
            !c.out.graph.nodes.values.contains(where: { catalog.nodes[$0.classType]?.isOutputNode == true })
        {
            c.out.problems.append(.init(node: nil, message: "The workflow has no output node, such as Save Image."))
        } else if c.out.graph.nodes.isEmpty {
            c.out.problems.append(.init(node: nil, message: "The workflow has no nodes that run."))
        }
        return c.out
    }

    /// A graph and where it sits: the root, or a subgraph inside `instance`.
    final class Scope {
        let graph: NodeGraph
        let path: [Int]
        let parent: Scope?
        let instance: GraphNode?

        init(graph: NodeGraph, path: [Int], parent: Scope?, instance: GraphNode?) {
            self.graph = graph
            self.path = path
            self.parent = parent
            self.instance = instance
        }
    }

    enum Source {
        case output(String, Int)
        case value(JSONValue)
        case none
    }

    struct Compiler {
        let doc: WorkflowDocument
        let catalog: ComfyCatalog
        var out = CompiledWorkflow()
        var origins: [String: NodePath] = [:]

        mutating func compile(_ scope: Scope) {
            guard scope.path.count < 8 else { return }
            for node in scope.graph.nodes {
                let path = NodePath(node.id, in: scope.path)
                if WorkflowCompiler.virtualTypes.contains(node.type) || node.mode == .never || node.mode == .bypass {
                    continue
                }
                if let def = doc.subgraph(node.type) {
                    compile(Scope(graph: def.graph, path: scope.path + [node.id], parent: scope, instance: node))
                    continue
                }
                guard let spec = catalog.nodes[node.type] else {
                    let linked = node.inputs.contains { $0.link != nil } || node.outputs.contains { !$0.links.isEmpty }
                    // Unlinked unknown nodes are editor-only ones from custom
                    // node packs (labels, bookmarks).
                    if linked {
                        out.problems.append(.init(node: path, message: "“\(node.type)” isn't installed on the server."))
                    }
                    continue
                }
                var inputs: [String: NodeInput] = [:]
                if case .array(let values)? = node.widgetsValues {
                    for (name, i) in WidgetLayout.slots(spec, values: values).values {
                        inputs[name] = Self.input(values[i], spec.inputs[name])
                    }
                } else if case .object(let values)? = node.widgetsValues {
                    for (name, v) in values where spec.inputs[name]?.isWidget == true {
                        inputs[name] = Self.input(v, spec.inputs[name])
                    }
                }
                for slot in node.inputs {
                    guard let link = slot.link else { continue }
                    let name = slot.widget ?? slot.name
                    switch resolve(link, in: scope) {
                    case .output(let id, let s): inputs[name] = .link(id, s)
                    case .value(let v): inputs[name] = Self.input(v, spec.inputs[name])
                    case .none: if spec.inputs[name]?.isLink == true { inputs[name] = nil }
                    }
                }
                for name in spec.required where inputs[name] == nil {
                    let label = node.title ?? spec.displayName ?? node.type
                    out.problems.append(.init(node: path, message: "“\(label)” needs its \(name) input linked."))
                }
                out.graph.set(path.apiID, WorkflowNode(classType: node.type, inputs: inputs))
                origins[path.apiID] = path
            }
        }

        /// Where a link really comes from.
        func resolve(_ linkID: Int, in scope: Scope, depth: Int = 0) -> Source {
            guard depth < 64, let link = scope.graph.link(linkID) else { return .none }
            if link.origin == GraphLink.subgraphInputID {
                guard let parent = scope.parent, let instance = scope.instance,
                    let def = doc.subgraph(instance.type), def.inputs.indices.contains(link.originSlot)
                else { return .none }
                let name = def.inputs[link.originSlot].name
                guard
                    let slot = instance.inputs.first(where: { $0.name == name })
                        ?? instance.inputs[safe: link.originSlot]
                else { return .none }
                if let outer = slot.link { return resolve(outer, in: parent, depth: depth + 1) }
                // A widget promoted to the subgraph node.
                if let v = promotedValue(instance, def: def, input: link.originSlot) { return .value(v) }
                return .none
            }
            guard let node = scope.graph.node(link.origin), node.mode != .never else { return .none }
            switch node.type {
            case "Reroute":
                return node.inputs.first?.link.map { resolve($0, in: scope, depth: depth + 1) } ?? .none
            case "PrimitiveNode":
                return node.widgetsValues?.array?.first.map(Source.value) ?? .none
            default: break
            }
            if node.mode == .bypass {
                let wanted = node.outputs[safe: link.originSlot]?.type ?? link.type
                let fits: (NodeInputSlot) -> Bool = { $0.link != nil && NodeGraph.accepts($0.type, from: wanted) }
                let input =
                    node.inputs[safe: link.originSlot].flatMap { fits($0) ? $0 : nil } ?? node.inputs.first(where: fits)
                return input?.link.map { resolve($0, in: scope, depth: depth + 1) } ?? .none
            }
            if let def = doc.subgraph(node.type) {
                let inner = Scope(graph: def.graph, path: scope.path + [node.id], parent: scope, instance: node)
                guard
                    let l = def.graph.links.first(where: {
                        $0.target == GraphLink.subgraphOutputID && $0.targetSlot == link.originSlot
                    })
                else { return .none }
                return resolve(l.id, in: inner, depth: depth + 1)
            }
            return .output(NodePath(node.id, in: scope.path).apiID, link.originSlot)
        }

        /// The value a subgraph node holds for an input that is a widget
        /// inside: in its widgets_values, in the order of such inputs.
        func promotedValue(_ instance: GraphNode, def: SubgraphDefinition, input: Int) -> JSONValue? {
            guard let values = instance.widgetsValues?.array else { return nil }
            let widgetInputs = def.inputs.indices.filter { i in
                instance.inputs.first(where: { $0.name == def.inputs[i].name })?.widget != nil
            }
            guard let k = widgetInputs.firstIndex(of: input), values.indices.contains(k) else { return nil }
            return values[k]
        }

        static func input(_ v: JSONValue, _ spec: InputSpec?) -> NodeInput {
            switch (spec?.type, v) {
            case ("INT", _): if let i = v.int { return .int(i) }
            case ("FLOAT", _): if let d = v.double { return .double(d) }
            case ("BOOLEAN", .bool(let b)): return .bool(b)
            case (_, .string(let s)): return .string(s)
            case (_, .bool(let b)): return .bool(b)
            case (_, .int(let i)): return .int(i)
            case (_, .double(let d)): return .double(d)
            default: break
            }
            return .json(v)
        }

        /// Text values and their role; LoRA names.
        mutating func collectTexts() {
            let nodes = out.graph.nodes
            for id in nodes.keys.sorted(by: { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }) {
                guard let node = nodes[id], let spec = catalog.nodes[node.classType], let path = origins[id] else {
                    continue
                }
                for (name, value) in node.inputs.sorted(by: { $0.key < $1.key }) {
                    guard case .string(let s) = value else { continue }
                    let type = spec.inputs[name]?.type
                    if name.hasPrefix("lora") && name.hasSuffix("name") {
                        out.loraNames.append(s)
                    } else if type == "STRING" || (type == nil && !s.isEmpty) {
                        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        out.texts.append(
                            .init(node: path, input: name, text: s, isNegative: Self.onlyNegative(id, nodes)))
                    }
                }
            }
        }

        /// Whether what node `id` makes ends up only in `negative` inputs.
        static func onlyNegative(_ id: String, _ nodes: [String: WorkflowNode]) -> Bool {
            var negative = false
            var positive = false
            var queue = [id]
            var seen: Set<String> = [id]
            while let current = queue.popLast() {
                for (other, node) in nodes {
                    for (name, input) in node.inputs {
                        guard case .link(let from, _) = input, from == current else { continue }
                        switch name {
                        case "negative": negative = true
                        case "positive": positive = true
                        default: if seen.insert(other).inserted { queue.append(other) }
                        }
                    }
                }
            }
            return negative && !positive
        }
    }
}

extension NodeGraph {
    /// After queueing: change seeds set to increment, decrement or
    /// randomize, as ComfyUI does ("control after generate").
    public mutating func applySeedControls(catalog: ComfyCatalog) {
        for i in nodes.indices {
            let n = nodes[i]
            if n.type == "PrimitiveNode" {
                guard case .array(var a)? = n.widgetsValues, a.count >= 2, let control = a[1].string,
                    let v = a[0].int
                else { continue }
                a[0] = .int(Self.next(v, control, min: 0, max: Self.seedMax))
                nodes[i].widgetsValues = .array(a)
                continue
            }
            guard let spec = catalog.nodes[n.type] else { continue }
            for (name, input) in spec.inputs where input.controlAfterGenerate {
                guard let control = n.controlValue(name, spec: spec), let v = n.widgetValue(name, spec: spec)?.int,
                    n.inputs.first(where: { $0.widget == name })?.link == nil
                else { continue }
                let next = Self.next(
                    v, control, min: Int(input.min ?? 0),
                    max: Int(Swift.min(input.max ?? Double(Self.seedMax), Double(Self.seedMax))))
                nodes[i].setWidgetValue(name, .int(next), spec: spec)
            }
        }
    }

    /// The frontend's largest random seed.
    static let seedMax = 1_125_899_906_842_624

    static func next(_ v: Int, _ control: String, min: Int, max: Int) -> Int {
        switch control {
        case "increment": return v >= max ? min : v + 1
        case "decrement": return v <= min ? max : v - 1
        case "randomize": return Int.random(in: min...Swift.max(min, max))
        default: return v
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

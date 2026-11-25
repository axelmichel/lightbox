// What each node of a standard graph is for, so the node editor can tell
// the parts Lightbox manages from ones the user added, and find the ends
// of the chains (anchors) that added nodes hang on.

/// The part of the generation a node built by `WorkflowBuilder` belongs to.
/// Written as text, e.g. "lora:styles/b.safetensors" or "guide.loader:0".
public struct NodeRole: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, CaseIterable, Sendable {
        case checkpoint, diffusionModel, textEncoders, vae, lora, shift, clipSkip
        case positive, guidance, reference, negative
        case guide, latent, inpaint, sampler, vaeDecode, faceFix, handFix, output
    }

    /// A helper node of a role made of several; the main node has none.
    public enum Part: String, CaseIterable, Sendable {
        case image, extract, loader, unionType, clipVision, encode, mask
        case noise, guider, select, scheduler, sigmas, detector
    }

    public var kind: Kind
    public var part: Part?
    /// Which one, for roles that repeat: the LoRA's name, or the guide's or
    /// reference's position in the request.
    public var key: String?

    public init(_ kind: Kind, _ part: Part? = nil, key: String? = nil) {
        self.kind = kind
        self.part = part
        self.key = key
    }

    /// Reads `description`; `nil` for anything else.
    public init?(_ text: String) {
        // The key comes last and may hold anything (LoRA names have
        // folders and dots), so it is split off first.
        let colon = text.firstIndex(of: ":")
        let head = colon.map { text[..<$0] } ?? Substring(text)
        let names = head.split(separator: ".", omittingEmptySubsequences: false)
        guard names.count <= 2, let kind = Kind(rawValue: String(names[0])) else { return nil }
        self.kind = kind
        if names.count == 2 {
            guard let part = Part(rawValue: String(names[1])) else { return nil }
            self.part = part
        }
        key = colon.map { String(text[text.index(after: $0)...]) }
    }

    public var description: String {
        kind.rawValue + (part.map { "." + $0.rawValue } ?? "") + (key.map { ":" + $0 } ?? "")
    }
}

/// The ends of a standard graph's chains: what the sampler (or for
/// `image`, the output) takes. Nodes the user adds connect to these, so
/// they stay connected when the chain grows.
public enum Anchor: String, CaseIterable, Sendable {
    case model, clip, vae, positive, negative, latent, image
}

/// A graph from `WorkflowBuilder` with the role of every node.
public struct BuiltWorkflow: Equatable, Sendable {
    public var graph: WorkflowGraph
    /// By node id.
    public var roles: [String: NodeRole]
    public var anchors: [Anchor: Output]

    /// Ids of the nodes with the role, in creation order.
    public func ids(_ role: NodeRole) -> [String] {
        roles.filter { $0.value == role }.map(\.key).sorted {
            $0.count != $1.count ? $0.count < $1.count : $0 < $1
        }
    }
}

/// Builds a graph and notes each node's role as it is added.
struct RoleRecorder {
    var graph = WorkflowGraph()
    var roles: [String: NodeRole] = [:]

    @discardableResult
    mutating func add(
        _ role: NodeRole, _ classType: String, _ inputs: [String: NodeInput], defaultsFrom catalog: ComfyCatalog? = nil
    ) -> String {
        let id =
            if let catalog { graph.add(classType, inputs, defaultsFrom: catalog) } else { graph.add(classType, inputs) }
        roles[id] = role
        return id
    }
}

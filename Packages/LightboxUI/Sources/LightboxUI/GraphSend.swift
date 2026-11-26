import ComfyKit
import Foundation
import LightboxCore

/// The one way a graph from the node editor reaches ComfyUI. Whatever the
/// graph holds, every text in it goes through the content guard first.
enum GraphSend {
    struct Problem: Error, Equatable {
        var message: String
    }

    /// The API graph for `doc`: compiled as ComfyUI's frontend does, then
    /// every text it sends (positive, or negative where it only reaches
    /// negative inputs) checked with the LoRA names, and the negatives the
    /// guard asks for added. Nothing is sent if the compiler finds problems.
    static func prepare(_ doc: WorkflowDocument, catalog: ComfyCatalog, rating: ContentRating)
        -> Result<CompiledWorkflow, Problem>
    {
        var compiled = WorkflowCompiler.compile(doc, catalog: catalog)
        if let problem = compiled.problems.first {
            let node = problem.node.map { "Node #\($0.apiID): " } ?? ""
            return .failure(Problem(message: node + problem.message))
        }
        let result: GuardResult
        do {
            result = try ContentGuard.check(
                GuardInput(
                    positive: compiled.positiveTexts, negative: compiled.negativeTexts, loraNames: compiled.loraNames,
                    rating: rating))
        } catch {
            return .failure(Problem(message: error.description))
        }
        guard compiled.addNegative(result.forcedNegatives) else {
            return .failure(
                Problem(message: "The graph needs a negative prompt for the safety terms this picture requires."))
        }
        return .success(compiled)
    }

    /// The node of the graph view an API id belongs to: "12", or for a node
    /// inside a subgraph "5:12", the subgraph's node 5.
    static func viewNode(_ apiID: String) -> Int? {
        apiID.split(separator: ":").first.flatMap { Int($0) }
    }

    /// What the server said about which node, by node of the graph view.
    static func nodeMessages(_ error: Error) -> [Int: String] {
        guard let error = error as? WorkflowRunError else { return [:] }
        var out: [Int: String] = [:]
        switch error {
        case .rejected(_, let nodes):
            for (id, messages) in nodes {
                guard let node = viewNode(id) else { continue }
                out[node] = ((out[node].map { [$0] } ?? []) + messages).joined(separator: "\n")
            }
        case .failed(let id, _, let message):
            if let node = id.flatMap(viewNode) { out[node] = message }
        }
        return out
    }

    /// The graph a request makes: the preset's template filled in, or the
    /// one `WorkflowBuilder` builds.
    static func standardGraph(_ request: GenerationRequest, template: WorkflowDocument?, catalog: ComfyCatalog)
        throws(WorkflowDocumentError) -> WorkflowDocument
    {
        if let template { return template.filled(with: request, catalog: catalog) }
        return try WorkflowDocument(WorkflowBuilder.build(request, catalog: catalog), catalog: catalog)
    }

    /// The graph as run, for the gallery's `workflow-runs/`:
    /// `{"workflow": <UI format>, "prompt": <API format>}`.
    static func runFile(_ doc: WorkflowDocument, _ graph: WorkflowGraph) throws -> Data {
        let prompt = JSONValue.parse(try graph.jsonData()) ?? .object([:])
        return try JSONValue.object(["workflow": doc.json(), "prompt": prompt]).data()
    }
}

/// Saying what a workflow lacks to be a template.
enum TemplateText {
    static func missing(_ kinds: [NodeRole.Kind]) -> String {
        let names = kinds.map { kind -> String in
            switch kind {
            case .checkpoint, .diffusionModel: "model loader"
            case .positive: "prompt (CLIP Text Encode)"
            case .sampler: "sampler"
            case .latent: "empty latent"
            case .vaeDecode: "VAE Decode"
            case .output: "output (Save or Preview Image)"
            default: kind.rawValue
            }
        }
        return "no " + names.joined(separator: ", no ")
    }

    /// What Lightbox fills in of a template.
    static func found(_ kinds: Set<NodeRole.Kind>) -> String {
        let parts: [(NodeRole.Kind, String)] = [
            (.positive, "prompt"), (.negative, "negative"), (.sampler, "sampling"), (.latent, "size"),
            (.lora, "LoRAs"), (.checkpoint, "model"), (.diffusionModel, "model"), (.textEncoders, "text encoders"),
            (.vae, "VAE"), (.guidance, "guidance"), (.shift, "shift"), (.clipSkip, "CLIP skip"),
        ]
        var seen: Set<String> = []
        return parts.filter { kinds.contains($0.0) }.map(\.1).filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}

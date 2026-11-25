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

    /// The graph as run, for the gallery's `workflow-runs/`:
    /// `{"workflow": <UI format>, "prompt": <API format>}`.
    static func runFile(_ doc: WorkflowDocument, _ graph: WorkflowGraph) throws -> Data {
        let prompt = JSONValue.parse(try graph.jsonData()) ?? .object([:])
        return try JSONValue.object(["workflow": doc.json(), "prompt": prompt]).data()
    }
}

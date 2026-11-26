import ComfyKit
import Foundation
import LightboxCore
import Testing

@testable import LightboxUI

/// The cut-down Krita-style server the ComfyKit tests use.
private func catalog() throws -> ComfyCatalog {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../ComfyKit/Tests/ComfyKitTests/Fixtures/object_info.json").standardized
    return try ComfyCatalog(objectInfo: Data(contentsOf: url))
}

private func request(_ positive: String, negative: String = "lowres") -> GenerationRequest {
    GenerationRequest(
        checkpoint: "Sample_Illustrious_v1.safetensors", loras: [LoraRequest(name: "a.safetensors", strength: 0.8)],
        positive: positive, negative: negative, width: 832, height: 1216, seed: 42)
}

private func graph(_ r: GenerationRequest, _ c: ComfyCatalog) throws -> WorkflowDocument {
    try WorkflowDocument(WorkflowBuilder.build(r, catalog: c), catalog: c)
}

/// The text of the negative prompt node, as sent.
private func negative(_ compiled: CompiledWorkflow) -> String? {
    compiled.texts.first(where: \.isNegative).flatMap { t in
        compiled.graph.nodes[t.node.apiID]?.inputs[t.input].flatMap {
            if case .string(let s) = $0 { s } else { nil }
        }
    }
}

@Test func aNormalGraphIsSentAsBuilt() throws {
    let c = try catalog()
    let r = request("a lighthouse on a cliff at dusk")
    let compiled = try GraphSend.prepare(try graph(r, c), catalog: c, rating: .mature).get()
    #expect(compiled.positiveTexts == ["a lighthouse on a cliff at dusk"])
    #expect(negative(compiled) == "lowres")
    #expect(compiled.loraNames == ["a.safetensors"])
}

@Test func theGuardBlocksWhatComposeWould() throws {
    let c = try catalog()
    guard case .failure(let problem) = GraphSend.prepare(try graph(request("loli"), c), catalog: c, rating: .mature)
    else {
        Issue.record("should be blocked")
        return
    }
    #expect(!problem.message.isEmpty)
}

@Test func forcedNegativesAreAdded() throws {
    let c = try catalog()
    let r = request("a child playing in the garden")
    let compiled = try GraphSend.prepare(try graph(r, c), catalog: c, rating: .mature).get()
    let sent = try #require(negative(compiled))
    #expect(sent.hasPrefix("lowres"))
    for term in ContentGuard.minorNegatives { #expect(sent.localizedCaseInsensitiveContains(term), "\(term)") }
}

@Test func aGraphWithoutANegativeCantTakeTheSafetyTerms() throws {
    let c = try catalog()
    var r = request("a child playing in the garden")
    r.split = SplitModelRequest(
        model: "flux1-krea-Q4.gguf", textEncoders: ["t5-xxl-encoder-Q4.gguf", "clip_l.safetensors"],
        clipType: "flux", vae: "ae.safetensors", guidance: 3.5, zeroNegative: true)
    guard case .failure(let problem) = GraphSend.prepare(try graph(r, c), catalog: c, rating: .mature) else {
        Issue.record("should be refused")
        return
    }
    #expect(problem.message.contains("negative"))
}

@Test func compilerProblemsStopTheSending() throws {
    let c = try catalog()
    var doc = try graph(request("a lighthouse"), c)
    // Without its output node there is nothing to run.
    let output = try #require(doc.roles.first { $0.value == NodeRole(.output) }?.key)
    doc.graph.removeNodes([output])
    guard case .failure(let problem) = GraphSend.prepare(doc, catalog: c, rating: .mature) else {
        Issue.record("should not be sent")
        return
    }
    #expect(problem.message.contains("output"))
}

/// Against the fake server (`tools/fake-comfyui`, see the README):
/// `COMFY_URL=http://localhost:8189 swift test --filter graphRunsOnTheServer`
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(1)))
func graphRunsOnTheServer() async throws {
    let c = try catalog()
    let base = try ComfyServer.normalizedURL(from: ProcessInfo.processInfo.environment["COMFY_URL"]!)
    let client = ComfyClient(baseURL: base)
    let doc = try graph(request("a child playing in the garden"), c)
    let compiled = try GraphSend.prepare(doc, catalog: c, rating: .mature).get()
    var promptID: String?
    var pictures: [GeneratedImage] = []
    var running: [String] = []
    for try await event in client.generate(compiled.graph, workflow: doc.json()) {
        if case .queued(let id) = event { promptID = id }
        if case .finished(let images) = event { pictures = images }
        if case .node(let id) = event { running.append(id) }
    }
    #expect(!pictures.isEmpty)
    // The running nodes are the graph's own, so the view can mark them.
    #expect(!running.isEmpty)
    #expect(running.allSatisfy { compiled.graph.nodes[$0] != nil })
    // The safety terms arrived with the prompt.
    let id = try #require(promptID)
    let (data, _) = try await URLSession.shared.data(from: base.appending(path: "history/\(id)"))
    let history = try #require(JSONValue.parse(data)?[id]?["prompt"]?.array)
    let sent = try #require(history[2].object)
    let texts = sent.values.compactMap { $0["inputs"]?["text"]?.string }
    #expect(texts.contains { $0.contains(ContentGuard.minorNegatives[0]) })
}

@Test func theRunFileHoldsBothFormats() throws {
    let c = try catalog()
    let doc = try graph(request("a lighthouse"), c)
    let compiled = try GraphSend.prepare(doc, catalog: c, rating: .mature).get()
    let file = try #require(JSONValue.parse(try GraphSend.runFile(doc, compiled.graph)))
    // The UI format, as ComfyUI opens it, and the API format as sent.
    #expect(file["workflow"]?["nodes"]?.array?.count == doc.graph.nodes.count)
    #expect(file["prompt"]?.object?.count == compiled.graph.nodes.count)
    #expect(try WorkflowDocument(json: #require(file["workflow"])).roles == doc.roles)
}

@Test func serverErrorsLandOnTheirNodes() {
    #expect(GraphSend.viewNode("12") == 12)
    #expect(GraphSend.viewNode("5:12") == 5)  // inside subgraph node 5
    #expect(GraphSend.viewNode("x") == nil)
    let rejected = WorkflowRunError.rejected(
        message: "Prompt outputs failed validation",
        nodes: ["4": ["Value not in list: ckpt_name"], "5:2": ["Required input is missing: clip"]])
    #expect(
        GraphSend.nodeMessages(rejected) == [4: "Value not in list: ckpt_name", 5: "Required input is missing: clip"])
    let failed = WorkflowRunError.failed(node: "9", nodeType: "KSampler", message: "out of memory")
    #expect(GraphSend.nodeMessages(failed) == [9: "out of memory"])
    #expect(GraphSend.nodeMessages(WorkflowRunError.failed(node: nil, nodeType: nil, message: "x")).isEmpty)
    #expect(GraphSend.nodeMessages(GraphSend.Problem(message: "no")).isEmpty)
}

/// A model the server doesn't have: refused, with the message at its loader.
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(1)))
func serverRefusalsPointAtTheNode() async throws {
    let c = try catalog()
    let base = try ComfyServer.normalizedURL(from: ProcessInfo.processInfo.environment["COMFY_URL"]!)
    var r = request("a lighthouse")
    r.checkpoint = "not-on-the-server.safetensors"
    let doc = try graph(r, c)
    let compiled = try GraphSend.prepare(doc, catalog: c, rating: .mature).get()
    let loader = try #require(doc.roles.first { $0.value == NodeRole(.checkpoint) }?.key)
    do {
        for try await _ in ComfyClient(baseURL: base).generate(compiled.graph) {}
        Issue.record("should be refused")
    } catch {
        #expect(GraphSend.nodeMessages(error)[loader] != nil, "\(error)")
    }
}

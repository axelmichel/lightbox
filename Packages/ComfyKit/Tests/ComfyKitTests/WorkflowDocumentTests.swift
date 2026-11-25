import CoreGraphics
import Foundation
import Testing

@testable import ComfyKit

/// Node definitions with names, outputs and categories, cut down from a live `/object_info`.
func editorCatalog() throws -> ComfyCatalog {
    try ComfyCatalog(objectInfo: try fixture("object_info_editor"))
}

/// Saved by ComfyUI's frontend 1.49.6 (prompt replaced).
func frontendWorkflow() throws -> WorkflowDocument {
    try WorkflowDocument(data: try fixture("workflow_sdxl_frontend"))
}

/// JSON with numbers as doubles, and nulls and empty lists dropped, to
/// compare files that mean the same.
func normalized(_ v: JSONValue) -> JSONValue? {
    switch v {
    case .null: return nil
    case .int(let i): return .double(Double(i))
    case .array(let a): return a.isEmpty ? nil : .array(a.map { normalized($0) ?? .null })
    case .object(let o):
        let kept = o.compactMapValues(normalized)
        return .object(kept)
    default: return v
    }
}

@Test func readsNodeDefinitionsForTheEditor() throws {
    let c = try editorCatalog()
    let sampler = try #require(c.nodes["KSampler"])
    #expect(sampler.displayName == "KSampler")
    #expect(sampler.category == "model/sampling")
    #expect(sampler.outputs == [OutputSpec(type: "LATENT", name: "LATENT")])
    #expect(sampler.inputs["seed"]?.controlAfterGenerate == true)
    #expect(sampler.inputs["cfg"]?.step != nil)
    #expect(c.nodes["CheckpointLoaderSimple"]?.outputs.map(\.type) == ["MODEL", "CLIP", "VAE"])
    #expect(c.nodes["SaveImage"]?.isOutputNode == true)
    #expect(c.nodes["CLIPTextEncode"]?.inputs["text"]?.multiline == true)
    #expect(c.nodes["LoadImage"]?.inputs["image"]?.imageUpload == true)
}

@Test func keepsAFrontendFileWhenSavedAgain() throws {
    let original = try #require(JSONValue.parse(try fixture("workflow_sdxl_frontend")))
    let doc = try frontendWorkflow()
    #expect(doc.schema == .v04)
    #expect(doc.graph.nodes.count == 8)
    #expect(doc.graph.groups.map(\.title) == ["Prompt", "Image Size"])
    #expect(abs(doc.scale - 1.2346596950291526) < 1e-9)
    let saved = doc.json()
    #expect(normalized(saved) == normalized(original))
    #expect(try WorkflowDocument(data: try doc.data()) == doc)
}

@Test func matchesWidgetValuesToInputs() throws {
    let c = try editorCatalog()
    let doc = try frontendWorkflow()
    let sampler = try #require(doc.graph.node(12))
    let spec = c.nodes["KSampler"]
    #expect(sampler.widgetValue("seed", spec: spec) == .int(898_369_762_078_895))
    #expect(sampler.controlValue("seed", spec: spec) == "randomize")
    #expect(sampler.widgetValue("steps", spec: spec) == .int(27))
    #expect(sampler.widgetValue("denoise", spec: spec) == .int(1))

    // Older files have no seed control value.
    let short = WidgetLayout.slots(
        try #require(spec), values: [.int(5), .int(20), .double(7), .string("euler"), .string("normal"), .int(1)])
    #expect(short.values["steps"] == 1)
    #expect(short.controls["seed"] == nil)

    let load = try #require(c.nodes["LoadImage"])
    #expect(WidgetLayout.slots(load, values: [.string("fox.png"), .string("image")]).values == ["image": 0])
    #expect(WidgetLayout.slots(load, values: [.string("fox.png")]).values == ["image": 0])
    #expect(WidgetLayout.defaults(load).count == 2)
}

@Test func changesOneWidgetValue() throws {
    let c = try editorCatalog()
    var node = try #require(try frontendWorkflow().graph.node(12))
    node.setWidgetValue("steps", .int(30), spec: c.nodes["KSampler"])
    #expect(node.widgetsValues?.array?[2] == .int(30))
    #expect(node.widgetsValues?.array?[0] == .int(898_369_762_078_895))
    #expect(node.extra["widgets_values_named"]?["steps"] == .int(30))
}

@Test func compilesLikeTheFrontend() throws {
    let c = try editorCatalog()
    let compiled = WorkflowCompiler.compile(try frontendWorkflow(), catalog: c)
    #expect(compiled.problems.isEmpty)
    let g = compiled.graph
    // The note is left out.
    #expect(Set(g.nodes.keys) == ["7", "10", "11", "12", "13", "14", "15"])
    let sampler = try #require(g.nodes["12"])
    #expect(sampler.inputs["model"] == .link("15", 0))
    #expect(sampler.inputs["positive"] == .link("10", 0))
    #expect(sampler.inputs["negative"] == .link("11", 0))
    #expect(sampler.inputs["seed"] == .int(898_369_762_078_895))
    #expect(sampler.inputs["cfg"] == .double(5.5))
    #expect(sampler.inputs["sampler_name"] == .string("euler_ancestral"))
    #expect(sampler.inputs.count == 10)
    #expect(g.nodes["7"]?.inputs["filename_prefix"] == .string("sdxl_simple"))
    #expect(g.nodes["13"]?.inputs == ["width": .int(1024), "height": .int(1024), "batch_size": .int(1)])
    #expect(compiled.positiveTexts.contains { $0.contains("red fox") })
    #expect(compiled.negativeTexts == ["lowres, bad anatomy, bad hands, worst quality, watermark"])
}

@Test func textReachingBothSidesCountsAsPositive() throws {
    // Flux 2: the negative is the positive conditioning zeroed out.
    let c = try editorCatalog()
    let doc = try WorkflowDocument(data: try fixture("workflow_flux2_ui"))
    let compiled = WorkflowCompiler.compile(doc, catalog: c)
    #expect(compiled.problems.isEmpty)
    #expect(compiled.negativeTexts.isEmpty)
    #expect(!compiled.positiveTexts.isEmpty)
}

@Test func skipsMutedBypassedAndEditorOnlyNodes() throws {
    let c = try editorCatalog()
    var doc = try frontendWorkflow()
    var g = doc.graph
    // Checkpoint → LoRA (bypassed) → Reroute → sampler.
    let loraSpec = try #require(c.nodes["LoraLoader"])
    let lora = g.addNode("LoraLoader", spec: loraSpec, at: .zero)
    g.nodes[g.index(of: lora)!].mode = .bypass
    var reroute = GraphNode(id: 0, type: "Reroute")
    reroute.inputs = [NodeInputSlot(name: "", type: "*")]
    reroute.outputs = [NodeOutputSlot(name: "", type: "*")]
    let r = g.addNode(reroute)
    g.connect(from: 15, 0, to: lora, 0)
    g.connect(from: 15, 1, to: lora, 1)
    g.connect(from: lora, 0, to: r, 0)
    g.connect(from: r, 0, to: 12, 0)
    // A primitive node sets the steps.
    var primitive = GraphNode(id: 0, type: "PrimitiveNode")
    primitive.outputs = [NodeOutputSlot(name: "INT", type: "INT")]
    primitive.widgetsValues = .array([.int(12), .string("fixed")])
    let p = g.addNode(primitive)
    let sampler = try #require(g.node(12))
    let steps = try #require(sampler.inputs.firstIndex { $0.widget == "steps" })
    g.connect(from: p, 0, to: 12, steps)
    doc.graph = g
    let compiled = WorkflowCompiler.compile(doc, catalog: c)
    #expect(compiled.problems.isEmpty)
    #expect(compiled.graph.nodes["12"]?.inputs["model"] == .link("15", 0))
    #expect(compiled.graph.nodes["12"]?.inputs["steps"] == .int(12))
    #expect(compiled.graph.nodes["\(lora)"] == nil)
    #expect(compiled.graph.nodes["\(r)"] == nil)

    // Muting the decoder leaves Save Image without its input.
    doc.graph.nodes[doc.graph.index(of: 14)!].mode = .never
    let muted = WorkflowCompiler.compile(doc, catalog: c)
    #expect(muted.graph.nodes["14"] == nil)
    #expect(muted.problems.map(\.node) == [NodePath(7)])
}

@Test func reportsMissingNodesAndOutputs() throws {
    let c = try editorCatalog()
    var doc = try frontendWorkflow()
    doc.graph.nodes[doc.graph.index(of: 12)!].type = "FancySampler"
    let compiled = WorkflowCompiler.compile(doc, catalog: c)
    #expect(compiled.problems.contains { $0.node == NodePath(12) && $0.message.contains("isn't installed") })

    var empty = WorkflowDocument()
    let loader = try #require(c.nodes["CheckpointLoaderSimple"])
    empty.graph.addNode("CheckpointLoaderSimple", spec: loader, at: .zero)
    #expect(WorkflowCompiler.compile(empty, catalog: c).problems.map(\.message).contains { $0.contains("no output") })
}

@Test func compilesSubgraphs() throws {
    let c = try editorCatalog()
    var doc = try frontendWorkflow()
    // A subgraph holding a text encoder: clip and text in, conditioning out.
    var inner = NodeGraph()
    let encodeSpec = try #require(c.nodes["CLIPTextEncode"])
    let encode = inner.addNode("CLIPTextEncode", spec: encodeSpec, at: .zero)
    // The encoder's sockets are text (0), then clip (1).
    #expect(inner.nodes[0].inputs.map(\.name) == ["text", "clip"])
    inner.links = [
        GraphLink(id: 1, origin: GraphLink.subgraphInputID, originSlot: 0, target: encode, targetSlot: 1, type: "CLIP"),
        GraphLink(
            id: 2, origin: GraphLink.subgraphInputID, originSlot: 1, target: encode, targetSlot: 0, type: "STRING"),
        GraphLink(
            id: 3, origin: encode, originSlot: 0, target: GraphLink.subgraphOutputID, targetSlot: 0,
            type: "CONDITIONING"),
    ]
    inner.nodes[0].inputs[1].link = 1
    inner.nodes[0].inputs[0].link = 2
    inner.nodes[0].outputs[0].links = [3]
    inner.lastLinkID = 3
    let def = SubgraphDefinition(
        id: "6f1c3f0e-0000-4000-8000-000000000001", name: "Prompt", graph: inner,
        inputs: [
            SubgraphSlot(id: "a", name: "clip", type: "CLIP", linkIDs: [1]),
            SubgraphSlot(id: "b", name: "text", type: "STRING", linkIDs: [2]),
        ],
        outputs: [SubgraphSlot(id: "c", name: "CONDITIONING", type: "CONDITIONING", linkIDs: [3])])
    doc.subgraphs = [def]
    var node = GraphNode(id: 0, type: def.id)
    node.inputs = [
        NodeInputSlot(name: "clip", type: "CLIP"), NodeInputSlot(name: "text", type: "STRING", widget: "text"),
    ]
    node.outputs = [NodeOutputSlot(name: "CONDITIONING", type: "CONDITIONING")]
    node.widgetsValues = .array([.string("a lighthouse at night")])
    let s = doc.graph.addNode(node)
    doc.graph.connect(from: 15, 1, to: s, 0)
    doc.graph.connect(from: s, 0, to: 12, 1)

    let compiled = WorkflowCompiler.compile(doc, catalog: c)
    #expect(compiled.problems.isEmpty)
    let id = NodePath(encode, in: [s]).apiID
    #expect(compiled.graph.nodes["12"]?.inputs["positive"] == .link(id, 0))
    #expect(compiled.graph.nodes[id]?.inputs["clip"] == .link("15", 1))
    #expect(compiled.graph.nodes[id]?.inputs["text"] == .string("a lighthouse at night"))
    #expect(compiled.texts.contains { $0.node == NodePath(encode, in: [s]) && !$0.isNegative })

    // Subgraph definitions survive a save.
    let again = try WorkflowDocument(data: try doc.data())
    #expect(again.subgraphs == doc.subgraphs)
    #expect(NodePath(apiID: id) == NodePath(encode, in: [s]))
}

@Test func readsTheApiFormat() throws {
    let c = try editorCatalog()
    let api = WorkflowCompiler.compile(try frontendWorkflow(), catalog: c).graph
    let doc = try WorkflowDocument(api: try api.jsonData(), catalog: c)
    #expect(doc.graph.nodes.count == 7)
    // Loaders on the left, the sampler further right.
    #expect(try #require(doc.graph.node(15)).position.x < (try #require(doc.graph.node(12))).position.x)
    #expect(WorkflowCompiler.compile(doc, catalog: c).graph == api)
}

@Test func editsLinks() throws {
    let c = try editorCatalog()
    var g = try frontendWorkflow().graph
    // CLIP into MODEL doesn't fit.
    #expect(g.connect(from: 15, 1, to: 12, 0) == nil)
    // A new link into an input replaces the old one.
    let before = g.links.count
    let linked = g.connect(from: 11, 0, to: 12, 1)
    let id = try #require(linked)
    #expect(g.links.count == before)
    #expect(g.node(12)?.inputs[1].link == id)
    #expect(g.node(10)?.outputs[0].links == [])
    #expect(g.node(11)?.outputs[0].links.count == 2)

    g.removeNodes([12])
    #expect(!g.links.contains { $0.target == 12 || $0.origin == 12 })
    #expect(g.node(13)?.outputs[0].links == [])

    let copies = g.duplicate([10, 15], offset: CGVector(dx: 40, dy: 40))
    #expect(copies.count == 2)
    #expect(g.links.contains { $0.origin == copies[1] && $0.target == copies[0] })
    _ = c
}

@Test func changesSeedsAfterARun() throws {
    let c = try editorCatalog()
    var g = try frontendWorkflow().graph
    let i = try #require(g.index(of: 12))
    g.nodes[i].setControlValue("seed", "increment", spec: c.nodes["KSampler"])
    g.applySeedControls(catalog: c)
    #expect(g.nodes[i].widgetValue("seed", spec: c.nodes["KSampler"]) == .int(898_369_762_078_896))
    g.nodes[i].setControlValue("seed", "fixed", spec: c.nodes["KSampler"])
    g.applySeedControls(catalog: c)
    #expect(g.nodes[i].widgetValue("seed", spec: c.nodes["KSampler"]) == .int(898_369_762_078_896))
}

@Test func parsesNodeResultMessages() {
    #expect(
        ServerMessage.parse(
            text:
                #"{"type":"executed","data":{"node":"9","prompt_id":"p","output":{"images":[{"filename":"a.png","subfolder":"","type":"output"}]}}}"#
        ) == .executed(promptID: "p", node: "9", images: [ImageRef(file: "a.png")]))
    #expect(
        ServerMessage.parse(text: #"{"type":"execution_cached","data":{"nodes":["4","5"],"prompt_id":"p"}}"#)
            == .cached(promptID: "p", nodes: ["4", "5"]))
}

extension ClientTests {
    @Test func sendsTheEditorWorkflowWithThePrompt() async throws {
        StubProtocol.seen = []
        StubProtocol.respond = { _, _ in (200, Data(#"{"prompt_id":"abc","number":1,"node_errors":{}}"#.utf8)) }
        let doc = try frontendWorkflow()
        let graph = WorkflowCompiler.compile(doc, catalog: try editorCatalog()).graph
        _ = try await client.queuePrompt(graph, clientID: "me", workflow: doc.json())
        let (_, body) = try #require(StubProtocol.seen.last)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let workflow = ((obj["extra_data"] as? [String: Any])?["extra_pnginfo"] as? [String: Any])?["workflow"]
        #expect((workflow as? [String: Any])?["nodes"] != nil)
    }

    @Test func rejectedWorkflowNamesTheNodes() async throws {
        StubProtocol.respond = { _, _ in
            (
                400,
                Data(
                    #"{"error":{"message":"Prompt outputs failed validation","details":""},"node_errors":{"12":{"errors":[{"message":"Value not in list","details":"sampler_name: 'x' not in [...]"}],"class_type":"KSampler"}}}"#
                        .utf8)
            )
        }
        do {
            _ = try await client.queuePrompt(WorkflowGraph(), clientID: "me", workflow: nil)
            Issue.record("expected an error")
        } catch let WorkflowRunError.rejected(_, nodes) {
            #expect(nodes == ["12": ["Value not in list: sampler_name: 'x' not in [...]"]])
        }
    }
}

@Test func addsRequiredNegatives() throws {
    var compiled = WorkflowCompiler.compile(try frontendWorkflow(), catalog: try editorCatalog())
    let added = compiled.addNegative(["nsfw", "watermark"])
    #expect(added)
    #expect(
        compiled.graph.nodes["11"]?.inputs["text"]
            == .string("lowres, bad anatomy, bad hands, worst quality, watermark, nsfw"))
    #expect(compiled.negativeTexts == ["lowres, bad anatomy, bad hands, worst quality, watermark, nsfw"])
    // Flux 2 has no negative prompt.
    var flux = WorkflowCompiler.compile(
        try WorkflowDocument(data: try fixture("workflow_flux2_ui")), catalog: try editorCatalog())
    let fluxAdded = flux.addNegative(["nsfw"])
    #expect(!fluxAdded)
}

/// Runs the frontend workflow and follows it node by node. Generates a
/// picture on a real server; use the fake one (`tools/fake-comfyui` with
/// `object_info_editor.json`) unless asked:
/// `COMFY_URL=http://localhost:8189 swift test --filter runsAnEditorWorkflow`
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMFY_URL"] != nil), .timeLimit(.minutes(5)))
func runsAnEditorWorkflow() async throws {
    let client = ComfyClient(
        baseURL: try ComfyServer.normalizedURL(from: ProcessInfo.processInfo.environment["COMFY_URL"]!))
    let doc = try frontendWorkflow()
    let compiled = WorkflowCompiler.compile(doc, catalog: try await client.catalog())
    #expect(compiled.problems.isEmpty)
    var events: [RunEvent] = []
    for try await e in client.run(compiled.graph, workflow: doc.json()) {
        if case .preview = e { continue }
        events.append(e)
    }
    #expect(events.contains { if case .queued = $0 { true } else { false } })
    #expect(
        events.contains {
            if case .executed(let node, let images) = $0 { node == "7" && !images.isEmpty } else { false }
        })
    #expect(events.last == .finished)
}

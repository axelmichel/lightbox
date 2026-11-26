import CoreGraphics
import Foundation
import Testing

@testable import ComfyKit
@testable import LightboxUI

private func doc() -> WorkflowDocument {
    var d = WorkflowDocument()
    for (id, x) in [(1, 0.0), (2, 100.0), (3, 600.0)] {
        d.graph.nodes.append(GraphNode(id: id, type: "Test", position: CGPoint(x: x, y: 50)))
    }
    return d
}

@Test func theNodeOnTopIsHit() {
    let d = doc()
    let layouts = Dictionary(uniqueKeysWithValues: d.graph.nodes.map { ($0.id, NodeLayout($0, spec: nil)) })
    // 1 and 2 overlap (320 wide); 2 is drawn later.
    #expect(NodeEditing.node(at: CGPoint(x: 150, y: 60), in: d.graph.nodes, layouts: layouts) == 2)
    #expect(NodeEditing.node(at: CGPoint(x: 50, y: 30), in: d.graph.nodes, layouts: layouts) == 1)  // title
    #expect(NodeEditing.node(at: CGPoint(x: 500, y: 60), in: d.graph.nodes, layouts: layouts) == nil)
}

@Test func clicksSelect() {
    #expect(NodeEditing.select(2, in: [1, 3], extend: false) == [2])
    #expect(NodeEditing.select(2, in: [1, 3], extend: true) == [1, 2, 3])
    #expect(NodeEditing.select(3, in: [1, 3], extend: true) == [1])
    #expect(NodeEditing.select(nil, in: [1, 3], extend: false) == [])
    #expect(NodeEditing.select(nil, in: [1, 3], extend: true) == [1, 3])
}

@Test func dragsMoveTheSelectionOrOneNode() {
    #expect(NodeEditing.dragged(1, selection: [1, 2]) == [1, 2])
    #expect(NodeEditing.dragged(3, selection: [1, 2]) == [3])
    let moved = NodeEditing.moved(doc(), [1, 3], by: CGSize(width: 10.4, height: -20.6))
    #expect(
        moved.graph.nodes.map(\.position) == [
            CGPoint(x: 10, y: 29), CGPoint(x: 100, y: 50), CGPoint(x: 610, y: 29),
        ])
}

private func spec(_ inputs: [(String, String)], outputs: [String], category: String = "", display: String? = nil)
    -> NodeSpec
{
    var s = NodeSpec(
        required: inputs.map(\.0), optional: [],
        inputs: Dictionary(uniqueKeysWithValues: inputs.map { ($0.0, InputSpec(type: $0.1)) }),
        outputs: outputs.map { OutputSpec(type: $0, name: $0) })
    s.category = category
    s.displayName = display
    return s
}

@Test func linksFollowTypesAndOwnership() throws {
    var d = WorkflowDocument()
    let decode = d.graph.addNode("VAEDecode", spec: spec([("samples", "LATENT")], outputs: ["IMAGE"]), at: .zero)
    let output = d.graph.addNode("PreviewImage", spec: spec([("images", "IMAGE")], outputs: []), at: .zero)
    let scale = d.graph.addNode("ImageScaleBy", spec: spec([("image", "IMAGE")], outputs: ["IMAGE"]), at: .zero)
    for (id, role) in [(decode, "vaeDecode"), (output, "output")] {
        let i = try #require(d.graph.index(of: id))
        d.graph.nodes[i].properties[WorkflowDocument.roleProperty] = .string(role)
    }
    // Into and out of a node the user added: theirs.
    #expect(NodeEditing.linkProblem(d, from: decode, 0, to: scale, 0) == nil)
    #expect(NodeEditing.linkProblem(d, from: scale, 0, to: output, 0) == nil)
    // Between Lightbox's own nodes: Lightbox's.
    #expect(NodeEditing.linkProblem(d, from: decode, 0, to: output, 0) != nil)
    // Types must fit, and a node can't feed itself.
    #expect(NodeEditing.linkProblem(d, from: scale, 0, to: decode, 0)?.contains("doesn't fit") == true)
    #expect(NodeEditing.linkProblem(d, from: scale, 0, to: scale, 0) != nil)

    #expect(NodeEditing.canDelete(scale, in: d))
    #expect(!NodeEditing.canDelete(decode, in: d))
    #expect(d.addedNodes.map(\.id) == [scale])
}

@Test func nodeSearchSuggestsThenFindsAll() {
    var c = ComfyCatalog()
    c.nodes["ImageScaleBy"] = spec([], outputs: [], category: "image/upscaling", display: "Upscale Image By")
    c.nodes["SaveImage"] = spec([], outputs: [], category: "image")
    c.nodes["LatentUpscale"] = spec([], outputs: [], category: "latent", display: "Upscale Latent")
    c.nodes["KSampler"] = spec([], outputs: [], category: "sampling")
    // Nothing typed: the suggestions the server has, in their order.
    #expect(NodeSearch.results("", in: c) == ["ImageScaleBy", "SaveImage"])
    // Display names count ("Upscale Image By", "Upscale Latent"); both start with the term, so by name.
    #expect(NodeSearch.results("upscale", in: c) == ["ImageScaleBy", "LatentUpscale"])
    // Starting with the term comes first: "Save…" before "…Image" elsewhere in the name.
    #expect(NodeSearch.results("image", in: c) == ["ImageScaleBy", "SaveImage"])
    #expect(NodeSearch.results("ksam", in: c) == ["KSampler"])
    #expect(NodeSearch.results("sampling", in: c) == ["KSampler"])  // by category
}

/// A standard graph without a server catalog: values by name, every input there.
private func builtDoc() throws -> WorkflowDocument {
    var r = GenerationRequest(
        checkpoint: "photo-xl.safetensors", loras: [LoraRequest(name: "ink.safetensors", strength: 0.6)],
        positive: "a fox", negative: "lowres", seed: 1, clipSkip: 2,
        faceFix: DetailerRequest(detector: "face.pt"))
    r.guides = [
        GuideRequest(
            setup: .controlNet(model: "depth.safetensors", unionType: nil, extractor: nil), image: Data(),
            filename: "g.png")
    ]
    return try WorkflowDocument(WorkflowBuilder.build(r, catalog: ComfyCatalog()), catalog: ComfyCatalog())
}

@Test func deletingANodeMeansWhatItStandsFor() throws {
    let doc = try builtDoc()
    func node(_ role: NodeRole) throws -> Int { try #require(doc.roles.first { $0.value == role }?.key) }
    #expect(
        NodeEditing.deletion(try node(NodeRole(.lora, key: "ink.safetensors")), in: doc)
            == .switchOff(.loraOff("ink.safetensors")))
    #expect(NodeEditing.deletion(try node(NodeRole(.clipSkip)), in: doc) == .switchOff(.clipSkip(1)))
    #expect(NodeEditing.deletion(try node(NodeRole(.faceFix)), in: doc) == .switchOff(.faceFixOff))
    #expect(NodeEditing.deletion(try node(NodeRole(.guide, key: "0")), in: doc) == .switchOff(.guideOff(0)))
    // Parts and required nodes stay.
    #expect(NodeEditing.deletion(try node(NodeRole(.guide, .loader, key: "0")), in: doc) == .keep)
    #expect(NodeEditing.deletion(try node(NodeRole(.faceFix, .detector)), in: doc) == .keep)
    for role in [NodeRole(.checkpoint), NodeRole(.sampler), NodeRole(.positive), NodeRole(.output)] {
        #expect(NodeEditing.deletion(try node(role), in: doc) == .keep, "\(role)")
    }
}

@Test func aLoraLoaderHungIntoTheChainIsTheForms() throws {
    var doc = try builtDoc()
    let checkpoint = try #require(doc.roles.first { $0.value == NodeRole(.checkpoint) }?.key)
    let sampler = try #require(doc.roles.first { $0.value == NodeRole(.sampler) }?.key)
    var lora = GraphNode(id: 0, type: "LoraLoader")
    lora.inputs = [NodeInputSlot(name: "model", type: "MODEL"), NodeInputSlot(name: "clip", type: "CLIP")]
    lora.outputs = [NodeOutputSlot(name: "MODEL", type: "MODEL"), NodeOutputSlot(name: "CLIP", type: "CLIP")]
    lora.widgetsValues = .object([
        "lora_name": .string("new-look.safetensors"), "strength_model": .double(0.7), "strength_clip": .double(0.4),
    ])
    let id = doc.graph.addNode(lora)
    doc.graph.connect(from: checkpoint, 0, to: id, 0)
    // Not yet feeding anything of Lightbox's: not in the chain.
    #expect(NodeEditing.hookedLoras(doc, catalog: ComfyCatalog()).isEmpty)
    let model = try #require(doc.graph.node(sampler)?.inputs.firstIndex { $0.name == "model" })
    doc.graph.connect(from: id, 0, to: sampler, model)
    let hooked = NodeEditing.hookedLoras(doc, catalog: ComfyCatalog())
    #expect(hooked.map(\.node) == [id])
    #expect(hooked.first?.change == .addLora(name: "new-look.safetensors", strength: 0.7, clipStrength: 0.4))
}

@Test func graphsSayWhatModelTheyAreFor() throws {
    func kind(_ split: SplitModelRequest?) throws -> String? {
        var r = GenerationRequest(checkpoint: "photo-xl.safetensors", positive: "a fox", negative: "", seed: 1)
        r.split = split
        let doc = try WorkflowDocument(WorkflowBuilder.build(r, catalog: ComfyCatalog()), catalog: ComfyCatalog())
        return NodeEditing.modelKind(doc, catalog: ComfyCatalog())
    }
    #expect(try kind(nil) == "a checkpoint model")
    #expect(
        try kind(
            SplitModelRequest(model: "f.gguf", textEncoders: ["t5.gguf", "l.safetensors"], clipType: "flux", vae: "ae"))
            == "Flux")
    #expect(
        try kind(
            SplitModelRequest(model: "k.safetensors", textEncoders: ["q.safetensors"], clipType: "krea2", vae: "v"))
            == "Krea 2")
    #expect(NodeEditing.modelKind(WorkflowDocument(), catalog: ComfyCatalog()) == nil)
}

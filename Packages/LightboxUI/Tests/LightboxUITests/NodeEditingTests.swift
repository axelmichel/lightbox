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

@Test func ownNodesCopyPasteMuteAndBypass() throws {
    var doc = try builtDoc()
    let decode = try #require(doc.roles.first { $0.value == NodeRole(.vaeDecode) }?.key)
    var scale = GraphNode(id: 0, type: "ImageScaleBy", position: CGPoint(x: 100, y: 100))
    scale.inputs = [NodeInputSlot(name: "image", type: "IMAGE")]
    scale.outputs = [NodeOutputSlot(name: "IMAGE", type: "IMAGE")]
    let a = doc.graph.addNode(scale)
    let b = doc.graph.addNode(scale)
    doc.graph.connect(from: a, 0, to: b, 0)
    doc.graph.connect(from: decode, 0, to: a, 0)

    // Only the user's nodes, with the link between them, not the one from the decode.
    let clip = try #require(NodeEditing.clipboard([a, b, decode], from: doc))
    #expect(Set(clip.graph.nodes.map(\.id)) == [a, b])
    #expect(clip.graph.links.count == 1)
    let (pasted, ids) = NodeEditing.pasted(clip, into: doc, offset: CGVector(dx: 40, dy: 40))
    #expect(ids.count == 2 && Set(ids).isDisjoint(with: [a, b]))
    #expect(pasted.graph.nodes.count == doc.graph.nodes.count + 2)
    #expect(pasted.graph.node(ids[0])?.position == CGPoint(x: 140, y: 140))
    #expect(pasted.graph.links.count == doc.graph.links.count + 1)
    #expect(NodeEditing.clipboard([decode], from: doc) == nil)

    // Mute, then again: running. Lightbox's own stay as they are.
    let muted = NodeEditing.toggled(.never, [a, decode], in: doc)
    #expect(muted.graph.node(a)?.mode == .never && muted.graph.node(decode)?.mode == .always)
    #expect(NodeEditing.toggled(.never, [a], in: muted).graph.node(a)?.mode == .always)
    #expect(NodeEditing.toggled(.bypass, [a, b], in: muted).graph.nodes.filter { $0.mode == .bypass }.count == 2)
}

@Test func groupsMoveWithWhatIsInside() {
    var d = WorkflowDocument()
    d.graph.nodes = [
        GraphNode(id: 1, type: "A", position: CGPoint(x: 50, y: 80), size: CGSize(width: 100, height: 50)),
        GraphNode(id: 2, type: "B", position: CGPoint(x: 900, y: 80)),
    ]
    var r = GraphReroute(id: 1, position: CGPoint(x: 120, y: 200))
    r.parent = nil
    d.graph.reroutes = [r]
    let (grouped, id) = NodeEditing.grouping(d, around: CGRect(x: 50, y: 50, width: 300, height: 200), title: "Look")
    let group = grouped.graph.groups.first { $0.id == id }!
    #expect(group.frame == CGRect(x: 40, y: 6, width: 320, height: 254))  // title bar of 33.6 above
    #expect(NodeEditing.group(at: CGPoint(x: 60, y: 20), in: grouped) == id)
    #expect(NodeEditing.group(at: CGPoint(x: 60, y: 100), in: grouped) == nil)  // body, not title

    let inside = NodeEditing.groupContents(id, in: grouped)
    #expect(inside.nodes == [1] && inside.reroutes == [1])
    let moved = NodeEditing.movedGroup(
        grouped, id, nodes: inside.nodes, reroutes: inside.reroutes, by: CGSize(width: 10, height: 20))
    #expect(moved.graph.groups[0].frame.origin == CGPoint(x: 50, y: 26))
    #expect(moved.graph.node(1)?.position == CGPoint(x: 60, y: 100))
    #expect(moved.graph.node(2)?.position == CGPoint(x: 900, y: 80))
    #expect(moved.graph.reroutes[0].position == CGPoint(x: 130, y: 220))
}

@Test func linksPassThroughTheirReroutes() {
    var g = NodeGraph()
    var first = GraphReroute(id: 1, position: CGPoint(x: 10, y: 10))
    first.parent = nil
    var second = GraphReroute(id: 2, position: CGPoint(x: 20, y: 20))
    second.parent = 1
    g.reroutes = [second, first]
    var link = GraphLink(id: 1, origin: 1, originSlot: 0, target: 2, targetSlot: 0, type: "IMAGE")
    #expect(NodeEditing.reroutePoints(link, in: g).isEmpty)
    link.parentReroute = 2
    #expect(NodeEditing.reroutePoints(link, in: g) == [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])
}

@Test func aSubgraphIsShownWithItsInputsAndOutputs() throws {
    var inner = NodeGraph()
    var encode = GraphNode(id: 1, type: "CLIPTextEncode", position: CGPoint(x: 100, y: 50))
    encode.inputs = [
        NodeInputSlot(name: "text", type: "STRING", link: 2), NodeInputSlot(name: "clip", type: "CLIP", link: 1),
    ]
    encode.outputs = [NodeOutputSlot(name: "CONDITIONING", type: "CONDITIONING", links: [3])]
    inner.nodes = [encode]
    inner.links = [
        GraphLink(id: 1, origin: GraphLink.subgraphInputID, originSlot: 0, target: 1, targetSlot: 1, type: "CLIP"),
        GraphLink(id: 2, origin: GraphLink.subgraphInputID, originSlot: 1, target: 1, targetSlot: 0, type: "STRING"),
        GraphLink(
            id: 3, origin: 1, originSlot: 0, target: GraphLink.subgraphOutputID, targetSlot: 0, type: "CONDITIONING"),
    ]
    var doc = WorkflowDocument()
    doc.subgraphs = [
        SubgraphDefinition(
            id: "sub", name: "Prompt", graph: inner,
            inputs: [
                SubgraphSlot(id: "a", name: "clip", type: "CLIP", linkIDs: [1]),
                SubgraphSlot(id: "b", name: "text", type: "STRING", linkIDs: [2]),
            ],
            outputs: [SubgraphSlot(id: "c", name: "CONDITIONING", type: "CONDITIONING", linkIDs: [3])])
    ]
    let shown = try #require(NodeEditing.inside("sub", of: doc))
    let inputs = try #require(shown.graph.node(GraphLink.subgraphInputID))
    let outputs = try #require(shown.graph.node(GraphLink.subgraphOutputID))
    #expect(inputs.outputs.map(\.name) == ["clip", "text"])
    #expect(outputs.inputs.map(\.name) == ["CONDITIONING"] && outputs.inputs[0].link == 3)
    // Left and right of what is inside.
    #expect(inputs.position.x < 100 && outputs.position.x > 100)
    #expect(shown.graph.links.count == 3)
    // Their sockets are where the links draw from and to.
    #expect(NodeLayout(inputs, spec: nil).outputPoints.count == 2)
    #expect(NodeLayout(outputs, spec: nil).inputPoints.count == 1)
    #expect(NodeEditing.inside("gone", of: doc) == nil)
}

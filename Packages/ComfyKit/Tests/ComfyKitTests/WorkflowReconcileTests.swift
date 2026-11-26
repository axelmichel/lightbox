import CoreGraphics
import Foundation
import Testing

@testable import ComfyKit

private func request(loras: [String] = ["a.safetensors", "b.safetensors"], steps: Int = 25) -> GenerationRequest {
    GenerationRequest(
        checkpoint: "Sample_Illustrious_v1.safetensors",
        loras: loras.map { LoraRequest(name: $0, strength: 0.8) },
        positive: "1girl, comic", negative: "lowres", width: 832, height: 1216, steps: steps, seed: 42, clipSkip: 2)
}

private func project(_ r: GenerationRequest, _ c: ComfyCatalog) throws -> WorkflowDocument {
    try WorkflowDocument(WorkflowBuilder.build(r, catalog: c), catalog: c)
}

/// The compiled graph with node ids replaced by roles (or "free:<id>"), so
/// two documents with different ids can be compared.
private func byRole(_ doc: WorkflowDocument, _ c: ComfyCatalog) -> [String: String] {
    let compiled = WorkflowCompiler.compile(doc, catalog: c)
    let roles = doc.roles
    func name(_ id: String) -> String { Int(id).flatMap { roles[$0]?.description } ?? "free:\(id)" }
    var out: [String: String] = [:]
    for (id, node) in compiled.graph.nodes {
        let inputs = node.inputs.sorted { $0.key < $1.key }.map { key, value -> String in
            if case .link(let from, let slot) = value { return "\(key)=\(name(from))#\(slot)" }
            return "\(key)=\(value)"
        }
        out[name(id)] = node.classType + " " + inputs.joined(separator: " ")
    }
    return out
}

private func node(_ doc: WorkflowDocument, _ role: NodeRole) throws -> GraphNode {
    let id = try #require(doc.roles.first { $0.value == role }?.key, "no \(role)")
    return try #require(doc.graph.node(id))
}

/// Move every node, so a reconcile that lays out anew would show.
private func moved(_ doc: WorkflowDocument) -> WorkflowDocument {
    var d = doc
    for i in d.graph.nodes.indices { d.graph.nodes[i].position.x += 1000 + Double(i) * 7 }
    return d
}

@Test func reconcilingWithTheSameGraphChangesNothing() throws {
    let c = try kritaCatalog()
    let doc = try project(request(), c)
    #expect(doc.reconciled(with: doc) == doc)
}

@Test func newValuesKeepThePlaces() throws {
    let c = try kritaCatalog()
    let doc = moved(try project(request(), c))
    let target = try project(request(steps: 30), c)
    let done = doc.reconciled(with: target)
    #expect(done.graph.nodes.map(\.position) == doc.graph.nodes.map(\.position))
    #expect(try node(done, NodeRole(.sampler)).widgetValue("steps", spec: c.nodes["KSampler"]) == .int(30))
    #expect(byRole(done, c) == byRole(target, c))
    #expect(done.reconciled(with: target) == done)
}

@Test func aLoraJoinsTheChainInTheMiddle() throws {
    let c = try kritaCatalog()
    let doc = moved(try project(request(), c))
    let target = try project(request(loras: ["a.safetensors", "c.safetensors", "b.safetensors"]), c)
    let done = doc.reconciled(with: target)
    #expect(byRole(done, c) == byRole(target, c))
    // The others stay where they were.
    for role in [NodeRole(.checkpoint), NodeRole(.lora, key: "a.safetensors"), NodeRole(.lora, key: "b.safetensors")] {
        #expect(try node(done, role).position == node(doc, role).position, "\(role)")
    }
    // The new one sits under the LoRA before it, clear of every other node.
    let added = try node(done, NodeRole(.lora, key: "c.safetensors"))
    let before = try node(done, NodeRole(.lora, key: "a.safetensors"))
    #expect(added.position.x == before.position.x)
    #expect(added.position.y > before.position.y + before.size.height)
    func box(_ n: GraphNode) -> CGRect {
        CGRect(x: n.position.x, y: n.position.y - 30, width: n.size.width, height: n.size.height + 30)
    }
    for other in done.graph.nodes where other.id != added.id {
        #expect(!box(other).intersects(box(added)), "overlaps \(other.type)")
    }
    #expect(added.id > (doc.graph.nodes.map(\.id).max() ?? 0))
    #expect(done.reconciled(with: target) == done)
}

@Test func aLoraLeavesTheChainInTheMiddle() throws {
    let c = try kritaCatalog()
    let doc = moved(try project(request(loras: ["a.safetensors", "c.safetensors", "b.safetensors"]), c))
    let target = try project(request(), c)
    let done = doc.reconciled(with: target)
    #expect(byRole(done, c) == byRole(target, c))
    #expect(done.graph.nodes.count == doc.graph.nodes.count - 1)
    #expect(
        try node(done, NodeRole(.lora, key: "b.safetensors")).position
            == node(doc, NodeRole(.lora, key: "b.safetensors")).position)
    #expect(done.reconciled(with: target) == done)
}

@Test func aNodeOfAnotherKindIsReplacedInPlace() throws {
    let c = try kritaCatalog()
    var flux = request(loras: [])
    flux.split = SplitModelRequest(
        model: "flux1-krea-Q4.gguf", textEncoders: ["t5-xxl-encoder-Q4.gguf", "clip_l.safetensors"],
        clipType: "flux", vae: "ae.safetensors", guidance: 4.5, zeroNegative: false)
    var zeroed = flux
    zeroed.split?.zeroNegative = true
    let doc = moved(try project(flux, c))
    let done = doc.reconciled(with: try project(zeroed, c))
    let before = try node(doc, NodeRole(.negative))
    let after = try node(done, NodeRole(.negative))
    #expect((before.type, after.type) == ("CLIPTextEncode", "ConditioningZeroOut"))
    #expect((after.id, after.position) == (before.id, before.position))
    #expect(byRole(done, c) == byRole(try project(zeroed, c), c))
}

@Test func nodesTheUserAddedStay() throws {
    let c = try kritaCatalog()
    var doc = try project(request(), c)
    let decode = try node(doc, NodeRole(.vaeDecode)).id
    let spec = try #require(c.nodes["PreviewImage"])
    let extra = doc.graph.addNode("PreviewImage", spec: spec, at: CGPoint(x: 5000, y: 0))
    doc.graph.connect(from: decode, 0, to: extra, 0)
    let done = doc.reconciled(with: try project(request(steps: 30), c))
    let kept = try #require(done.graph.node(extra))
    #expect(kept.position == CGPoint(x: 5000, y: 0))
    #expect(done.graph.links.contains { $0.origin == decode && $0.target == extra })
}

@Test func aLinkFromAnAddedNodeIntoAManagedInputStays() throws {
    let c = try kritaCatalog()
    var doc = try project(request(), c)
    let output = try node(doc, NodeRole(.output)).id
    // A second picture source the user feeds the output with.
    let spec = try #require(c.nodes["VAEDecode"])
    let mine = doc.graph.addNode("VAEDecode", spec: spec, at: CGPoint(x: 5000, y: 0))
    let images = try #require(doc.graph.node(output)?.inputs.firstIndex { $0.name == "images" })
    doc.graph.connect(from: mine, 0, to: output, images)
    let done = doc.reconciled(with: try project(request(steps: 30), c))
    #expect(done.graph.links.contains { $0.origin == mine && $0.target == output })
    // A managed link that was cut is made again.
    var cut = try project(request(), c)
    let sampler = try node(cut, NodeRole(.sampler))
    let model = try #require(sampler.inputs.firstIndex { $0.name == "model" })
    cut.graph.disconnect(input: sampler.id, model)
    let target = try project(request(), c)
    #expect(byRole(cut.reconciled(with: target), c) == byRole(target, c))
}

/// From any of the standard graphs to any other: the result runs as the
/// target does, and a second pass changes nothing.
@Test func reconcilesBetweenAllKindsOfGraphs() throws {
    let c = try kritaCatalog()
    let all = try requests().map { ($0.name, try project($0.request, c)) }
    for (from, doc) in all {
        for (to, target) in all {
            let done = moved(doc).reconciled(with: target)
            #expect(byRole(done, c) == byRole(target, c), "\(from) → \(to)")
            #expect(WorkflowCompiler.compile(done, catalog: c).problems.isEmpty, "\(from) → \(to)")
            #expect(ManagedGraph(done, catalog: c).missing.isEmpty, "\(from) → \(to)")
            #expect(done.reconciled(with: target) == done, "\(from) → \(to): not stable")
        }
    }
}

@Test func aNewNodeNothingFeedsDoesNotLandOnAnother() throws {
    let c = try kritaCatalog()
    var withVAE = request()
    withVAE.vae = "sdxl-vae.safetensors"
    // Everything moved onto the place the fresh layout gives the VAE loader.
    let target = try project(withVAE, c)
    let spot = try node(target, NodeRole(.vae)).position
    var doc = try project(request(), c)
    for i in doc.graph.nodes.indices { doc.graph.nodes[i].position = spot }
    let added = try node(doc.reconciled(with: target), NodeRole(.vae))
    let blocker = try #require(doc.graph.nodes.first)
    #expect(added.position.y > blocker.position.y + blocker.size.height)
}

/// A node the user added, put between a chain's end and what reads it.
private func spliced(
    _ doc: WorkflowDocument, after role: NodeRole, slot: Int, type: String, into consumer: NodeRole, input: String
) throws -> (WorkflowDocument, Int) {
    var d = doc
    let from = try node(d, role).id
    let to = try node(d, consumer).id
    var added = GraphNode(id: 0, type: "UserNode", position: CGPoint(x: 5000, y: 0))
    added.inputs = [NodeInputSlot(name: "in", type: type)]
    added.outputs = [NodeOutputSlot(name: type, type: type)]
    let id = d.graph.addNode(added)
    d.graph.connect(from: from, slot, to: id, 0)
    let i = try #require(d.graph.node(to)?.inputs.firstIndex { $0.name == input })
    d.graph.connect(from: id, 0, to: to, i)
    return (d, id)
}

private func source(_ doc: WorkflowDocument, _ node: Int) -> Int? {
    doc.graph.node(node)?.inputs.first?.link.flatMap { doc.graph.link($0)?.origin }
}

@Test func anUpscalerFollowsTheFaceFix() throws {
    let c = try kritaCatalog()
    let (doc, upscaler) = try spliced(
        try project(request(), c), after: NodeRole(.vaeDecode), slot: 0, type: "IMAGE", into: NodeRole(.output),
        input: "images")
    var fixed = request()
    fixed.faceFix = DetailerRequest(detector: "bbox/face_yolov8m.pt")
    let done = doc.reconciled(with: try project(fixed, c))
    // decode → face fix → upscaler → output
    #expect(source(done, upscaler) == (try node(done, NodeRole(.faceFix)).id))
    let output = try node(done, NodeRole(.output))
    #expect(output.inputs.first.flatMap { $0.link.flatMap { done.graph.link($0)?.origin } } == upscaler)
    #expect(done.reconciled(with: try project(fixed, c)) == done)
    // Fix off again: back to the decode.
    let back = done.reconciled(with: try project(request(), c))
    #expect(source(back, upscaler) == (try node(back, NodeRole(.vaeDecode)).id))
}

@Test func aModelNodeFollowsANewLora() throws {
    let c = try kritaCatalog()
    // After the last LoRA, before the sampler.
    let (doc, patch) = try spliced(
        try project(request(), c), after: NodeRole(.lora, key: "b.safetensors"), slot: 0, type: "MODEL",
        into: NodeRole(.sampler), input: "model")
    let done = doc.reconciled(
        with: try project(request(loras: ["a.safetensors", "b.safetensors", "c.safetensors"]), c))
    #expect(source(done, patch) == (try node(done, NodeRole(.lora, key: "c.safetensors")).id))
    let sampler = try node(done, NodeRole(.sampler))
    let model = try #require(sampler.inputs.first { $0.name == "model" })
    #expect(model.link.flatMap { done.graph.link($0)?.origin } == patch)
}

@Test func aNodeReadingMidChainStaysThere() throws {
    let c = try kritaCatalog()
    var fixed = request()
    fixed.faceFix = DetailerRequest(detector: "bbox/face_yolov8m.pt")
    var doc = try project(fixed, c)
    // The picture before the face fix, on purpose (to compare).
    let decode = try node(doc, NodeRole(.vaeDecode)).id
    var added = GraphNode(id: 0, type: "UserNode")
    added.inputs = [NodeInputSlot(name: "in", type: "IMAGE")]
    let id = doc.graph.addNode(added)
    doc.graph.connect(from: decode, 0, to: id, 0)
    var more = fixed
    more.handFix = DetailerRequest(detector: "bbox/hand_yolov8s.pt")
    let done = doc.reconciled(with: try project(more, c))
    #expect(source(done, id) == decode)
}

import CoreGraphics
import Testing

@testable import ComfyKit
@testable import LightboxUI

/// A node as `ApiLayout` makes it: a slot for every input, widget inputs
/// named as such.
private func node(_ type: String, _ spec: NodeSpec, at position: CGPoint, size: CGSize) -> GraphNode {
    var n = GraphNode(id: 1, type: type, position: position, size: size)
    n.inputs = spec.inputOrder.compactMap { name in
        spec.inputs[name].map { NodeInputSlot(name: name, type: $0.type, widget: $0.isWidget ? name : nil) }
    }
    n.outputs = spec.outputs.map { NodeOutputSlot(name: $0.name, type: $0.type) }
    return n
}

private let kSampler: NodeSpec = {
    var seed = InputSpec(type: "INT")
    seed.controlAfterGenerate = true
    return NodeSpec(
        required: [
            "model", "seed", "steps", "cfg", "sampler_name", "scheduler", "positive", "negative", "latent_image",
            "denoise",
        ],
        optional: [],
        inputs: [
            "model": InputSpec(type: "MODEL"), "seed": seed, "steps": InputSpec(type: "INT"),
            "cfg": InputSpec(type: "FLOAT"), "sampler_name": InputSpec(type: "COMBO", options: ["euler"]),
            "scheduler": InputSpec(type: "COMBO", options: ["normal"]), "positive": InputSpec(type: "CONDITIONING"),
            "negative": InputSpec(type: "CONDITIONING"), "latent_image": InputSpec(type: "LATENT"),
            "denoise": InputSpec(type: "FLOAT"),
        ],
        outputs: [OutputSpec(type: "LATENT", name: "LATENT")])
}()

private let textEncode = NodeSpec(
    required: ["text", "clip"], optional: [],
    inputs: ["text": InputSpec(type: "STRING", multiline: true), "clip": InputSpec(type: "CLIP")],
    outputs: [OutputSpec(type: "CONDITIONING", name: "CONDITIONING")])

@Test func socketsAndWidgetsFollowLiteGraph() throws {
    let n = node("KSampler", kSampler, at: CGPoint(x: 100, y: 200), size: CGSize(width: 320, height: 100))
    let l = NodeLayout(n, spec: kSampler)
    #expect(l.titleRect == CGRect(x: 100, y: 170, width: 320, height: 30))
    // Four sockets without widgets, in rows of 20, 10 in from the edge.
    #expect(l.inputPoints[0] == CGPoint(x: 110, y: 214))  // model
    #expect(l.inputPoints[6] == CGPoint(x: 110, y: 234))  // positive
    #expect(l.inputPoints[8] == CGPoint(x: 110, y: 274))  // latent_image
    #expect(l.outputPoints == [CGPoint(x: 410, y: 214)])
    // Then the widgets: the seed with its control, then the rest.
    #expect(l.rows.map(\.name) == ["seed", "seed", "steps", "cfg", "sampler_name", "scheduler", "denoise"])
    #expect(l.rows[1].kind == .control)
    #expect(l.rows[0].rect == CGRect(x: 100, y: 284, width: 320, height: 20))
    #expect(l.rows[6].rect.minY == 428)
    // A widget's socket is at its row.
    #expect(l.inputPoints[1] == CGPoint(x: 110, y: 294))
    // Taller than the file says, as the widgets need it.
    #expect(l.minHeight == 256)
    #expect(l.frame == CGRect(x: 100, y: 200, width: 320, height: 256))
    #expect(l.bounds == CGRect(x: 100, y: 170, width: 320, height: 286))
}

@Test func textBoxesTakeTheRoomLeft() {
    let n = node("CLIPTextEncode", textEncode, at: .zero, size: CGSize(width: 400, height: 200))
    let l = NodeLayout(n, spec: textEncode)
    #expect(l.inputPoints == [CGPoint(x: 10, y: 34), CGPoint(x: 10, y: 14)])  // text, clip
    #expect(l.minHeight == 112)
    #expect(
        l.rows == [
            NodeLayout.Row(
                name: "text", kind: .value, multiline: true, rect: CGRect(x: 0, y: 24, width: 400, height: 168))
        ])
    #expect(l.frame.height == 200)
}

@Test func nodesTheServerLacksShowEverySocket() {
    let n = node("KSampler", kSampler, at: .zero, size: CGSize(width: 50, height: 10))
    let l = NodeLayout(n, spec: nil)
    #expect(l.rows.isEmpty)
    #expect(l.frame == CGRect(x: 0, y: 0, width: 140, height: 208))  // at least 140 wide
    #expect(l.inputPoints == (0..<10).map { CGPoint(x: 10, y: (Double($0) + 0.7) * 20) })
    #expect(l.minHeight == 208)
}

@Test func collapsedNodesAreATitle() {
    var n = node("KSampler", kSampler, at: CGPoint(x: 0, y: 100), size: CGSize(width: 320, height: 200))
    n.collapsed = true
    let l = NodeLayout(n, spec: kSampler)
    #expect(l.frame.height == 0)
    #expect(l.bounds == CGRect(x: 0, y: 70, width: 320, height: 30))
    #expect(l.inputPoints == Array(repeating: CGPoint(x: 0, y: 85), count: 10))
    #expect(l.outputPoints == [CGPoint(x: 320, y: 85)])
}

@Test func findsWhatIsUnderAPoint() {
    let n = node("KSampler", kSampler, at: CGPoint(x: 100, y: 200), size: CGSize(width: 320, height: 100))
    let l = NodeLayout(n, spec: kSampler)
    #expect(l.hit(CGPoint(x: 112, y: 216)) == .input(0))
    #expect(l.hit(CGPoint(x: 408, y: 214)) == .output(0))
    // The seed's socket wins over its row.
    #expect(l.hit(CGPoint(x: 110, y: 294)) == .input(1))
    #expect(l.hit(CGPoint(x: 200, y: 340)) == .widget("steps"))
    #expect(l.hit(CGPoint(x: 200, y: 185)) == .title)
    #expect(l.hit(CGPoint(x: 250, y: 230)) == .body)
    #expect(l.hit(CGPoint(x: 90, y: 230)) == nil)
    #expect(l.hit(CGPoint(x: 200, y: 460)) == nil)
}

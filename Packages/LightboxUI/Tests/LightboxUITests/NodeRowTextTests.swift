import ComfyKit
import Foundation
import Testing

@testable import LightboxUI

@Test func promptsAndPicturesAreLocked() {
    #expect(NodeRowText.isLocked(NodeRole(.positive), input: "text"))
    #expect(NodeRowText.isLocked(NodeRole(.negative), input: "text"))
    #expect(NodeRowText.isLocked(NodeRole(.guide, .image, key: "0"), input: "image"))
    #expect(NodeRowText.isLocked(NodeRole(.reference, .image, key: "0"), input: "image"))
    #expect(NodeRowText.isLocked(NodeRole(.inpaint, .mask), input: "image"))
    #expect(!NodeRowText.isLocked(NodeRole(.inpaint, .mask), input: "channel"))
    #expect(!NodeRowText.isLocked(NodeRole(.sampler), input: "steps"))
    #expect(!NodeRowText.isLocked(NodeRole(.guidance), input: "guidance"))
    #expect(!NodeRowText.isLocked(nil, input: "text"))
}

@Test func valuesReadAsInComfyUI() {
    #expect(NodeRowText.value(.double(0.35)) == "0.35")
    #expect(NodeRowText.value(.double(6)) == "6")
    #expect(NodeRowText.value(.double(0.123456)) == "0.123")
    #expect(NodeRowText.value(.double(-0.5)) == "-0.5")
    #expect(NodeRowText.value(.int(1024)) == "1024")
    #expect(NodeRowText.value(.bool(true)) == "true")
    #expect(NodeRowText.value(.string("euler")) == "euler")
    #expect(NodeRowText.value(nil) == "—")
}

/// Every editable row changes a setting of the form when its value
/// changes, and no other (unlocked) row does.
@Test func editableRowsAreExactlyTheSettings() throws {
    let face = DetailerRequest(detector: "face.pt", denoise: 0.35)
    var checkpoint = GenerationRequest(
        checkpoint: "photo-xl.safetensors", vae: "sdxl-vae.safetensors",
        loras: [LoraRequest(name: "a.safetensors", strength: 0.8)], positive: "a fox", negative: "lowres",
        width: 832, height: 1216, seed: 7, clipSkip: 2, faceFix: face)
    checkpoint.guides = [
        GuideRequest(
            setup: .controlNet(model: "depth.safetensors", unionType: nil, extractor: nil), image: Data(),
            filename: "a.png", strength: 0.6),
        GuideRequest(
            setup: .ipAdapter(model: "ip.safetensors", clipVision: "vision.safetensors", weightType: "linear"),
            image: Data(), filename: "b.png", strength: 0.5),
    ]
    var flux = checkpoint
    flux.guides = []
    flux.split = SplitModelRequest(
        model: "flux.gguf", textEncoders: ["t5.gguf", "clip_l.safetensors"], clipType: "flux", vae: "ae.safetensors",
        guidance: 3.5)
    var zImage = flux
    zImage.split = SplitModelRequest(
        model: "z.gguf", textEncoders: ["qwen.gguf"], clipType: "lumina2", vae: "ae.safetensors", shift: 3)
    var flux2 = flux
    flux2.split = SplitModelRequest(
        model: "klein.gguf", textEncoders: ["qwen.gguf"], clipType: "flux2", vae: "flux2-vae.safetensors",
        sampling: .flux2)

    var editable = 0
    for r in [checkpoint, flux, zImage, flux2] {
        // Without a server catalog, values are kept by name: every input is there.
        let doc = try WorkflowDocument(WorkflowBuilder.build(r, catalog: ComfyCatalog()), catalog: ComfyCatalog())
        let before = ManagedGraph(doc, catalog: ComfyCatalog()).settings
        let roles = doc.roles
        for node in doc.graph.nodes {
            guard let role = roles[node.id], case .object(let values)? = node.widgetsValues else { continue }
            for (input, value) in values {
                let other: JSONValue =
                    switch value {
                    case .int(let i): .int(i + 1)
                    case .double(let d): .double(d + 0.25)
                    case .string(let s): .string(s + "x")
                    case .bool(let b): .bool(!b)
                    default: value
                    }
                var edited = doc
                let i = try #require(edited.graph.index(of: node.id))
                edited.graph.nodes[i].setWidgetValue(input, other, spec: nil)
                let changes = GraphChange.changes(
                    from: before, to: ManagedGraph(edited, catalog: ComfyCatalog()).settings)
                if NodeRowText.isEditable(role, input: input) {
                    editable += 1
                    #expect(!changes.isEmpty, "\(role).\(input) changes nothing")
                } else if !NodeRowText.isLocked(role, input: input) {
                    #expect(changes.isEmpty, "\(role).\(input) changes \(changes) but can't be edited")
                }
            }
        }
    }
    // The four graphs have dozens; a handful would mean the values weren't read.
    #expect(editable > 40, "only \(editable) editable rows seen")
}

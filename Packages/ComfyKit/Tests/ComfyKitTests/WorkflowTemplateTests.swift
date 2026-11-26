import Foundation
import Testing

@testable import ComfyKit

/// A workflow fixture of the LightboxCore tests (UI format, as ComfyUI saves).
private func coreWorkflow(_ name: String) throws -> WorkflowDocument {
    let url = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../LightboxCore/Tests/LightboxCoreTests/Fixtures/\(name).json").standardized
    return try WorkflowDocument(data: Data(contentsOf: url))
}

private func marked(_ doc: WorkflowDocument) throws -> (doc: WorkflowDocument, roles: [Int: NodeRole]) {
    let m = doc.markedAsTemplate(catalog: try kritaCatalog())
    #expect(m.missing.isEmpty, "\(m.missing)")
    return (m.doc, m.doc.roles)
}

@Test func anSDXLWorkflowIsMarkedFromItsSampler() throws {
    let (doc, roles) = try marked(try coreWorkflow("workflow_ui"))
    #expect(roles[4] == NodeRole(.checkpoint))
    #expect(roles[10] == NodeRole(.lora, key: "ink_style.safetensors"))
    #expect(roles[11] == NodeRole(.clipSkip))
    #expect((roles[6], roles[7]) == (NodeRole(.positive), NodeRole(.negative)))
    #expect(
        (roles[5], roles[3], roles[8], roles[9]) == (
            NodeRole(.latent), NodeRole(.sampler), NodeRole(.vaeDecode), NodeRole(.output)
        ))
    // The muted LoRA, the upscale model and the note are the user's.
    #expect(roles[13] == nil && roles[12] == nil && roles[14] == nil)
    // Read like Lightbox's own graphs.
    let s = ManagedGraph(doc, catalog: try kritaCatalog()).settings
    #expect(s.checkpoint == "Sample_Illustrious_v1.safetensors")
    #expect((s.steps, s.cfg, s.sampler, s.scheduler) == (28, 5.5, "euler_ancestral", "normal"))
    #expect((s.width, s.height, s.clipSkip) == (832, 1216, 2))
    #expect(s.loras == [LoraRequest(name: "ink_style.safetensors", strength: 0.8, clipStrength: 0.6)])
    #expect(s.negative == "lowres, bad hands, watermark")
}

@Test func aFlux2WorkflowIsMarkedThroughItsGuider() throws {
    let (_, roles) = try marked(try coreWorkflow("workflow_flux2_ui"))
    #expect(roles[1] == NodeRole(.diffusionModel))
    #expect(roles[2] == NodeRole(.textEncoders))
    #expect(roles[3] == NodeRole(.vae))
    #expect((roles[4], roles[5]) == (NodeRole(.positive), NodeRole(.negative)))
    #expect(roles[6] == NodeRole(.sampler, .guider))
    #expect(roles[7] == NodeRole(.sampler, .noise))
    #expect(roles[8] == NodeRole(.sampler, .select))
    #expect(roles[9] == NodeRole(.sampler, .scheduler))
    #expect(
        (roles[10], roles[11], roles[12], roles[13]) == (
            NodeRole(.latent), NodeRole(.sampler), NodeRole(.vaeDecode), NodeRole(.output)
        ))
    #expect(roles[14] == nil && roles[15] == nil)  // the size primitives
}

@Test(arguments: ["workflow_flux_ui", "workflow_zimage_ui", "workflow_anima_ui", "workflow_krea2_ui"])
func splitModelWorkflowsAreMarked(_ name: String) throws {
    let (doc, roles) = try marked(try coreWorkflow(name))
    let kinds = Set(roles.values.map(\.kind))
    #expect(kinds.isSuperset(of: [.diffusionModel, .textEncoders, .vae, .positive, .negative, .latent, .sampler]))
    if name.contains("flux_") { #expect(kinds.contains(.guidance)) }
    if name.contains("zimage") { #expect(kinds.contains(.shift)) }
    let s = ManagedGraph(doc, catalog: try kritaCatalog()).settings
    #expect(s.diffusionModel?.isEmpty == false && !s.positive.isEmpty && s.steps > 0, "\(name)")
}

@Test func theFrontendsOwnWorkflowIsMarked() throws {
    let (doc, roles) = try marked(try frontendWorkflow())
    #expect(Set(roles.values.map(\.kind)).isSuperset(of: [.checkpoint, .positive, .negative, .sampler, .output]))
    #expect(!ManagedGraph(doc, catalog: try kritaCatalog()).settings.positive.isEmpty)
}

@Test func whatIsMissingIsSaid() throws {
    var doc = try coreWorkflow("workflow_ui")
    doc.graph.removeNodes([6, 9])  // the positive prompt and the output
    let m = doc.markedAsTemplate(catalog: try kritaCatalog())
    #expect(m.missing == [.positive, .output])
    #expect(WorkflowDocument().markedAsTemplate(catalog: try kritaCatalog()).missing.first == .checkpoint)
}

@Test func earlierRolesAreReplaced() throws {
    let built = WorkflowBuilder.build(
        GenerationRequest(checkpoint: "a.safetensors", positive: "x", negative: "y", seed: 1),
        catalog: try kritaCatalog())
    let doc = try WorkflowDocument(built, catalog: try kritaCatalog())
    // A Lightbox graph marked again gets the same roles.
    #expect(doc.markedAsTemplate(catalog: try kritaCatalog()).doc.roles == doc.roles)
}

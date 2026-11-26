import ComfyKit
import Foundation
import LightboxCore

/// A value changed in the node graph, said in the form's terms. The graph
/// never changes a managed node itself: the change goes into the form's
/// state (`GraphTarget.apply`), and the graph is made from that again.
enum GraphChange: Equatable {
    case checkpoint(String)
    case vae(String)
    case textEncoders([String])
    case sampler(String)
    case scheduler(String)
    case steps(Int)
    case cfg(Double)
    case clipSkip(Int)
    case guidance(Double)
    case shift(Double)
    case size(width: Int, height: Int)
    case seed(Int)
    /// A LoRA's strength, on the image model and the text encoder.
    case lora(name: String, strength: Double, clipStrength: Double)
    /// A guide by its place in the form.
    case guide(index: Int, strength: Double, start: Double, end: Double)
    case faceFix(Double)
    case handFix(Double)
    /// A LoRA hung into the model chain in the graph.
    case addLora(name: String, strength: Double, clipStrength: Double)
    /// A LoRA's node deleted: an extra one goes, a preset's is switched off.
    case loraOff(String)
    case faceFixOff
    case handFixOff
    /// A guide's node deleted: the guide goes from the form.
    case guideOff(Int)

    /// What changed between two readings of a graph: `old` what the form
    /// made, `new` what the graph holds now. Prompts and pictures are
    /// locked and not looked at; nor are LoRAs that came or went.
    static func changes(from old: GraphSettings, to new: GraphSettings) -> [GraphChange] {
        var out: [GraphChange] = []
        if let model = new.checkpoint ?? new.diffusionModel, model != (old.checkpoint ?? old.diffusionModel) {
            out.append(.checkpoint(model))
        }
        if let vae = new.vae, vae != old.vae { out.append(.vae(vae)) }
        if new.textEncoders != old.textEncoders, !new.textEncoders.isEmpty {
            out.append(.textEncoders(new.textEncoders))
        }
        if new.sampler != old.sampler { out.append(.sampler(new.sampler)) }
        if let scheduler = new.scheduler, scheduler != old.scheduler { out.append(.scheduler(scheduler)) }
        if new.steps != old.steps { out.append(.steps(new.steps)) }
        if new.cfg != old.cfg { out.append(.cfg(new.cfg)) }
        if new.clipSkip != old.clipSkip { out.append(.clipSkip(new.clipSkip)) }
        if let guidance = new.guidance, guidance != old.guidance { out.append(.guidance(guidance)) }
        if let shift = new.shift, shift != old.shift { out.append(.shift(shift)) }
        if let w = new.width, let h = new.height, (w, h) != (old.width ?? 0, old.height ?? 0) {
            out.append(.size(width: w, height: h))
        }
        if new.seed != old.seed { out.append(.seed(new.seed)) }
        for lora in new.loras {
            guard let before = old.loras.first(where: { $0.name == lora.name }), before != lora else { continue }
            out.append(.lora(name: lora.name, strength: lora.strength, clipStrength: lora.clipStrength))
        }
        for (i, g) in new.guides.sorted(by: { $0.key < $1.key }) where old.guides[i] != nil && old.guides[i] != g {
            out.append(.guide(index: i, strength: g.strength, start: g.start, end: g.end))
        }
        if let fix = new.faceFix, let before = old.faceFix, fix.denoise != before.denoise {
            out.append(.faceFix(fix.denoise))
        }
        if let fix = new.handFix, let before = old.handFix, fix.denoise != before.denoise {
            out.append(.handFix(fix.denoise))
        }
        return out
    }
}

/// What the Generate form holds that the graph can change.
struct GraphTarget: Equatable {
    /// How far a guide reaches; the picture and kind stay with the form.
    struct GuideReach: Equatable {
        var strength: Double
        var start: Double
        var end: Double
    }

    /// The preset as saved; never changed here.
    var preset: GenerationPreset
    /// The workflow's changes to it.
    var overrides = PresetOverrides()
    /// `nil`: the preset's size.
    var size: ImageSize?
    /// Empty: a new random seed each run.
    var seedText = ""
    var extraLoras: [LoraSlot] = []
    var guides: [GuideReach] = []
    /// Guides taken out, by their place in the form.
    var removedGuides: Set<Int> = []
    var finish = FinishSettings()

    /// The preset the workflow generates with.
    var effectivePreset: GenerationPreset { overrides.applied(to: preset) }

    mutating func apply(_ change: GraphChange) {
        switch change {
        case .checkpoint(let v): overrides.checkpoint = v
        case .vae(let v): overrides.vae = v
        case .textEncoders(let v): overrides.textEncoders = v
        case .sampler(let v): overrides.sampler = v
        case .scheduler(let v): overrides.scheduler = v
        case .steps(let v): overrides.steps = v
        case .cfg(let v): overrides.cfg = v
        case .clipSkip(let v): overrides.clipSkip = v
        case .guidance(let v): overrides.guidance = v
        case .shift(let v): overrides.shift = v
        case .size(let w, let h):
            size = (w, h) == (preset.width, preset.height) ? nil : ImageSize(width: w, height: h)
        case .seed(let v): seedText = String(v)
        case .lora(let name, let strength, let clip):
            // A preset LoRA at another strength is an extra LoRA of the same
            // name: `compose` loads it once, at the extra one's strength.
            let clipStrength = clip == strength ? nil : clip
            if let i = extraLoras.lastIndex(where: { $0.name == name && $0.isActive }) {
                extraLoras[i].strength = strength
                extraLoras[i].clipStrength = clipStrength
            } else {
                let triggers = preset.loras.first { $0.name == name }?.triggers ?? ""
                extraLoras.append(
                    LoraSlot(name: name, strength: strength, clipStrength: clipStrength, triggers: triggers))
            }
        case .guide(let i, let strength, let start, let end):
            guard guides.indices.contains(i) else { return }
            guides[i] = GuideReach(strength: strength, start: start, end: end)
        case .faceFix(let v): finish.faceStrength = v
        case .handFix(let v): finish.handStrength = v
        case .addLora(let name, let strength, let clip):
            overrides.disabledLoras?.removeAll { $0 == name }
            apply(.lora(name: name, strength: strength, clipStrength: clip))
        case .loraOff(let name):
            extraLoras.removeAll { $0.name == name }
            if preset.loras.contains(where: { $0.name == name && $0.isActive }) {
                overrides.disabledLoras = (overrides.disabledLoras ?? []).filter { $0 != name } + [name]
            }
        case .faceFixOff: finish.fixFaces = false
        case .handFixOff: finish.fixHands = false
        case .guideOff(let i): removedGuides.insert(i)
        }
        overrides = overrides.trimmed(for: preset)
    }
}

extension PresetOverrides {
    /// Each value the workflow changes, said with the preset's own:
    /// "Steps: 12 (preset 30)".
    func entries(for preset: GenerationPreset) -> [(field: Field, text: String)] {
        func number(_ d: Double) -> String { NodeRowText.value(.double(d)) }
        func file(_ s: String?) -> String { s.map { ($0 as NSString).lastPathComponent } ?? "—" }
        func files(_ list: [String]) -> String { list.map(file).joined(separator: ", ") }
        return fields.map { field in
            let text: String =
                switch field {
                case .checkpoint: "Model: \(file(checkpoint)) (preset \(file(preset.checkpoint)))"
                case .vae: "VAE: \(file(vae)) (preset \(file(preset.vae)))"
                case .textEncoders:
                    "Text encoders: \(files(textEncoders ?? [])) (preset \(files(preset.textEncoders)))"
                case .sampler: "Sampler: \(sampler ?? "") (preset \(preset.sampler))"
                case .scheduler: "Scheduler: \(scheduler ?? "") (preset \(preset.scheduler))"
                case .steps: "Steps: \(steps ?? 0) (preset \(preset.steps))"
                case .cfg: "CFG: \(number(cfg ?? 0)) (preset \(number(preset.cfg)))"
                case .clipSkip: "CLIP skip: \(clipSkip ?? 1) (preset \(preset.clipSkip))"
                case .guidance: "Guidance: \(number(guidance ?? 0)) (preset \(number(preset.guidance)))"
                case .shift: "Shift: \(number(shift ?? 0)) (preset \(number(preset.shift)))"
                case .disabledLoras: "LoRA off: \((disabledLoras ?? []).map(file).joined(separator: ", ")) (preset on)"
                }
            return (field, text)
        }
    }
}

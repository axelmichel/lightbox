import Foundation

/// Preset values a workflow changes, set in the node graph. The preset
/// itself stays as it is; `applied(to:)` gives the preset the workflow
/// generates with. Prompt conventions (dialect, style and negative
/// prompts) are always the preset's.
public struct PresetOverrides: Codable, Hashable, Sendable {
    /// The checkpoint, or the diffusion model of a split model.
    public var checkpoint: String?
    public var vae: String?
    public var textEncoders: [String]?
    public var sampler: String?
    public var scheduler: String?
    public var steps: Int?
    public var cfg: Double?
    public var clipSkip: Int?
    public var guidance: Double?
    public var shift: Double?
    /// The preset's LoRAs switched off in the graph, by file name.
    public var disabledLoras: [String]?

    /// One of the values, to list or reset it.
    public enum Field: CaseIterable, Sendable {
        case checkpoint, vae, textEncoders, sampler, scheduler, steps, cfg, clipSkip, guidance, shift, disabledLoras
    }

    public init() {}

    public var isEmpty: Bool { self == PresetOverrides() }

    /// The values set, in `Field` order.
    public var fields: [Field] {
        Field.allCases.filter { field in
            var o = self
            o.reset(field)
            return o != self
        }
    }

    /// Back to the preset's value.
    public mutating func reset(_ field: Field) {
        switch field {
        case .checkpoint: checkpoint = nil
        case .vae: vae = nil
        case .textEncoders: textEncoders = nil
        case .sampler: sampler = nil
        case .scheduler: scheduler = nil
        case .steps: steps = nil
        case .cfg: cfg = nil
        case .clipSkip: clipSkip = nil
        case .guidance: guidance = nil
        case .shift: shift = nil
        case .disabledLoras: disabledLoras = nil
        }
    }

    public func applied(to preset: GenerationPreset) -> GenerationPreset {
        var p = preset
        if let checkpoint { p.checkpoint = checkpoint }
        if let vae { p.vae = vae }
        if let textEncoders { p.textEncoders = textEncoders }
        if let sampler { p.sampler = sampler }
        if let scheduler { p.scheduler = scheduler }
        if let steps { p.steps = steps }
        if let cfg { p.cfg = cfg }
        if let clipSkip { p.clipSkip = clipSkip }
        if let guidance { p.guidance = guidance }
        if let shift { p.shift = shift }
        if let disabledLoras {
            for i in p.loras.indices where disabledLoras.contains(p.loras[i].name) { p.loras[i].enabled = false }
        }
        return p
    }

    /// Without the values that are the preset's own anyway.
    public func trimmed(for preset: GenerationPreset) -> PresetOverrides {
        var o = self
        if checkpoint == preset.checkpoint { o.checkpoint = nil }
        if vae == preset.vae { o.vae = nil }
        if textEncoders == preset.textEncoders { o.textEncoders = nil }
        if sampler == preset.sampler { o.sampler = nil }
        if scheduler == preset.scheduler { o.scheduler = nil }
        if steps == preset.steps { o.steps = nil }
        if cfg == preset.cfg { o.cfg = nil }
        if clipSkip == preset.clipSkip { o.clipSkip = nil }
        if guidance == preset.guidance { o.guidance = nil }
        if shift == preset.shift { o.shift = nil }
        // Only LoRAs the preset has and uses can be switched off.
        let active = Set(preset.loras.filter(\.isActive).map(\.name))
        let off = (disabledLoras ?? []).filter { active.contains($0) }
        o.disabledLoras = off.isEmpty ? nil : off
        return o
    }
}

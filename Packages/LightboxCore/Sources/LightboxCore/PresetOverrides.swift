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

    public init() {}

    public var isEmpty: Bool { self == PresetOverrides() }

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
        return o
    }
}

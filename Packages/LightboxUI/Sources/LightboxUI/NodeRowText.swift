import ComfyKit

/// What a widget row of the node graph says, and whether it is locked.
enum NodeRowText {
    /// Rows the configurator keeps for itself, even in a workflow changed
    /// in the graph: the prompt texts and the pictures.
    static func isLocked(_ role: NodeRole?, input: String) -> Bool {
        guard let role else { return false }
        switch (role.kind, role.part) {
        case (.positive, nil), (.negative, nil): return input == "text"
        case (_, .image?), (_, .mask?): return input == "image"
        default: return false
        }
    }

    /// Rows that stand for a setting of the form, so changing one in the
    /// graph changes the form (`GraphChange`). Others are read-only.
    static func isEditable(_ role: NodeRole?, input: String) -> Bool {
        guard let role else { return false }
        let inputs: [String] =
            switch (role.kind, role.part) {
            case (.checkpoint, nil): ["ckpt_name"]
            case (.diffusionModel, nil): ["unet_name"]
            case (.textEncoders, nil): ["clip_name", "clip_name1", "clip_name2"]
            case (.vae, nil): ["vae_name"]
            case (.lora, nil): ["strength_model", "strength_clip"]
            case (.shift, nil): ["shift"]
            case (.clipSkip, nil): ["stop_at_clip_layer"]
            case (.guidance, nil): ["guidance"]
            case (.latent, nil): ["width", "height"]
            case (.sampler, nil): ["seed", "steps", "cfg", "sampler_name", "scheduler"]
            // Flux 2 spreads its sampler over several nodes.
            case (.sampler, .noise?): ["noise_seed"]
            case (.sampler, .guider?): ["cfg"]
            case (.sampler, .select?): ["sampler_name"]
            case (.sampler, .scheduler?): ["steps"]
            // ControlNet, or IP-Adapter.
            case (.guide, nil): ["strength", "start_percent", "end_percent", "weight", "start_at", "end_at"]
            case (.faceFix, nil), (.handFix, nil): ["denoise"]
            default: []
            }
        return inputs.contains(input)
    }

    /// A value as ComfyUI shows it: numbers with a point and at most three
    /// decimals, whole numbers without.
    static func value(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?:
            let r = (d * 1000).rounded() / 1000
            return r == r.rounded() && abs(r) < 1e15 ? String(Int(r)) : String(r)
        case .bool(let b)?: return b ? "true" : "false"
        case .array?, .object?: return "…"
        case .null?, nil: return "—"
        }
    }
}

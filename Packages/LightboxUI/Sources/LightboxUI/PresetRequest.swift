import ComfyKit
import LightboxCore

/// Turning a preset into a ComfyUI request: one checkpoint, or for Flux,
/// Z-Image and Anima the diffusion model with its text encoders and VAE.
extension GenerationPreset {
    /// What keeps the preset from running on the server; `nil` = ready.
    func problem(with catalog: ComfyCatalog) -> String? {
        guard !checkpoint.isEmpty else { return "The preset “\(name)” has no model yet." }
        guard family.isSupported else {
            return "“\(checkpoint)” is a model Lightbox can't load yet (SD3 and similar)."
        }
        guard let split = splitRequest(negative: "") else { return nil }
        if textEncoders.filter({ !$0.isEmpty }).count < family.textEncoderCount {
            let need =
                switch family {
                case .flux: "two text encoders (T5 and CLIP-L)"
                case .flux2: "a text encoder (Qwen3 8B for Klein 9B, 4B for Klein 4B)"
                case .anima: "a text encoder (Qwen3 0.6B)"
                case .krea2: "a text encoder (Qwen3-VL 4B)"
                default: "a text encoder (Qwen3 4B)"
                }
            return "The preset “\(name)” needs \(need); pick them under Edit Presets."
        }
        if vae?.isEmpty ?? true {
            let usual =
                switch family {
                case .flux2: "flux2-vae.safetensors"
                case .anima, .krea2: "qwen_image_vae.safetensors"
                default: "ae.safetensors"
                }
            return "The preset “\(name)” needs a VAE (usually \(usual)); pick it under Edit Presets."
        }
        let missing = split.requiredNodes.filter { !catalog.has($0) }
        if !catalog.nodes.isEmpty, !missing.isEmpty {
            let gguf = missing.contains { $0.hasSuffix("GGUF") } ? " GGUF files need the ComfyUI-GGUF nodes." : ""
            return "The server lacks \(missing.joined(separator: ", ")).\(gguf)"
        }
        return nil
    }

    /// The split-model part of the request; `nil` for checkpoints.
    func splitRequest(negative: String) -> SplitModelRequest? {
        guard family.isSplit else { return nil }
        let clipType =
            switch family {
            case .flux: "flux"
            case .flux2: "flux2"
            // Anima's Qwen3 encoder is loaded as "stable_diffusion".
            case .anima: "stable_diffusion"
            case .krea2: "krea2"
            default: "lumina2"
            }
        return SplitModelRequest(
            model: checkpoint, textEncoders: Array(textEncoders.prefix(family.textEncoderCount)),
            clipType: clipType, vae: vae ?? "",
            guidance: family == .flux ? guidance : nil, shift: family == .zImage ? shift : nil,
            // Flux and Krea 2 have no negative prompt; one typed is still
            // used (it matters only with a CFG above 1).
            zeroNegative: [.flux, .flux2, .krea2].contains(family)
                && negative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sampling: family == .flux2 ? .flux2 : .standard,
            emptyLatent: family == .anima || family == .krea2 ? "EmptyLatentImage" : "EmptySD3LatentImage")
    }

    /// The request for a composed prompt, at the preset's size unless
    /// `width` and `height` are given.
    func request(
        _ prompt: ComposedPrompt, seed: Int, width: Int? = nil, height: Int? = nil, batchSize: Int = 1,
        guides: [GuideRequest] = [], faceFix: DetailerRequest? = nil, handFix: DetailerRequest? = nil,
        inpaint: InpaintSource? = nil
    ) -> GenerationRequest {
        GenerationRequest(
            checkpoint: checkpoint, vae: vae,
            loras: prompt.loras.map { LoraRequest(name: $0.name, strength: $0.weight, clipStrength: $0.clipWeight) },
            positive: prompt.positive, negative: prompt.negative, width: width ?? self.width,
            height: height ?? self.height, steps: steps, cfg: cfg, sampler: sampler, scheduler: scheduler, seed: seed,
            batchSize: max(1, batchSize), clipSkip: clipSkip, guides: guides, faceFix: faceFix, handFix: handFix,
            inpaint: inpaint, split: splitRequest(negative: prompt.negative))
    }
}

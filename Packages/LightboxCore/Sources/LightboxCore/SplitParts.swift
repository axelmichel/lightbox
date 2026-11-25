import Foundation

/// The text encoders and VAE a Flux or Z-Image model is loaded with, picked
/// from the server's files by name. Each pick adds a note, and a missing
/// file says what to put on the server.
public enum SplitParts {
    public struct Choice: Equatable, Sendable {
        public var textEncoders: [String]
        public var vae: String?
        public var notes: [String]
    }

    /// `model` is the diffusion model's file; Flux 2 Klein 4B and 9B want
    /// different text encoders.
    public static func choose(for family: ModelFamily, model: String = "", textEncoders: [String], vaes: [String])
        -> Choice
    {
        var notes: [String] = []
        var encoders: [String] = []
        func pick(_ what: String, _ fragments: [String], from files: [String], example: String) -> String? {
            for f in fragments {
                if let file = files.first(where: { key($0).contains(f) }) {
                    notes.append("\(what): “\(file)”, found by its name.")
                    return file
                }
            }
            notes.append("\(what): none on the server; it needs one such as \(example).")
            return nil
        }
        switch family {
        case .flux:
            // T5 first, then CLIP-L, as the Flux workflows have them.
            if let t5 = pick(
                "T5 text encoder", ["t5xxl", "t5v11xxl", "t5"], from: textEncoders,
                example: "t5xxl_fp8_e4m3fn.safetensors")
            {
                encoders.append(t5)
            }
            if let clip = pick("CLIP-L text encoder", ["clipl"], from: textEncoders, example: "clip_l.safetensors") {
                encoders.append(clip)
            }
        case .zImage:
            if let qwen = pick(
                "Qwen3 text encoder", ["qwen34b", "qwen3"], from: textEncoders, example: "qwen_3_4b.safetensors")
            {
                encoders.append(qwen)
            }
        case .flux2:
            // Klein 4B goes with Qwen3 4B, 9B with Qwen3 8B.
            let small = key(model).contains("4b")
            if let qwen = pick(
                "Qwen3 text encoder", small ? ["qwen34b", "qwen3"] : ["qwen38b", "qwen3"], from: textEncoders,
                example: small ? "qwen_3_4b.safetensors" : "qwen_3_8b.safetensors")
            {
                encoders.append(qwen)
            }
            let vae = pick(
                "VAE", ["flux2vae", "flux2"], from: vaes.filter { $0 != "pixel_space" },
                example: "flux2-vae.safetensors")
            return Choice(textEncoders: encoders, vae: vae, notes: notes)
        default:
            return Choice(textEncoders: [], vae: nil, notes: [])
        }
        // Both use the Flux VAE, usually called "ae".
        let vae =
            vaes.first { stem($0) == "ae" }.map { file -> String in
                notes.append("VAE: “\(file)”, the Flux VAE both use.")
                return file
            }
            ?? pick(
                "VAE", ["fluxvae", "fluxae", "ae"], from: vaes.filter { $0 != "pixel_space" }, example: "ae.safetensors"
            )
        return Choice(textEncoders: encoders, vae: vae, notes: notes)
    }

    /// Lower case, letters and digits only: "t5-v1_1-xxl" → "t5v11xxl".
    static func key(_ file: String) -> String {
        PresetDetector.fileName(file).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func stem(_ file: String) -> String {
        (PresetDetector.fileName(file) as NSString).deletingPathExtension.lowercased()
    }
}

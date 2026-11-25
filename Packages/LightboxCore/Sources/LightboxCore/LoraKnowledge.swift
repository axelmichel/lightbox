// What the LoRA info page starts with, besides the trigger words:
// - a summary of the file's header metadata (title, author, description,
//   base model, training, most frequent training tags) and a sample prompt
//   made from its triggers and tags;
// - the settings their makers give for well-known LoRAs (Hyper-SD,
//   SDXL-Lightning, LCM, DMD2, detail tweakers), matched by file name;
// - otherwise, a starting point for the LoRA's kind.

import Foundation

/// The settings published for a well-known LoRA.
struct KnownLora: Sendable {
    var title: String
    var notes: [String]
    var strength: Double
    var link: String

    /// The known LoRA `name` is a copy of, if any.
    static func match(_ name: String) -> KnownLora? {
        let file = PresetDetector.fileName(name).lowercased()
        let steps = file.firstMatch(of: /(\d+)[-_ ]?steps?/).flatMap { Int($0.output.1) }
        let stepText = steps.map { "\($0) steps" } ?? "the step count in its name"

        if file.contains("hyper-sd") || file.contains("hyper_sd") {
            let sd15 = file.contains("sd15") || file.contains("sd1.5")
            let base = sd15 ? "SD 1.5" : "SDXL"
            var notes = ["Hyper-SD (ByteDance) speed LoRA for \(base) models."]
            if file.contains("cfg") {
                notes.append(
                    "Settings: \(stepText), CFG 5–8 (this version keeps CFG working, so the negative prompt "
                        + "still counts), sampler euler, scheduler sgm_uniform, strength 1.")
            } else {
                notes.append(
                    "Settings: \(stepText), CFG 1 (the negative prompt has no effect), sampler euler, "
                        + "scheduler sgm_uniform, strength 1.")
            }
            if steps == 1 { notes.append("The 1-step version needs the TCD scheduler; it is unreliable otherwise.") }
            notes.append("No trigger word. Set the preset's steps and CFG to match (Suggest Settings does this).")
            return KnownLora(
                title: "Hyper-SD", notes: notes, strength: 1, link: "https://huggingface.co/ByteDance/Hyper-SD")
        }
        if file.contains("lightning") {
            return KnownLora(
                title: "SDXL-Lightning",
                notes: [
                    "SDXL-Lightning (ByteDance) speed LoRA for SDXL models.",
                    "Settings: \(stepText), CFG 1 (the negative prompt has no effect), sampler euler, "
                        + "scheduler sgm_uniform, strength 1.",
                    "No trigger word. Set the preset's steps and CFG to match (Suggest Settings does this).",
                ], strength: 1, link: "https://huggingface.co/ByteDance/SDXL-Lightning")
        }
        if file.contains("dmd2") {
            return KnownLora(
                title: "DMD2",
                notes: [
                    "DMD2 speed LoRA for SDXL models.",
                    "Settings: 4 steps, CFG 1, sampler lcm, scheduler sgm_uniform, strength 1.",
                    "No trigger word.",
                ], strength: 1, link: "https://huggingface.co/tianweiy/DMD2")
        }
        if file.contains("lcm") {
            let sd15 = file.contains("sdv1") || file.contains("sd15") || file.contains("sd1.5")
            return KnownLora(
                title: "LCM-LoRA",
                notes: [
                    "Latent Consistency speed LoRA for \(sd15 ? "SD 1.5" : "SDXL") models.",
                    "Settings: 4–8 steps, CFG 1–2, sampler lcm, scheduler sgm_uniform, strength 1.",
                    "No trigger word.",
                ], strength: 1,
                link: sd15
                    ? "https://huggingface.co/latent-consistency/lcm-lora-sdv1-5"
                    : "https://huggingface.co/latent-consistency/lcm-lora-sdxl")
        }
        if file.hasPrefix("add_detail") || file.hasPrefix("add-detail") || file.contains("detail tweaker")
            || file.contains("detail_tweaker")
        {
            return KnownLora(
                title: "Detail Tweaker",
                notes: [
                    "Detail Tweaker: more detail at positive strengths, a smoother, simpler look at negative ones.",
                    "Strength 0.5–1 for more detail, −0.5 to −1 for less; it works across −2…2. No trigger word.",
                ], strength: 0.6, link: "")
        }
        return nil
    }

    /// A starting point for a LoRA of `kind` that isn't known.
    static func advice(for kind: LoraInfo.Kind) -> String? {
        switch kind {
        case .speed:
            "Speed LoRA: the preset's steps and CFG must match it, usually 4–8 steps at CFG 1–2. "
                + "Suggest Settings in the preset editor sets them."
        case .slider:
            "Slider: the strength sets how much and which way; try −3…3, 0 is off. No trigger word."
        case .detail:
            "Detail LoRA: 0.3–1 adds detail; negative values smooth it out."
        case .style:
            "Style LoRA: start at 0.6–0.9; higher values can override the checkpoint's own look."
        case .other:
            nil
        }
    }
}

extension LoraDetector {
    /// Lines about the LoRA from its header metadata, for the notes.
    static func summary(metadata meta: [String: String], name: String, counts: [String: Int]) -> [String] {
        func text(_ key: String) -> String? {
            guard let v = meta[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, v != "None" else {
                return nil
            }
            return v
        }
        var lines: [String] = []
        let stem = (PresetDetector.fileName(name) as NSString).deletingPathExtension
        if let title = text("modelspec.title"), title != stem { lines.append("Title: \(title)") }
        if let author = text("modelspec.author") { lines.append("By \(author)") }
        if let description = text("modelspec.description") { lines.append(String(description.prefix(500))) }
        if let hint = text("modelspec.usage_hint") { lines.append("Use: \(hint)") }
        if let comment = text("ss_training_comment") { lines.append("Trainer's comment: \(comment)") }

        var trained: [String] = []
        if let base = text("ss_sd_model_name") { trained.append("from “\(base)”") }
        if let pictures = text("ss_num_train_images") { trained.append("\(pictures) pictures") }
        if let epochs = text("ss_num_epochs") ?? text("ss_epoch") { trained.append("\(epochs) epochs") }
        if let resolution = text("ss_resolution") ?? text("modelspec.resolution") {
            trained.append(
                "at \(resolution.replacingOccurrences(of: #"[()\s]"#, with: "", options: .regularExpression))")
        }
        if let dim = text("ss_network_dim") { trained.append("rank \(dim)") }
        if !trained.isEmpty { lines.append("Trained \(trained.joined(separator: ", ")).") }

        let tags = topTags(counts, limit: 12)
        if !tags.isEmpty { lines.append("Most frequent training tags: \(tags.joined(separator: ", ")).") }
        return lines
    }

    /// A prompt that shows the LoRA off: its triggers and the tags most of
    /// its training pictures had.
    static func samplePrompt(triggers: [String], counts: [String: Int]) -> String {
        var parts = triggers
        for tag in topTags(counts, limit: 10) where !parts.contains(tag) { parts.append(tag) }
        return parts.joined(separator: ", ")
    }

    /// The most frequent training tags, without quality, rating and sexual terms.
    static func topTags(_ counts: [String: Int], limit: Int) -> [String] {
        counts.filter { tag, _ in
            !Fragments.commonTags.contains(tag) || Fragments.booruTags.contains(tag) || tag.hasSuffix(" hair")
                || tag.hasSuffix(" eyes")
        }
        .filter { tag, _ in
            !Fragments.qualityTags.contains(tag) && ContentGuard.match(tag, Terms.explicit) == nil
                && ContentGuard.match(tag, Terms.suggestive) == nil
        }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        .prefix(limit).map(\.key)
    }
}

extension Fragments {
    static let qualityTags: Set<String> = [
        "masterpiece", "best quality", "high quality", "good quality", "normal quality", "low quality",
        "worst quality", "amazing quality", "very aesthetic", "aesthetic", "absurdres", "highres", "lowres",
        "incredibly absurdres", "newest", "recent", "sensitive", "general", "safe", "questionable", "explicit",
        "nsfw", "sfw", "simple background", "white background", "signature", "watermark", "artist name", "dated",
        "username", "english text", "text", "blurry", "jpeg artifacts",
    ]
}

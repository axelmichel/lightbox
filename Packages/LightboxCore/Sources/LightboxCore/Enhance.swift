// Instructions for the prompt helper (an Ollama model). It only rewrites
// the text in the prompt field; the result is shown for the user to accept
// and is composed and guarded like anything typed.

import Foundation

public enum PromptEnhancer {
    /// The system prompt for rewriting a prompt for `preset`. The preset's
    /// style terms, the picked `modifiers` and the LoRA `triggers` are added
    /// by `compose()`, so the model is told not to repeat them.
    public static func instructions(
        preset: GenerationPreset, modifiers: [StyleModifier] = [], triggers: [String] = [], direction: String = ""
    ) -> String {
        var lines: [String] = [
            "You improve prompts for an image generation model (Stable Diffusion, \(preset.family.label)).",
            "The user gives a short idea. Rewrite it into one better prompt for that model.",
        ]

        switch (preset.dialect, preset.family) {
        case (.tags, .illustrious), (.tags, .pony):
            lines.append(
                "Write Danbooru tags, comma-separated, lowercase, with spaces instead of underscores "
                    + "(e.g. \"1girl, long hair, red scarf, snowy forest, looking at viewer\"). "
                    + "Start with the subject count tags, then the character, clothing, pose, setting and composition.")
        case (.tags, _):
            lines.append(
                "Write short comma-separated tags and phrases, most important first: subject, details, setting, "
                    + "composition.")
        case (.natural, _):
            lines.append(
                "Write one or two plain, concrete sentences, as a photo or picture caption would describe it: "
                    + "subject first, then what they do, the setting, and the composition.")
        }

        switch preset.style {
        case .photo:
            lines.append(
                "It is a photograph: describe real, visible things (materials, weather, time of day, framing). "
                    + "Don't call it a painting, render or illustration.")
        case .anime:
            lines.append(
                "It is an anime or comic picture: add expression, pose, outfit details, background and framing.")
        case .illustration:
            lines.append("It is an illustration: add the scene, mood, colors and composition.")
        }

        lines.append(
            "Keep it under about 60 words or 40 tags. Keep the user's subject and every detail they asked for; "
                + "add only what fits. Don't add text, logos or watermarks.")

        var added: [String] = []
        if !preset.stylePrompt.isEmpty { added.append(preset.stylePrompt) }
        added += modifiers.map(\.positive).filter { !$0.isEmpty }
        added += triggers.filter { !$0.isEmpty }
        if !added.isEmpty {
            lines.append(
                "These terms are added automatically; don't repeat them or contradict them: "
                    + added.joined(separator: ", ") + ".")
        }

        lines.append(
            "Don't add nudity or sexual content the user didn't ask for. Never describe a child or minor "
                + "in a sexual or suggestive way; if the idea shows children, keep it wholesome.")
        let hint = preset.enhanceHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty { lines.append("For this model: \(hint)") }
        let dir = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dir.isEmpty { lines.append("The user also wants: \(dir)") }
        lines.append("Answer with the prompt only: no explanation, no quotes, no heading.")
        return lines.joined(separator: "\n")
    }

    /// The prompt from a model's answer: without code fences, a leading
    /// "Prompt:", surrounding quotes, or a thinking block.
    public static func clean(_ answer: String) -> String {
        var text = answer
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        text = text.replacingOccurrences(of: "```[a-z]*", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = text.range(
            of: #"^(\*\*)?(improved |enhanced |rewritten )?prompt(\*\*)?\s*:\s*(\*\*)?"#,
            options: [.regularExpression, .caseInsensitive])
        {
            text.removeSubrange(r)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")]
        where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close) {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

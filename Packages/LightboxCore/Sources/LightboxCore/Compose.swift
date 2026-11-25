// Deterministic prompt composition: same inputs, same prompt. Every
// fragment is weight-canonicalized before joining (see `Weights`) and the
// whole generation goes through `ContentGuard`.

import Foundation

public struct PromptInput: Sendable {
    public var preset: GenerationPreset
    /// The prompt typed by the user.
    public var prompt: String
    /// Extra negative terms typed by the user.
    public var negative: String
    /// LoRAs switched on for this generation, on top of the preset's.
    public var extraLoras: [LoraSlot]
    /// Camera, light, film or comic styles picked for this generation.
    public var modifiers: [StyleModifier]
    public var rating: ContentRating

    public init(
        preset: GenerationPreset, prompt: String, negative: String = "", extraLoras: [LoraSlot] = [],
        modifiers: [StyleModifier] = [], rating: ContentRating
    ) {
        self.preset = preset
        self.prompt = prompt
        self.negative = negative
        self.extraLoras = extraLoras
        self.modifiers = modifiers
        self.rating = rating
    }
}

public struct LoraUse: Codable, Hashable, Sendable {
    public var name: String
    public var weight: Double
    /// Text-encoder strength; usually the same as `weight`.
    public var clipWeight: Double

    public init(name: String, weight: Double, clipWeight: Double? = nil) {
        self.name = name
        self.weight = weight
        self.clipWeight = clipWeight ?? weight
    }
}

public struct ComposedPrompt: Codable, Hashable, Sendable {
    public var positive: String
    public var negative: String
    public var loras: [LoraUse]
    /// Set when the guard treated the image as showing a minor.
    public var minorSignal: String?

    public init(positive: String, negative: String, loras: [LoraUse], minorSignal: String? = nil) {
        self.positive = positive
        self.negative = negative
        self.loras = loras
        self.minorSignal = minorSignal
    }
}

public func compose(_ input: PromptInput) throws(GuardError) -> ComposedPrompt {
    let preset = input.preset

    // A LoRA that is in the preset and switched on again is loaded once,
    // with the strength chosen for this generation.
    var loras: [LoraUse] = []
    func use(_ l: LoraSlot) {
        let u = LoraUse(name: l.name, weight: l.strength, clipWeight: l.clipStrength)
        if let i = loras.firstIndex(where: { $0.name == u.name }) { loras[i] = u } else { loras.append(u) }
    }
    let presetLoras = preset.loras.filter(\.isActive)
    let extraLoras = input.extraLoras.filter(\.isActive)
    for l in presetLoras + extraLoras { use(l) }
    let triggers = (presetLoras + extraLoras).map(\.triggers)

    let looks = input.modifiers.map(\.positive)
    let userNegatives = [preset.negativePrompt, input.negative] + input.modifiers.map(\.negative)
    let result = try ContentGuard.check(
        GuardInput(
            positive: [preset.stylePrompt, input.prompt] + triggers + looks, negative: userNegatives,
            loraNames: loras.map(\.name), rating: input.rating))

    var pos: [String] = []
    push(&pos, preset.stylePrompt)
    for part in triggers { push(&pos, part) }
    push(&pos, input.prompt)
    for part in looks { push(&pos, part) }

    var neg: [String] = []
    for part in userNegatives { push(&neg, part) }
    for term in result.forcedNegatives { push(&neg, term) }

    return ComposedPrompt(
        positive: joinDedup(pos), negative: joinDedup(neg), loras: loras, minorSignal: result.minorSignal)
}

/// Add a fragment in canonical weight form, so its brackets are balanced and
/// its weights cannot spill over into the fragments after it.
func push(_ parts: inout [String], _ text: String) {
    let t = Weights.canonical(text).trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
    if !t.isEmpty { parts.append(t) }
}

/// Join fragments with ", " and drop repeated comma-separated terms
/// (case-insensitive), keeping the first occurrence.
func joinDedup(_ parts: [String]) -> String {
    var seen = Set<String>()
    var out: [String] = []
    for part in parts {
        for term in Weights.splitTerms(part) {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
    }
    return out.joined(separator: ", ")
}

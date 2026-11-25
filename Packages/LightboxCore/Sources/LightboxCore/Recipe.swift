import Foundation

/// Everything that went into one generation, stored with its picture so it
/// can be explained and made again. Reusing a recipe goes through
/// `compose()` again; a recipe is never sent to ComfyUI as it is.
public struct GenerationRecipe: Codable, Hashable, Sendable {
    /// A picture that guided the generation (ControlNet or IP-Adapter).
    public struct GuideUse: Codable, Hashable, Sendable {
        /// `ControlKind` raw value (ComfyKit), e.g. "pose".
        public var kind: String
        public var strength: Double
        public var startPercent: Double
        public var endPercent: Double
        public var extract: Bool
        /// The guide picture's file name in the gallery's `guides` folder.
        public var image: String

        public init(
            kind: String, strength: Double, startPercent: Double = 0, endPercent: Double = 1, extract: Bool = true,
            image: String
        ) {
            self.kind = kind
            self.strength = strength
            self.startPercent = startPercent
            self.endPercent = endPercent
            self.extract = extract
            self.image = image
        }
    }

    /// The preset as it was then, with the size actually used.
    public var preset: GenerationPreset
    /// The prompt as typed.
    public var prompt: String
    public var negative: String
    public var extraLoras: [LoraSlot]
    /// The camera, light, film or comic styles used, as they were then.
    public var modifiers: [StyleModifier]
    public var rating: ContentRating
    public var finish: FinishSettings
    public var guides: [GuideUse]
    public var seed: Int
    /// Which picture of the batch this was (they share the seed).
    public var batchIndex: Int
    /// What was sent to ComfyUI.
    public var sent: ComposedPrompt
    /// Face and hand fix detectors used, if any.
    public var faceDetector: String?
    public var handDetector: String?
    /// ComfyUI server address and version, for reference.
    public var server: String?

    public init(
        input: PromptInput, sent: ComposedPrompt, seed: Int, batchIndex: Int = 0, finish: FinishSettings,
        guides: [GuideUse] = [], faceDetector: String? = nil, handDetector: String? = nil, server: String? = nil
    ) {
        preset = input.preset
        prompt = input.prompt
        negative = input.negative
        extraLoras = input.extraLoras
        modifiers = input.modifiers
        rating = input.rating
        self.finish = finish
        self.guides = guides
        self.seed = seed
        self.batchIndex = batchIndex
        self.sent = sent
        self.faceDetector = faceDetector
        self.handDetector = handDetector
        self.server = server
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(GenerationPreset.self, forKey: .preset)
        prompt = try c.decode(String.self, forKey: .prompt)
        negative = try c.decode(String.self, forKey: .negative)
        extraLoras = try c.decodeIfPresent([LoraSlot].self, forKey: .extraLoras) ?? []
        modifiers = try c.decodeIfPresent([StyleModifier].self, forKey: .modifiers) ?? []
        rating = try c.decode(ContentRating.self, forKey: .rating)
        finish = try c.decodeIfPresent(FinishSettings.self, forKey: .finish) ?? FinishSettings()
        guides = try c.decodeIfPresent([GuideUse].self, forKey: .guides) ?? []
        seed = try c.decode(Int.self, forKey: .seed)
        batchIndex = try c.decodeIfPresent(Int.self, forKey: .batchIndex) ?? 0
        sent = try c.decode(ComposedPrompt.self, forKey: .sent)
        faceDetector = try c.decodeIfPresent(String.self, forKey: .faceDetector)
        handDetector = try c.decodeIfPresent(String.self, forKey: .handDetector)
        server = try c.decodeIfPresent(String.self, forKey: .server)
    }

    /// Labelled lines for the info panel, in reading order.
    public var details: [(label: String, value: String)] {
        let p = preset
        var rows: [(String, String)] = [
            ("Preset", p.name),
            ("Checkpoint", p.checkpoint),
            ("Model", "\(p.family.label) · \(p.style.label)" + (p.speed == .standard ? "" : " · \(p.speed.label)")),
            ("Size", "\(p.width) × \(p.height)"),
            ("Seed", String(seed) + (batchIndex > 0 ? " (picture \(batchIndex + 1) of the batch)" : "")),
            ("Sampler", "\(p.sampler) · \(p.scheduler)"),
            ("Steps", String(p.steps)),
            ("CFG", p.cfg.formatted(.number.precision(.fractionLength(0...2)))),
        ]
        if p.clipSkip > 1 { rows.append(("CLIP skip", String(p.clipSkip))) }
        if let vae = p.vae, !vae.isEmpty { rows.append(("VAE", vae)) }
        for l in sent.loras {
            let w = l.weight.formatted(.number.precision(.fractionLength(0...2)))
            let c = l.clipWeight.formatted(.number.precision(.fractionLength(0...2)))
            rows.append(("LoRA", l.weight == l.clipWeight ? "\(l.name) · \(w)" : "\(l.name) · \(w) / clip \(c)"))
        }
        for m in modifiers { rows.append((m.category.label, m.name)) }
        if faceDetector != nil {
            rows.append(("Face fix", finish.faceStrength.formatted(.number.precision(.fractionLength(0...2)))))
        }
        if handDetector != nil {
            rows.append(("Hand fix", finish.handStrength.formatted(.number.precision(.fractionLength(0...2)))))
        }
        rows.append(("Rating", rating.label))
        if let server { rows.append(("Server", server)) }
        return rows
    }
}

extension GenerationRecipe {
    /// For a picture nothing was generated for (a composition of imported
    /// pictures): no prompt, no model.
    public static func composed(rating: ContentRating) -> GenerationRecipe {
        let input = PromptInput(
            preset: GenerationPreset(name: "Composition", negativePrompt: ""), prompt: "", rating: rating)
        return GenerationRecipe(
            input: input, sent: ComposedPrompt(positive: "", negative: "", loras: []), seed: 0, finish: FinishSettings()
        )
    }
}

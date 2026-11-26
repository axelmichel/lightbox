import Foundation

/// How the model wants its prompt written.
public enum PromptDialect: String, Codable, CaseIterable, Sendable {
    /// Danbooru-style tags (Pony, Illustrious, most anime models).
    case tags
    /// Natural-language sentences (base SDXL, realistic models).
    case natural

    public var label: String {
        switch self {
        case .tags: "Tags"
        case .natural: "Sentences"
        }
    }
}

/// Base model family; decides the prompt conventions and which guide
/// models and LoRAs fit.
public enum ModelFamily: String, Codable, CaseIterable, Sendable {
    case sd15
    case sdxl
    /// SDXL-based; wants `score_9, score_8_up, …` in front of the prompt.
    case pony
    /// Illustrious / NoobAI: SDXL-based anime models with their own ControlNets.
    case illustrious
    /// Flux.1 (dev, schnell, Krea): diffusion model, T5 and CLIP-L text
    /// encoders and VAE as separate files; guidance instead of CFG.
    case flux
    /// Z-Image (Turbo): diffusion model, a Qwen3 text encoder and the Flux
    /// VAE as separate files.
    case zImage = "zimage"
    /// Flux 2 (Klein): diffusion model, a Qwen3 text encoder and its own
    /// VAE; sampled with its own size-dependent schedule.
    case flux2
    /// Anima: an anime model with a diffusion model, the small Qwen3 0.6B
    /// text encoder and the Qwen-Image VAE as separate files.
    case anima
    /// Krea 2: diffusion model, a Qwen3-VL 4B text encoder and the
    /// Qwen-Image VAE as separate files; Turbo samples in 8 steps without CFG.
    case krea2
    /// SD3, HiDream and other models Lightbox has no workflow for yet.
    case unsupported

    public var label: String {
        switch self {
        case .sd15: "SD 1.5"
        case .sdxl: "SDXL"
        case .pony: "Pony"
        case .illustrious: "Illustrious / NoobAI"
        case .flux: "Flux"
        case .zImage: "Z-Image"
        case .flux2: "Flux 2"
        case .anima: "Anima"
        case .krea2: "Krea 2"
        case .unsupported: "Not supported"
        }
    }

    public var isSupported: Bool { self != .unsupported }

    /// Loaded from a diffusion model, text encoders and a VAE instead of one checkpoint.
    public var isSplit: Bool { [.flux, .zImage, .flux2, .anima, .krea2].contains(self) }

    /// ControlNets and IP-Adapters exist for it in Lightbox.
    public var supportsGuides: Bool { isSupported && !isSplit }

    /// How many text encoder files it needs.
    public var textEncoderCount: Int {
        switch self {
        case .flux: 2
        case .zImage, .flux2, .anima, .krea2: 1
        default: 0
        }
    }
}

/// What a checkpoint is good at.
public enum PictureStyle: String, Codable, CaseIterable, Sendable {
    case anime
    case photo
    case illustration

    public var label: String {
        switch self {
        case .anime: "Anime / Comic"
        case .photo: "Photo"
        case .illustration: "Illustration / Art"
        }
    }
}

/// Distilled models and LoRAs that need few steps and a low CFG.
public enum SpeedVariant: String, Codable, CaseIterable, Sendable {
    case standard
    case lightning
    case turbo
    case hyper
    case lcm

    public var label: String {
        switch self {
        case .standard: "Standard"
        case .lightning: "Lightning"
        case .turbo: "Turbo"
        case .hyper: "Hyper"
        case .lcm: "LCM"
        }
    }
}

/// Model and sampling settings, named and reusable.
public struct GenerationPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var family: ModelFamily
    public var style: PictureStyle
    public var speed: SpeedVariant
    /// Checkpoint file name on the server; for Flux and Z-Image the
    /// diffusion model's.
    public var checkpoint: String
    /// VAE file name; `nil` uses the checkpoint's own VAE. Flux and Z-Image need one.
    public var vae: String?
    /// Flux and Z-Image: the text encoder files (Flux: T5, then CLIP-L).
    public var textEncoders: [String]
    /// Flux: how closely it follows the prompt (FluxGuidance); CFG stays at 1.
    public var guidance: Double
    /// Z-Image: the sampling shift (ModelSamplingAuraFlow).
    public var shift: Double
    public var sampler: String
    public var scheduler: String
    public var steps: Int
    public var cfg: Double
    public var width: Int
    public var height: Int
    /// 1 = off; 2 is usual for Pony and anime models.
    public var clipSkip: Int
    public var dialect: PromptDialect
    /// Quality and style terms put in front of every prompt.
    public var stylePrompt: String
    public var negativePrompt: String
    /// Extra instruction for the prompt helper (Ollama), e.g. "always outdoors".
    public var enhanceHint: String
    /// LoRAs always applied with this preset.
    public var loras: [LoraSlot]
    /// Made by `PresetDetector`; reasons it gave, shown in the editor.
    public var detectionNotes: [String]
    /// An example picture, shown when choosing a preset (`PreviewStore`).
    public var picture: UUID?

    public init(
        id: UUID = UUID(), name: String, family: ModelFamily = .sdxl, style: PictureStyle = .illustration,
        speed: SpeedVariant = .standard, checkpoint: String = "", vae: String? = nil, sampler: String = "dpmpp_2m",
        scheduler: String = "karras", steps: Int = 25, cfg: Double = 6, width: Int = 1024, height: Int = 1024,
        clipSkip: Int = 1, dialect: PromptDialect = .natural, stylePrompt: String = "",
        negativePrompt: String = "lowres, worst quality, bad anatomy, bad hands, text, watermark, signature",
        enhanceHint: String = "", loras: [LoraSlot] = [], detectionNotes: [String] = [], textEncoders: [String] = [],
        guidance: Double = 3.5, shift: Double = 3
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.style = style
        self.speed = speed
        self.checkpoint = checkpoint
        self.vae = vae
        self.textEncoders = textEncoders
        self.guidance = guidance
        self.shift = shift
        self.sampler = sampler
        self.scheduler = scheduler
        self.steps = steps
        self.cfg = cfg
        self.width = width
        self.height = height
        self.clipSkip = clipSkip
        self.dialect = dialect
        self.stylePrompt = stylePrompt
        self.negativePrompt = negativePrompt
        self.enhanceHint = enhanceHint
        self.loras = loras
        self.detectionNotes = detectionNotes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, family, style, speed, checkpoint, vae, sampler, scheduler, steps, cfg, width, height
        case clipSkip, dialect, stylePrompt, negativePrompt, enhanceHint, loras, detectionNotes
        case textEncoders, guidance, shift, picture
    }

    /// Fields added later fall back to their defaults, so older presets load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GenerationPreset(name: "")
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        id = try value(.id, UUID())
        name = try value(.name, d.name)
        family = try value(.family, d.family)
        style = try value(.style, d.style)
        speed = try value(.speed, d.speed)
        checkpoint = try value(.checkpoint, d.checkpoint)
        vae = try c.decodeIfPresent(String.self, forKey: .vae)
        textEncoders = try value(.textEncoders, [])
        guidance = try value(.guidance, d.guidance)
        shift = try value(.shift, d.shift)
        sampler = try value(.sampler, d.sampler)
        scheduler = try value(.scheduler, d.scheduler)
        steps = try value(.steps, d.steps)
        cfg = try value(.cfg, d.cfg)
        width = try value(.width, d.width)
        height = try value(.height, d.height)
        clipSkip = try value(.clipSkip, d.clipSkip)
        dialect = try value(.dialect, d.dialect)
        stylePrompt = try value(.stylePrompt, d.stylePrompt)
        negativePrompt = try value(.negativePrompt, d.negativePrompt)
        enhanceHint = try value(.enhanceHint, "")
        loras = try value(.loras, [])
        detectionNotes = try value(.detectionNotes, [])
        picture = try c.decodeIfPresent(UUID.self, forKey: .picture)
    }
}

/// A LoRA with its sliders, as stacked in a preset or for one generation.
public struct LoraSlot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    /// File name on the server.
    public var name: String
    /// Effect on the image model. Negative values work for "slider" LoRAs.
    public var strength: Double
    /// Effect on the text encoder; `nil` = same as `strength`.
    public var clipStrength: Double?
    /// Trigger words, added to the prompt while the LoRA is on.
    public var triggers: String

    public init(
        id: UUID = UUID(), enabled: Bool = true, name: String = "", strength: Double = 0.8,
        clipStrength: Double? = nil, triggers: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.strength = strength
        self.clipStrength = clipStrength
        self.triggers = triggers
    }

    public var isActive: Bool { enabled && !name.isEmpty }
}

/// The second pass that redraws small faces and hands.
public struct FinishSettings: Codable, Hashable, Sendable {
    public var fixFaces: Bool
    /// How much of a face is redrawn: 0.3 keeps it, 0.6 reinvents it.
    public var faceStrength: Double
    public var fixHands: Bool
    public var handStrength: Double

    public init(fixFaces: Bool = false, faceStrength: Double = 0.4, fixHands: Bool = false, handStrength: Double = 0.35)
    {
        self.fixFaces = fixFaces
        self.faceStrength = faceStrength
        self.fixHands = fixHands
        self.handStrength = handStrength
    }
}

/// Presets and generation settings, stored as one JSON file.
public struct Library: Codable, Hashable, Sendable {
    public var presets: [GenerationPreset]
    public var rating: ContentRating
    public var finish: FinishSettings
    /// LoRAs switched on for the next generations, on top of the preset's.
    public var extraLoras: [LoraSlot]
    /// Checkpoints already offered a preset, so a preset deleted on purpose
    /// isn't made again.
    public var knownCheckpoints: Set<String>
    /// Camera, light, film and comic styles: the built-ins and the user's own.
    public var modifiers: [StyleModifier]
    /// What is known about each LoRA, by file name.
    public var loraNotes: [String: LoraNote]

    public init(
        presets: [GenerationPreset] = [], rating: ContentRating = .allAges, finish: FinishSettings = FinishSettings(),
        extraLoras: [LoraSlot] = [], knownCheckpoints: Set<String> = [],
        modifiers: [StyleModifier] = StyleModifier.builtIns, loraNotes: [String: LoraNote] = [:]
    ) {
        self.presets = presets
        self.rating = rating
        self.finish = finish
        self.extraLoras = extraLoras
        self.knownCheckpoints = knownCheckpoints
        self.modifiers = modifiers
        self.loraNotes = loraNotes
    }

    public func modifier(_ id: UUID?) -> StyleModifier? {
        modifiers.first { $0.id == id }
    }

    /// Checkpoints on the server that have no preset and weren't offered
    /// one before, in the server's order.
    public func newCheckpoints(_ onServer: [String]) -> [String] {
        let used = Set(presets.map(\.checkpoint))
        return onServer.filter { !used.contains($0) && !knownCheckpoints.contains($0) }
    }

    enum CodingKeys: String, CodingKey {
        case presets, rating, finish, extraLoras, knownCheckpoints, modifiers, loraNotes
    }

    /// Fields added later fall back to their defaults, so an older file
    /// still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Library()
        presets = try c.decodeIfPresent([GenerationPreset].self, forKey: .presets) ?? defaults.presets
        rating = try c.decodeIfPresent(ContentRating.self, forKey: .rating) ?? defaults.rating
        finish = try c.decodeIfPresent(FinishSettings.self, forKey: .finish) ?? defaults.finish
        extraLoras = try c.decodeIfPresent([LoraSlot].self, forKey: .extraLoras) ?? []
        knownCheckpoints = try c.decodeIfPresent(Set<String>.self, forKey: .knownCheckpoints) ?? []
        modifiers = StyleModifier.withBuiltIns(try c.decodeIfPresent([StyleModifier].self, forKey: .modifiers) ?? [])
        loraNotes = try c.decodeIfPresent([String: LoraNote].self, forKey: .loraNotes) ?? [:]
    }
}

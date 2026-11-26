// Preset detection: given a checkpoint, guess its family (SD 1.5, SDXL,
// Pony, Illustrious, or an unsupported split model), what it draws best
// (anime, photo, illustration) and whether it is a few-step model, then
// suggest the settings such models are usually run with.
//
// Evidence, strongest first:
// - the file's header metadata (`GET /view_metadata`): the architecture,
//   the base model it was trained from, and its training tags;
// - the file name, matched against the names of well-known models;
// - speed LoRAs in use (Hyper, Lightning, LCM), which change steps and CFG.
//
// Everything is a guess; the notes say what each one was based on, and every
// value stays editable.

import Foundation

public struct Detection: Equatable, Sendable {
    public var family: ModelFamily
    public var style: PictureStyle
    public var speed: SpeedVariant
    /// Step count named in a file name ("8steps").
    public var namedSteps: Int?
    /// The speed model keeps CFG working (Hyper "-CFG" LoRAs).
    public var keepsCFG = false
    /// What each guess was based on.
    public var notes: [String]

    public var dialect: PromptDialect {
        switch (family, style) {
        // Flux and Z-Image read sentences with their T5 / Qwen encoders.
        // Anima reads tags and sentences alike with its Qwen3 encoder.
        case (.flux, _), (.zImage, _), (.flux2, _), (.anima, _), (.krea2, _): .natural
        case (.illustrious, _), (.pony, _), (_, .anime): .tags
        default: .natural
        }
    }

    /// A new preset for `checkpoint` with the suggested settings.
    public func preset(checkpoint: String, name: String? = nil) -> GenerationPreset {
        var p = GenerationPreset(name: name ?? PresetDetector.displayName(checkpoint), checkpoint: checkpoint)
        apply(to: &p)
        return p
    }

    /// Replace a preset's sampling, size and prompt defaults with the
    /// suggested ones. Name, checkpoint, VAE and LoRAs stay.
    public func apply(to p: inout GenerationPreset) {
        p.family = family
        p.style = style
        p.speed = speed
        p.dialect = dialect
        p.detectionNotes = notes

        let format: AspectRatio = style == .illustration ? .square : .r2x3
        (p.width, p.height) = format.size(for: family)

        if family.isSplit {
            applySplit(to: &p)
            return
        }

        switch (family, style) {
        case (.pony, _):
            (p.sampler, p.scheduler, p.steps, p.cfg, p.clipSkip) = ("euler_ancestral", "normal", 25, 7, 2)
            let source: String =
                switch style {
                case .anime: "source_anime"
                case .photo: "source_photo, photorealistic"
                case .illustration: "source_cartoon"
                }
            p.stylePrompt = "score_9, score_8_up, score_7_up, \(source)"
            p.negativePrompt = "score_4, score_5, score_6, lowres, bad anatomy, bad hands, text, watermark, signature"
        case (.illustrious, _), (.sdxl, .anime):
            (p.sampler, p.scheduler, p.steps, p.cfg, p.clipSkip) = ("euler_ancestral", "normal", 28, 5.5, 2)
            p.stylePrompt = "masterpiece, best quality, very aesthetic, absurdres"
            p.negativePrompt =
                "lowres, worst quality, low quality, bad anatomy, bad hands, extra digits, jpeg artifacts, "
                + "signature, watermark, text, username"
        case (.sdxl, .photo):
            (p.sampler, p.scheduler, p.steps, p.cfg, p.clipSkip) = ("dpmpp_2m_sde", "karras", 30, 4.5, 1)
            p.stylePrompt = "photograph, sharp focus, natural lighting, highly detailed"
            p.negativePrompt =
                "cartoon, anime, illustration, painting, drawing, cgi, render, lowres, blurry, deformed, "
                + "bad anatomy, bad hands, text, watermark"
        case (.sdxl, .illustration), (.unsupported, _), (.flux, _), (.zImage, _), (.flux2, _), (.anima, _),
            (.krea2, _):
            (p.sampler, p.scheduler, p.steps, p.cfg, p.clipSkip) = ("dpmpp_2m", "karras", 30, 6, 1)
            p.stylePrompt = "detailed digital illustration, vibrant colors"
            p.negativePrompt = "lowres, worst quality, blurry, bad anatomy, bad hands, text, watermark, signature"
        case (.sd15, .anime):
            (p.sampler, p.scheduler, p.steps, p.cfg, p.clipSkip) = ("dpmpp_2m", "karras", 25, 7, 2)
            p.stylePrompt = "masterpiece, best quality"
            p.negativePrompt = "(worst quality, low quality:1.4), bad anatomy, bad hands, text, watermark"
        case (.sd15, .photo):
            (p.sampler, p.scheduler, p.steps, p.cfg, p.clipSkip) = ("dpmpp_2m_sde", "karras", 30, 5, 1)
            p.stylePrompt = "RAW photo, sharp focus, natural lighting, film grain"
            p.negativePrompt =
                "cartoon, anime, painting, (worst quality, low quality:1.3), deformed, bad anatomy, bad hands"
        case (.sd15, .illustration):
            (p.sampler, p.scheduler, p.steps, p.cfg, p.clipSkip) = ("dpmpp_2m", "karras", 25, 7, 1)
            p.stylePrompt = "detailed illustration, vibrant colors"
            p.negativePrompt = "(worst quality, low quality:1.3), blurry, bad anatomy, bad hands, text, watermark"
        }

        switch speed {
        case .standard:
            break
        case .lightning:
            (p.sampler, p.scheduler, p.steps, p.cfg) = ("euler", "sgm_uniform", namedSteps ?? 6, 1.5)
        case .turbo:
            (p.sampler, p.scheduler, p.steps, p.cfg) = ("dpmpp_sde", "karras", namedSteps ?? 6, 2)
        case .hyper:
            (p.sampler, p.scheduler, p.steps) = ("euler", "sgm_uniform", namedSteps ?? 8)
            p.cfg = keepsCFG ? min(p.cfg, 5) : 1
        case .lcm:
            (p.sampler, p.scheduler, p.steps, p.cfg) = ("lcm", "sgm_uniform", namedSteps ?? 6, 1.5)
        }
    }
}

extension Detection {
    /// Flux and Z-Image: few or no quality terms, CFG 1, their own sampling.
    /// The text encoders and VAE are picked from the server's files
    /// (`SplitParts`).
    func applySplit(to p: inout GenerationPreset) {
        p.clipSkip = 1
        p.stylePrompt = ""
        (p.sampler, p.scheduler) = ("euler", "simple")
        let fast = speed != .standard
        switch family {
        case .flux:
            // Schnell is distilled to a few steps; dev and Krea want 20–30.
            (p.steps, p.cfg) = (namedSteps ?? (fast ? 4 : 24), 1)
            p.negativePrompt = ""
            p.guidance = notes.contains { $0.localizedCaseInsensitiveContains("krea") } ? 4.5 : 3.5
        case .flux2:
            // Klein is distilled to 4 steps without CFG; the base model
            // ("base" in the name) wants steps and CFG.
            let base = notes.contains { $0.localizedCaseInsensitiveContains("base model") }
            (p.steps, p.cfg) = base ? (28, 4) : (namedSteps ?? 4, 1)
            p.negativePrompt = ""
        case .krea2:
            // Turbo: 8 steps without CFG, the negative zeroed out, as its
            // workflows have it. The full model is a starting point only.
            (p.steps, p.cfg) = fast ? (namedSteps ?? 8, 1) : (28, 4)
            p.negativePrompt = fast ? "" : "lowres, blurry, bad anatomy, bad hands, text, watermark"
        case .anima:
            // As Anima's workflows have it: plain KSampler, CFG 4, quality
            // and score tags on both sides.
            (p.steps, p.cfg) = (namedSteps ?? 30, 4)
            p.stylePrompt = "masterpiece, best quality"
            p.negativePrompt = "worst quality, low quality, score_1, score_2, score_3, blurry, jpeg artifacts"
        default:
            // Z-Image Turbo: 8–9 steps without CFG; the base model wants CFG.
            (p.steps, p.cfg) = fast ? (namedSteps ?? 9, 1) : (28, 4)
            p.shift = 3
            p.negativePrompt = fast ? "" : "lowres, blurry, bad anatomy, bad hands, text, watermark"
        }
    }
}

public enum PresetDetector {
    /// Guess what `checkpoint` is. `metadata` is the file's header from
    /// `/view_metadata` (if the server has it); `loras` are the LoRAs that
    /// will be used with it.
    /// `diffusionModel`: the file is a bare diffusion model (ComfyUI's
    /// `diffusion_models` folder), not a checkpoint; one Lightbox doesn't
    /// know is unsupported rather than SDXL.
    /// `chosen`: the family picked in the preset; a split family is kept
    /// for a diffusion model whose name and header don't say (fine-tunes).
    public static func detect(
        checkpoint: String, metadata: [String: String]? = nil, loras: [String] = [], diffusionModel: Bool = false,
        chosen: ModelFamily? = nil
    ) -> Detection {
        let file = Name(fileName(checkpoint))
        let meta = metadata ?? [:]
        var notes: [String] = []

        // Text about the model inside the file: its title, description,
        // and the model it was trained from.
        let metaText = [
            "modelspec.title", "modelspec.description", "modelspec.tags", "ss_sd_model_name", "ss_output_name",
        ]
        .compactMap { meta[$0] }.joined(separator: " ")
        let about = Name(metaText)
        let tags = trainingTags(meta["ss_tag_frequency"])

        // Family
        let arch = [meta["modelspec.architecture"], meta["ss_base_model_version"]].compactMap { $0 }.first
        var family: ModelFamily?
        func found(_ f: ModelFamily, _ why: String) {
            if family == nil {
                family = f
                notes.append("\(f.label): \(why).")
            }
        }
        if let hit = file.first(Fragments.krea2) {
            found(.krea2, "“\(hit)” in the file name; loaded with its text encoder and VAE as separate files")
        }
        if let hit = file.first(Fragments.anima) {
            found(.anima, "“\(hit)” in the file name; loaded with its text encoder and VAE as separate files")
        }
        if let hit = file.first(Fragments.zImage) {
            found(.zImage, "“\(hit)” in the file name; loaded with its text encoder and VAE as separate files")
        }
        if let hit = file.first(Fragments.flux2) {
            found(.flux2, "“\(hit)” in the file name; loaded with its text encoder and VAE as separate files")
            if file.first(["=base"]) != nil {
                notes.append("Base model: not distilled, so it wants more steps and CFG.")
            }
        }
        if let hit = file.first(Fragments.unsupported) {
            found(.unsupported, "“\(hit)” in the file name; Lightbox has no workflow for these models yet")
        }
        if let hit = file.first(Fragments.flux) {
            found(.flux, "“\(hit)” in the file name; loaded with its text encoders and VAE as separate files")
        }
        if let arch, let f = Self.family(architecture: arch) {
            if f == .unsupported || f.isSplit {
                found(f, "the file says its architecture is “\(arch)”")
            } else if let hit = file.first(Fragments.illustrious) ?? about.first(Fragments.illustrious) {
                found(.illustrious, "“\(hit)” in the name or metadata")
            } else if let hit = file.first(Fragments.pony) ?? about.first(Fragments.pony) {
                found(.pony, "“\(hit)” in the name or metadata")
            } else {
                found(f, "the file says its architecture is “\(arch)”")
            }
        }
        if let hit = file.first(Fragments.illustrious) ?? about.first(Fragments.illustrious) {
            found(.illustrious, "“\(hit)” in the name")
        }
        if let hit = file.first(Fragments.pony) ?? about.first(Fragments.pony) { found(.pony, "“\(hit)” in the name") }
        if let hit = file.xl ?? file.first(Fragments.sdxl) { found(.sdxl, "“\(hit)” in the file name") }
        if let hit = file.first(Fragments.sd15) { found(.sd15, "“\(hit)” in the file name") }
        if diffusionModel, family?.isSplit != true, let chosen, chosen.isSplit {
            family = chosen
            notes = ["\(chosen.label): picked in the preset; the file's name and header don't say."]
        }
        if diffusionModel, family?.isSplit != true {
            family = .unsupported
            notes = [
                "Not supported: a diffusion model whose name doesn't say what it is. If it is a fine-tune of "
                    + "Flux, Flux 2, Z-Image, Anima or Krea 2, pick that family under Model."
            ]
        }
        if family == nil {
            family = .sdxl
            notes.append("SDXL: nothing in the name says otherwise, and most current checkpoints are SDXL.")
        }

        // Style
        let photo = file.first(Fragments.photo) ?? about.first(Fragments.photo)
        let anime = file.first(Fragments.anime) ?? about.first(Fragments.anime)
        let artistic = file.first(Fragments.illustration) ?? about.first(Fragments.illustration)
        let tagStyle = style(ofTrainingTags: tags)
        var style: PictureStyle
        if let photo {
            style = .photo
            notes.append("Photo: “\(photo)” in the name.")
        } else if let anime {
            style = .anime
            notes.append("Anime / Comic: “\(anime)” in the name.")
        } else if let tagStyle {
            style = tagStyle.style
            notes.append("\(style.label): it was trained on pictures tagged like “\(tagStyle.tag)”.")
        } else if family == .zImage {
            style = .photo
            notes.append("Photo: Z-Image is made for photographic pictures first.")
        } else if family == .anima {
            style = .anime
            notes.append("Anime / Comic: Anima is an anime model.")
        } else if family == .illustrious || family == .pony {
            style = .anime
            notes.append("Anime / Comic: \(family!.label) models are mostly anime models.")
        } else if let artistic {
            style = .illustration
            notes.append("Illustration / Art: “\(artistic)” in the name.")
        } else {
            style = .illustration
            notes.append("Illustration / Art: the name doesn't say; this is the all-round setting.")
        }
        if style == .photo, family == .illustrious {
            // There are no realistic Illustrious models to speak of; a "real"
            // in the name is usually "semi-real", which still wants tags.
            notes.append("Prompts are written as tags anyway, as Illustrious models expect.")
        }

        // Speed
        var detection = Detection(family: family!, style: style, speed: .standard, notes: notes)
        let speedSources = [checkpoint] + loras
        for source in speedSources {
            let name = Name(fileName(source))
            guard let (variant, hit) = speedVariant(name) else { continue }
            detection.speed = variant
            detection.namedSteps = name.steps
            detection.keepsCFG = variant == .hyper && name.tokens.contains("cfg")
            let what = source == checkpoint ? "the file name" : "the LoRA “\(fileName(source))”"
            var note = "\(variant.label): “\(hit)” in \(what)"
            if let steps = name.steps { note += ", made for \(steps) steps" }
            detection.notes.append(note + ".")
            break
        }
        return detection
    }

    /// "sdxl/Sample_Illustrious_v1.safetensors" → "Sample Illustrious v1".
    public static func displayName(_ checkpoint: String) -> String {
        let base = fileName(checkpoint)
        let stem = (base as NSString).deletingPathExtension
        return stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    static func family(architecture: String) -> ModelFamily? {
        let a = architecture.lowercased()
        if a.contains("flux-2") || a.contains("flux.2") || a.contains("flux2") { return .flux2 }
        if a.contains("flux-1") || a.contains("flux.1") || a == "flux" { return .flux }
        if a.contains("z-image") || a.contains("zimage") || a.contains("lumina2") { return .zImage }
        if ["flux", "stable-diffusion-v3", "sd3", "auraflow", "hunyuan", "pixart", "kolors", "hidream", "chroma"]
            .contains(where: a.contains)
        {
            return .unsupported
        }
        if a.contains("xl") { return .sdxl }
        if a.contains("v1") || a.contains("sd_v1") || a.contains("1-5") || a.contains("1.5") { return .sd15 }
        return nil
    }

    static func speedVariant(_ name: Name) -> (SpeedVariant, String)? {
        if let hit = name.first(["lightning"]) { return (.lightning, hit) }
        // A whole token: "Hyper-SDXL", "HyperXL", but not "hyperrealism".
        if let hit = name.first(["=hyper", "hypersd"]) { return (.hyper, hit) }
        if let hit = name.first(["turbo", "schnell"]) { return (.turbo, hit) }
        if let hit = name.first(["lcm", "dmd2"]) { return (.lcm, hit) }
        return nil
    }

    /// Tags from kohya's `ss_tag_frequency` (`{"dataset": {"tag": count}}`),
    /// most frequent first.
    static func trainingTags(_ json: String?) -> [String] {
        guard let json, let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return [] }
        var counts: [String: Int] = [:]
        for case let set as [String: Any] in obj.values {
            for (tag, n) in set {
                let t = tag.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: " ")
                counts[t, default: 0] += (n as? Int) ?? 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Danbooru tags among the top training tags mean an anime model;
    /// photography terms a photo model.
    static func style(ofTrainingTags tags: [String]) -> (style: PictureStyle, tag: String)? {
        let top = tags.prefix(40)
        if let t = top.first(where: Fragments.photoTags.contains) { return (.photo, t) }
        if let t = top.first(where: Fragments.booruTags.contains) { return (.anime, t) }
        return nil
    }
}

/// A model name split for matching: tokens ("realvisxl", "v", "40") and a
/// key without separators ("realvisxlv40").
struct Name {
    let tokens: [String]
    let key: String

    init(_ text: String) {
        var tokens: [String] = []
        var current = ""
        var last: Character?
        for c in text {
            let boundary: Bool =
                if let last {
                    !(c.isLetter || c.isNumber) || (last.isLowercase && c.isUppercase)
                        || (last.isLetter && c.isNumber) || (last.isNumber && c.isLetter)
                } else { false }
            if boundary, !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
            if c.isLetter || c.isNumber { current.append(c) }
            last = c
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        self.tokens = tokens
        key = tokens.joined()
    }

    /// The first fragment found. Fragments of up to three letters, and those
    /// starting with "=", must be a whole token ("xl", "=real"); longer ones
    /// may be part of a word ("realvis" in "realvisxl").
    func first(_ fragments: [String]) -> String? {
        for f in fragments {
            let k = f.lowercased().filter { $0.isLetter || $0.isNumber }
            let whole = f.hasPrefix("=") || k.count <= 3
            if whole ? tokens.contains(k) : key.contains(k) { return f.hasPrefix("=") ? String(f.dropFirst()) : f }
        }
        return nil
    }

    /// "XL" as a token or at the end of one ("dreamshaperXL", "realvisxl").
    var xl: String? {
        tokens.first { $0 == "xl" || ($0.count > 3 && $0.hasSuffix("xl")) || $0 == "sdxl" }.map { _ in "XL" }
    }

    /// "8steps", "4step", "8-step" → 8.
    var steps: Int? {
        for (i, t) in tokens.enumerated() where t == "step" || t == "steps" {
            if i > 0, let n = Int(tokens[i - 1]), (1...50).contains(n) { return n }
        }
        return nil
    }
}

enum Fragments {
    static let unsupported = [
        "sd3", "sd35", "auraflow", "hunyuan", "pixart", "kolors", "hidream", "qwen", "cascade",
    ]
    static let flux = ["flux"]
    static let flux2 = ["flux2", "klein"]
    static let zImage = ["zimage"]
    /// A whole word: "animagine" is SDXL.
    static let anima = ["=anima"]
    /// Not "flux1-krea", which is Flux.
    static let krea2 = ["krea2"]
    static let illustrious = ["illustrious", "noobai", "noob", "ilxl", "ill"]
    static let pony = ["pony", "pdxl", "autismmix"]
    static let sdxl = [
        "juggernaut", "realvis", "zavychroma", "copax", "animagine", "albedobase", "proteus", "playground",
        "leosam", "halcyon", "nightvision", "crystalclear", "dynavision", "starlight", "wildcard",
    ]
    static let sd15 = [
        "sd15", "sd 1.5", "realisticvision", "dreamshaper8", "anythingv", "counterfeit", "meinamix",
        "deliberate", "revanimated", "abyssorangemix", "absolutereality", "majicmix", "chilloutmix", "epicrealism",
        "cyberrealistic", "photon", "ghostmix", "aom3",
    ]
    static let photo = [
        "photo", "realistic", "realism", "=real", "realvis", "juggernaut", "photon", "raw", "analog", "lifelike",
        "absolutereality", "majicmix", "chilloutmix", "leosam", "halcyon", "nightvision", "dslr", "cinematic",
        "krea",
    ]
    static let anime = [
        "anime", "manga", "comic", "cartoon", "toon", "waifu", "animagine", "anything", "counterfeit", "meina",
        "abyssorange", "hassaku", "kohaku", "niji", "2d", "aam", "bluepencil", "cetus", "ghostmix", "aniverse",
        "aom3", "chibi", "cel",
    ]
    static let illustration = [
        "dreamshaper", "=art", "paint", "fantasy", "protovision", "artium", "deliberate", "revanimated", "3d",
        "render", "=base",
    ]
    static let booruTags: Set<String> = [
        "1girl", "1boy", "2girls", "solo", "looking at viewer", "highres", "absurdres", "simple background",
        "white background", "multiple girls", "blush", "smile", "open mouth", "long hair", "short hair",
    ]
    static let photoTags: Set<String> = [
        "photo", "photograph", "photography", "realistic", "photorealistic", "raw photo", "dslr", "film grain",
    ]
}

// LoRA detection: what a LoRA was trained for, its trigger words, and a
// starting strength.
//
// Evidence, from the file's header metadata (`GET /view_metadata/loras`):
// - `modelspec.trigger_phrase`, when the trainer filled it in;
// - kohya's dataset folders, named "<repeats>_<trigger>";
// - kohya's training tags (`ss_tag_frequency`): a tag in (almost) every
//   training picture that isn't a common Danbooru or quality tag is the
//   trigger; made-up words ("toon4on", "s-cartoon") count at lower shares;
// - the base model (`ss_sd_model_name`, `ss_base_model_version`,
//   `modelspec.architecture`), then the file name and folder.
// Strength is rarely stored; it comes from the kind (detail, style, slider,
// speed) unless the description names a weight.

import Foundation

public struct LoraInfo: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case speed, slider, detail, style, other

        public var label: String {
            switch self {
            case .speed: "speed"
            case .slider: "slider"
            case .detail: "detail"
            case .style: "style"
            case .other: "LoRA"
            }
        }
    }

    /// `nil` = unknown.
    public var family: ModelFamily?
    public var kind: Kind
    /// Trigger words to fill in, most likely first.
    public var triggers: [String]
    /// Other telling training tags (character features, style variants),
    /// offered to add.
    public var suggestions: [String]
    public var strength: Double
    /// What each guess was based on.
    public var notes: [String]
    /// About the LoRA: what its file says, or the published settings of a
    /// well-known one. For the LoRA info page.
    public var about: [String] = []
    /// A prompt that shows it off.
    public var samplePrompt = ""
    /// Where it is described, for well-known LoRAs.
    public var link = ""
    /// Hash of its weights (`sshs_model_hash`), which Civitai can look up.
    public var modelHash: String?

    /// How the LoRA fits a preset of `family`: `nil` = fine or unknown.
    public func mismatch(with family: ModelFamily) -> String? {
        guard let own = self.family, own != family, family.isSupported else { return nil }
        if !own.isSupported { return "Made for a model family Lightbox can't load (SD3 or similar)." }
        if own.isSplit || family.isSplit { return "Made for \(own.label); it won't work with \(family.label) models." }
        if (own == .sd15) != (family == .sd15) {
            return "Made for \(own.label); it won't work with \(family.label) models."
        }
        if own == .sdxl || family == .sdxl {
            return "Made for \(own.label); with \(family.label) it may work less well."
        }
        return
            "Made for \(own.label); \(own.label) and \(family.label) LoRAs often, but not always, work on each other."
    }
}

/// What is known about one LoRA file, shown on the LoRA info page. Filled
/// in from `LoraInfo` the first time the LoRA is looked at; afterwards the
/// user's edits win, and picking the LoRA uses these triggers and strength.
public struct LoraNote: Codable, Hashable, Sendable {
    /// File name on the server.
    public var name: String
    /// Trigger words, comma-separated.
    public var triggers: String
    public var strength: Double
    /// Prompt strength; `nil` = same as `strength`.
    public var clipStrength: Double?
    /// The model family it was made for; `nil` = unknown.
    public var family: ModelFamily?
    /// Free text: what it does, what works well with it.
    public var notes: String
    /// Where it came from, e.g. its Civitai page.
    public var link: String
    /// A prompt that shows it off.
    public var samplePrompt: String
    /// Changed by the user since it was filled in.
    public var edited: Bool
    /// Its picture, kept with the style previews (`Previews/<id>.jpg`).
    public var picture: UUID?

    public init(
        name: String, triggers: String = "", strength: Double = 1, clipStrength: Double? = nil,
        family: ModelFamily? = nil, notes: String = "", link: String = "", samplePrompt: String = "",
        edited: Bool = false
    ) {
        self.name = name
        self.triggers = triggers
        self.strength = strength
        self.clipStrength = clipStrength
        self.family = family
        self.notes = notes
        self.link = link
        self.samplePrompt = samplePrompt
        self.edited = edited
    }

    /// A note filled in from what the detector found.
    public init(detected info: LoraInfo, name: String) {
        self.init(
            name: name, triggers: info.triggers.joined(separator: ", "), strength: info.strength, family: info.family,
            notes: info.about.joined(separator: "\n"), link: info.link, samplePrompt: info.samplePrompt)
    }

    enum CodingKeys: String, CodingKey {
        case name, triggers, strength, clipStrength, family, notes, link, samplePrompt, edited, picture
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        triggers = try c.decodeIfPresent(String.self, forKey: .triggers) ?? ""
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        clipStrength = try c.decodeIfPresent(Double.self, forKey: .clipStrength)
        family = try c.decodeIfPresent(ModelFamily.self, forKey: .family)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        samplePrompt = try c.decodeIfPresent(String.self, forKey: .samplePrompt) ?? ""
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        picture = try c.decodeIfPresent(UUID.self, forKey: .picture)
    }
}

public enum LoraDetector {
    public static func detect(name: String, metadata: [String: String]? = nil) -> LoraInfo {
        let meta = metadata ?? [:]
        let file = Name(PresetDetector.fileName(name))
        let path = Name(name)
        var notes: [String] = []

        // Family: the model it was trained on, then its name.
        var family: ModelFamily?
        func found(_ f: ModelFamily, _ why: String) {
            guard family == nil else { return }
            family = f
            notes.append("\(f.label): \(why).")
        }
        let base = meta["ss_sd_model_name"].map(Name.init)
        if let base, let hit = base.first(Fragments.illustrious + ["illustxl"]) {
            found(.illustrious, "trained on “\(meta["ss_sd_model_name"]!)” (“\(hit)”)")
        } else if let base, let hit = base.first(Fragments.pony) {
            found(.pony, "trained on “\(meta["ss_sd_model_name"]!)” (“\(hit)”)")
        }
        let arch = [meta["ss_base_model_version"], meta["modelspec.architecture"]].compactMap { $0 }
            .first { PresetDetector.family(architecture: $0) != nil }
        let archFamily = arch.flatMap(PresetDetector.family(architecture:))
        if archFamily == .sd15 || archFamily == .unsupported || archFamily?.isSplit == true {
            found(archFamily!, "the file says it was trained for “\(arch!)”")
        }
        if let hit = path.first(Fragments.illustrious + ["illustxl"]) {
            found(.illustrious, "“\(hit)” in the name or folder")
        } else if let hit = path.first(Fragments.pony) {
            found(.pony, "“\(hit)” in the name or folder")
        }
        if let archFamily { found(archFamily, "the file says it was trained for “\(arch!)”") }
        if let hit = file.xl ?? file.first(["sdxl"]) { found(.sdxl, "“\(hit)” in the file name") }
        if let hit = file.first(["sd15"]) { found(.sd15, "“\(hit)” in the file name") }

        // Kind
        var kind = LoraInfo.Kind.other
        if let (variant, hit) = PresetDetector.speedVariant(file) {
            kind = .speed
            notes.append("\(variant.label) speed LoRA (“\(hit)”): the preset's steps and CFG should match it.")
        } else if file.tokens.contains("slider") {
            kind = .slider
            notes.append("Slider: negative strengths turn it the other way.")
        } else if file.first(["=detail", "=details", "enhancer", "tweaker", "adddetail"]) != nil {
            kind = .detail
        } else if file.first(Fragments.loraStyle) != nil {
            kind = .style
        }

        // Strength
        var strength =
            switch kind {
            case .detail: 0.6
            case .style: 0.8
            case .speed, .slider, .other: 1.0
            }
        let about = ["modelspec.usage_hint", "modelspec.description", "ss_training_comment"].compactMap { meta[$0] }
        if let named = about.lazy.compactMap(recommendedWeight).first {
            strength = named
            notes.append("Strength \(named.formatted()): named in the file's description.")
        }

        // Triggers
        var triggers: [String] = []
        var suggestions: [String] = []
        func addTrigger(_ t: String, _ why: String) {
            let t = t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !triggers.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else {
                return
            }
            triggers.append(t)
            notes.append("Trigger “\(t)”: \(why).")
        }
        if let phrase = meta["modelspec.trigger_phrase"] {
            for t in phrase.split(separator: ",") { addTrigger(String(t), "named in the file") }
        }
        let counts = tagCounts(meta["ss_tag_frequency"])
        let pictures = max(imageCount(meta["ss_dataset_dirs"]), counts.values.max() ?? 0)
        for folder in datasetTriggers(meta["ss_dataset_dirs"]) {
            // The tag spelling if the folder name is also a tag.
            let key = Name(folder).key
            let tag = counts.keys.first { Name($0).key == key }
            addTrigger(tag ?? folder.lowercased(), "the training folder is named “\(folder)”")
        }
        if pictures > 0 {
            let ranked = counts.filter { !isCommonTag($0.key) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            for (tag, count) in ranked {
                let share = Double(count) / Double(pictures)
                let madeUp =
                    tag.contains(where: \.isNumber) || tag.contains("-") || (!tag.contains(" ") && tag.count >= 12)
                if share >= 0.95 || (madeUp && share >= 0.25) {
                    if triggers.isEmpty {
                        addTrigger(tag, "in \(Int(share * 100))% of the training pictures")
                    } else if !triggers.contains(tag) {
                        suggestions.append(tag)
                    }
                } else if share >= 0.3, suggestions.count < 8 {
                    suggestions.append(tag)
                }
            }
        }
        if triggers.isEmpty, kind != .speed, kind != .slider {
            notes.append(
                counts.isEmpty
                    ? "No trigger words: the file has no training tags."
                    : "No trigger words stand out in its training tags."
            )
        }
        var page = summary(metadata: meta, name: name, counts: counts)
        var link = ""
        if let known = KnownLora.match(name) {
            page = known.notes + page
            link = known.link
            strength = known.strength
            notes.append("\(known.title): settings published by its makers.")
        } else if let advice = KnownLora.advice(for: kind) {
            page.append(advice)
        }
        return LoraInfo(
            family: family, kind: kind, triggers: triggers, suggestions: Array(suggestions.prefix(8)),
            strength: strength, notes: notes, about: page,
            samplePrompt: samplePrompt(triggers: triggers, counts: counts),
            link: link, modelHash: meta["sshs_model_hash"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Tag counts from `ss_tag_frequency` (`{"dataset": {"tag": count}}`).
    static func tagCounts(_ json: String?) -> [String: Int] {
        guard let json, let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return [:] }
        var counts: [String: Int] = [:]
        for case let set as [String: Any] in obj.values {
            for (tag, n) in set {
                let t = tag.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: " ")
                if !t.isEmpty { counts[t, default: 0] += (n as? Int) ?? 1 }
            }
        }
        return counts
    }

    /// Training pictures, from `ss_dataset_dirs` (`{"10_name": {"img_count": 40}}`).
    static func imageCount(_ json: String?) -> Int {
        guard let json, let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return 0 }
        return obj.values.compactMap { ($0 as? [String: Any])?["img_count"] as? Int }.reduce(0, +)
    }

    /// Names of kohya dataset folders ("20_cinematic style" → "cinematic style").
    static func datasetTriggers(_ json: String?) -> [String] {
        guard let json, let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return [] }
        return obj.keys.sorted().compactMap { folder in
            guard let underscore = folder.firstIndex(of: "_"), Int(folder[..<underscore]) != nil else { return nil }
            let name = folder[folder.index(after: underscore)...].trimmingCharacters(in: .whitespaces)
            return name.count >= 3 && !Fragments.datasetFolders.contains(name.lowercased()) ? name : nil
        }
    }

    /// "weight 0.7", "strength: 0.6-0.8" (→ 0.6), "use at 0.8 weight".
    static func recommendedWeight(_ text: String) -> Double? {
        let pattern = /(?i)(?:weight|strength)\D{0,12}?(\d*\.\d+|\d)|(\d*\.\d+)\s*(?:weight|strength)/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        let number = match.output.1 ?? match.output.2
        guard let number, let value = Double(number), (0.05...2).contains(value) else { return nil }
        return value
    }

    /// Danbooru tags for what is in a picture, and quality terms: they
    /// describe the training pictures, not the LoRA.
    static func isCommonTag(_ tag: String) -> Bool {
        if Fragments.commonTags.contains(tag) || Fragments.booruTags.contains(tag) || Fragments.photoTags.contains(tag)
        {
            return true
        }
        if tag.wholeMatch(of: /\d\+?(girl|boy|other)s?/) != nil { return true }
        let suffixes = [
            " hair", " eyes", " background", " breasts", " focus", " lips", " nails", " skin", " shirt", " dress",
            " skirt", " pants", " gloves", " boots", " shoes", " legwear", " thighhighs", " jacket", " hat", " sleeves",
            " shot", " body", " view", " lighting", " text", " name", " username",
        ]
        let prefixes = ["looking ", "holding ", "from ", "open ", "closed ", "parted ", "hair ", "multiple "]
        return suffixes.contains(where: tag.hasSuffix) || prefixes.contains(where: tag.hasPrefix)
    }
}

extension Fragments {
    static let loraStyle = [
        "style", "cartoon", "sketch", "realism", "photo", "cinematic", "painting", "anime", "manga", "comic",
        "midjourney", "realtouch", "watercolor", "lineart", "=art", "aesthetic", "film",
    ]
    static let datasetFolders: Set<String> = ["img", "image", "images", "dataset", "data", "train", "training"]
    static let commonTags: Set<String> = [
        // quality and rating
        "masterpiece", "best quality", "high quality", "good quality", "normal quality", "low quality",
        "worst quality", "amazing quality", "very aesthetic", "aesthetic", "ultra-detailed", "ultra detailed",
        "highly detailed", "finely detailed", "extremely detailed", "detailed", "8k", "4k", "hdr", "uhd", "highres",
        "absurdres", "incredibly absurdres", "lowres", "ultra realistic", "photo-realistic", "hyper realistic",
        "newest", "recent", "sensitive", "general", "safe", "questionable", "explicit", "nsfw", "sfw",
        // people
        "solo", "solo focus", "male focus", "female focus", "multiple girls", "multiple boys", "couple", "yuri", "yaoi",
        "female", "male", "girl", "boy", "woman", "man", "child", "adult", "muscular", "muscular female",
        "muscular male", "abs", "thick thighs", "dark skin", "pale skin", "tan", "tanlines", "freckles", "mole",
        "makeup", "lipstick", "eyeshadow", "eyeliner", "blush", "smile", "grin", "teeth", "tongue", "nose", "ears",
        "lips", "fingernails", "toenails", "nail polish", "toenail polish", "feet", "toes", "soles", "barefoot",
        "ass", "navel", "midriff", "cleavage", "collarbone", "nipples", "nude", "completely nude", "pussy", "penis",
        "underwear", "panties", "bra", "breasts", "small breasts", "medium breasts", "large breasts", "huge breasts",
        "bangs", "ponytail", "twintails", "braid", "sidelocks", "ahoge", "hair ornament",
        // clothes and things
        "jewelry", "earrings", "necklace", "choker", "bracelet", "ring", "glasses", "sunglasses", "hat", "gloves",
        "fingerless gloves", "boots", "knee boots", "high heels", "shoes", "socks", "belt", "shirt", "white shirt",
        "jacket", "coat", "dress", "skirt", "shorts", "pants", "denim", "jeans", "leotard", "white leotard",
        "bodysuit", "swimsuit", "bikini", "uniform", "school uniform", "armor", "shoulder armor", "cape",
        "long sleeves", "short sleeves", "sleeveless", "coattails", "weapon", "sword", "gun", "cup", "phone", "bag",
        "chair", "table", "car", "vehicle", "motor vehicle", "wheel",
        // pose, framing, place
        "standing", "sitting", "lying", "kneeling", "walking", "running", "full body", "upper body", "lower body",
        "cowboy shot", "portrait", "close-up", "from above", "from below", "from side", "from behind", "profile",
        "outdoors", "indoors", "day", "night", "sky", "cloud", "tree", "water", "city", "room", "bed", "window",
        "shadow", "blurry", "depth of field", "bokeh", "multiple views", "reference sheet", "no humans", "still life",
        "monochrome", "greyscale", "sketch", "lineart", "traditional media", "realistic", "photorealistic",
        "signature", "watermark", "dated", "artist name", "english text",
        "speech bubble", "comic", "science fiction", "fantasy", "dirty", "wet", "sweat", "crystal",
    ]
}

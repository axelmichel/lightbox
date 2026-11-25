// Content guard. Pictures may show children; sexualizing them is never
// allowed.
//
// - Child-related words and explicit young ages are a *minor signal*. They
//   block nothing by themselves.
// - Sexual terms come in two levels (suggestive, explicit). Which levels are
//   allowed depends on the project rating, and none are allowed together
//   with a minor signal.
// - Some terms are blocked in every context.
// - With a minor signal, clothing terms in the negative prompt are blocked
//   too (negating clothes is the same as asking for nudity), and safety
//   negatives are forced.
//
// Matching runs on normalized text (lowercase, leetspeak undone, punctuation
// collapsed), so "L0-li", "n.u.d.e" and LoRA file names like
// "nude_style_v2.safetensors" are caught.

import Foundation

public enum ContentRating: String, Codable, CaseIterable, Sendable {
    case allAges
    case teen
    case mature
}

public enum GuardError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Blocked in every context.
    case blocked(term: String)
    /// A sexual term together with a minor signal.
    case sexualWithMinor(term: String, minor: String)
    /// Clothing in the negative prompt together with a minor signal.
    case clothingNegatedWithMinor(term: String, minor: String)
    /// A sexual term the project rating does not allow.
    case notAllowedByRating(term: String, rating: ContentRating)

    public var description: String {
        switch self {
        case .blocked(let term):
            "“\(term)” is not allowed."
        case .sexualWithMinor(let term, let minor):
            "“\(term)” is not allowed in an image with a minor (“\(minor)”)."
        case .clothingNegatedWithMinor(let term, let minor):
            "“\(term)” in the negative prompt is not allowed in an image with a minor (“\(minor)”)."
        case .notAllowedByRating(let term, let rating):
            "“\(term)” is not allowed for the rating \(rating.label)."
        }
    }
}

extension ContentRating {
    public var label: String {
        switch self {
        case .allAges: "All ages"
        case .teen: "Teen"
        case .mature: "Mature"
        }
    }
}

/// Everything one generation is made of, as seen by the guard.
public struct GuardInput: Sendable {
    /// Positive prompt parts: the prompt, the preset's style, trigger words.
    public var positive: [String]
    /// Negative prompt parts typed by the user or stored in presets.
    public var negative: [String]
    /// LoRA file names used in the generation.
    public var loraNames: [String]
    public var rating: ContentRating

    public init(positive: [String], negative: [String] = [], loraNames: [String] = [], rating: ContentRating) {
        self.positive = positive
        self.negative = negative
        self.loraNames = loraNames
        self.rating = rating
    }
}

public struct GuardResult: Equatable, Sendable {
    /// What made the guard treat the image as showing a minor, if anything.
    public var minorSignal: String?
    /// Terms that must be added to the negative prompt.
    public var forcedNegatives: [String]
}

public enum ContentGuard {
    public static let minorNegatives = ["nsfw", "nude", "nudity", "suggestive", "sexualized"]

    public static func check(_ input: GuardInput) throws(GuardError) -> GuardResult {
        // Checked as one text, so terms split across parts still meet.
        let positive = (input.positive + input.loraNames).joined(separator: ", ")
        if let term = alwaysBlocked(in: positive) { throw .blocked(term: term) }

        let minor = minorSignal(in: positive)

        let suggestive = match(positive, Terms.suggestive)
        let explicit = match(positive, Terms.explicit)

        if let minor {
            if let term = explicit ?? suggestive { throw .sexualWithMinor(term: term, minor: minor) }
            if let term = match(input.negative.joined(separator: ", "), Terms.clothing) {
                throw .clothingNegatedWithMinor(term: term, minor: minor)
            }
            return GuardResult(minorSignal: minor, forcedNegatives: minorNegatives)
        }

        switch input.rating {
        case .allAges:
            if let term = explicit ?? suggestive { throw .notAllowedByRating(term: term, rating: .allAges) }
            return GuardResult(minorSignal: nil, forcedNegatives: ["nsfw", "nude", "nudity", "suggestive"])
        case .teen:
            if let term = explicit { throw .notAllowedByRating(term: term, rating: .teen) }
            return GuardResult(minorSignal: nil, forcedNegatives: ["nsfw", "nude", "nudity", "explicit"])
        case .mature:
            return GuardResult(minorSignal: nil, forcedNegatives: [])
        }
    }

    /// The first term that is blocked in every context.
    public static func alwaysBlocked(in text: String) -> String? {
        match(text, Terms.alwaysBlocked)
    }

    /// What in `text` points to a minor: a child-related word or a young age.
    public static func minorSignal(in text: String) -> String? {
        if let age = youngAge(in: text) { return age }
        var norm = " \(normalize(text)) "
        for allowed in Terms.benignPhrases {
            norm = norm.replacingOccurrences(of: " \(allowed) ", with: " ")
        }
        if let term = match(norm: norm, Terms.minor) { return term }
        // German "kind" is also English ("kind of", "a kind smile").
        if looksGerman(norm), norm.split(separator: " ").contains(where: { $0 == "kind" }) {
            return "kind"
        }
        return nil
    }

    // MARK: - Matching

    static func match(_ text: String, _ terms: TermList) -> String? {
        match(norm: normalize(text), terms)
    }

    static func match(norm: String, _ terms: TermList) -> String? {
        let padded = " \(norm) "
        for phrase in terms.phrases where padded.contains(" \(phrase) ") {
            return phrase
        }
        // "l o l i", "n.u.d.e": runs of very short tokens count as one word too.
        for word in norm.split(separator: " ").map(String.init) + shortTokenRuns(norm) {
            if terms.words.contains(word) { return word }
            if let stem = terms.stems.first(where: { word.hasPrefix($0) }) { return stem }
        }
        return nil
    }

    static func shortTokenRuns(_ norm: String) -> [String] {
        var runs: [String] = []
        var current = ""
        var count = 0
        let tokens: [Substring] = norm.split(separator: " ") + [""]
        for token in tokens {
            if !token.isEmpty, token.count <= 2 {
                current += token
                count += 1
            } else {
                if count > 1 { runs.append(current) }
                current = ""
                count = 0
            }
        }
        return runs
    }

    static func looksGerman(_ norm: String) -> Bool {
        let markers: Set<Substring> = ["und", "mit", "der", "die", "das", "ein", "eine", "im", "auf", "einer"]
        let words = norm.split(separator: " ")
        if words.filter({ markers.contains($0) }).count >= 2 { return true }
        // A single German term from the lists is enough ("Kind, nackt").
        return words.contains { Terms.germanWords.contains(String($0)) || $0.contains(where: "äöüß".contains) }
    }

    /// Explicit ages below 18: "8 years old", "8-year-old", "15yo", "age 12",
    /// "12 Jahre alt", "12-jährig".
    static func youngAge(in text: String) -> String? {
        let words = normalizeKeepDigits(text).split(separator: " ").map(String.init)
        func isYoung(_ s: some StringProtocol) -> Bool { Int(s).map { $0 < 18 } ?? false }
        let suffixes: Set<String> = ["yo", "y/o", "yrs", "jährig", "jaehrig", "jährige", "jährigen", "jähriger"]
        let after: Set<String> = ["year", "years", "yr", "yrs", "jahre", "jahren", "jahr"]
        let before: Set<String> = ["age", "aged", "alter"]

        for (i, w) in words.enumerated() {
            let digits = w.prefix(while: { $0.isASCII && $0.isNumber })
            if !digits.isEmpty, isYoung(digits) {
                let rest = String(w.dropFirst(digits.count))
                if suffixes.contains(rest) { return w }
                if i + 1 < words.count, suffixes.contains(words[i + 1]) {
                    return "\(w) \(words[i + 1])"
                }
                // "8 years old", "12 Jahre alt", "9 years of age"; not "2 years later".
                if i + 2 < words.count, after.contains(words[i + 1]), ["old", "alt", "of"].contains(words[i + 2]) {
                    return "\(w) \(words[i + 1]) \(words[i + 2])"
                }
            }
            if before.contains(w), i + 1 < words.count, isYoung(words[i + 1]) {
                return "\(w) \(words[i + 1])"
            }
        }
        return nil
    }
}

struct TermList: Sendable {
    var words: Set<String> = []
    var phrases: [String] = []
    /// Word prefixes: "masturbat" matches "masturbating".
    var stems: [String] = []
}

enum Terms {
    static let alwaysBlocked = TermList(
        words: [
            "loli", "lolis", "lolicon", "lolita", "shota", "shotas", "shotacon", "toddlercon",
            "jailbait", "pedo", "pedos", "pedophile", "pedophilia", "paedo", "paedophile",
            "pädophil", "pädophile", "pädophilie", "cp", "kinderporno", "kinderpornografie",
        ],
        phrases: ["child porn", "child pornography", "underage sex"]
    )

    static let minor = TermList(
        words: [
            // English
            "child", "children", "childs", "kid", "kids", "kiddo", "toddler", "toddlers", "infant",
            "infants", "baby", "babies", "newborn", "underage", "preteen", "preteens", "prepubescent",
            "pubescent", "minor", "minors", "juvenile", "schoolchild", "schoolkid", "schoolgirl",
            "schoolgirls", "schoolboy", "schoolboys", "kindergarten", "kindergartner", "teen",
            "teens", "teenage", "teenager", "teenagers", "tween", "tweens", "childlike",
            // German
            "kinder", "kindes", "kleinkind", "kleinkinder", "säugling", "minderjährig",
            "minderjährige", "minderjährigen", "minderjähriger", "schulkind", "schulkinder",
            "schüler", "schülerin", "schülerinnen", "jugendlich", "jugendliche", "jugendlichen",
            "teenie", "teenies", "grundschule", "grundschüler",
        ],
        phrases: [
            "young girl", "young boy", "little girl", "little boy", "elementary school",
            "middle school", "junior high", "high school", "grade school", "school girl",
            "school boy", "school uniform", "under 18", "under eighteen", "not yet 18",
            "younger self", "kleines mädchen", "kleiner junge", "unter 18",
        ]
    )

    /// German words from the sexual term lists; their presence makes "kind"
    /// read as German.
    static let germanWords: Set<String> = [
        "nackt", "nackte", "nackten", "nackter", "nacktheit", "sexuell", "sexuelle", "erotisch",
        "erotische", "verführerisch", "aufreizend", "dessous", "unterwäsche", "reizwäsche",
    ]

    /// Phrases that contain a minor word but are not about children.
    static let benignPhrases = [
        "baby blue", "baby pink", "baby face cream", "kid gloves", "minor detail",
        "minor details", "minor scratches", "minor chord", "minor key", "kinderleicht",
    ]

    static let explicit = TermList(
        words: [
            "nsfw", "nude", "nudes", "naked", "nudity", "sex", "sexual", "sexually", "porn", "porno",
            "pornographic", "hentai", "explicit", "lewd", "genitals", "genitalia", "penis", "vagina",
            "pussy", "cock", "nipples", "nipple", "areola", "areolae", "topless", "bottomless",
            "orgasm", "cum", "cumshot", "erection", "aroused", "intercourse", "fellatio", "blowjob",
            "ahegao", "bdsm", "bondage", "fetish", "rape", "uncensored",
            // German
            "nackt", "nackte", "nackten", "nackter", "nacktheit", "sexuell", "sexuelle",
            "geschlechtsverkehr", "brustwarzen", "pornografisch",
        ],
        phrases: ["oben ohne", "spread legs", "no clothes", "without clothes", "ohne kleidung"],
        stems: ["masturbat", "molest", "undress", "strippi", "striptease", "ejacul"]
    )

    static let suggestive = TermList(
        words: [
            "sexy", "seductive", "suggestive", "sensual", "erotic", "erotica", "lingerie",
            "underwear", "panties", "panty", "pantyshot", "upskirt", "bra", "thong", "bikini",
            "cleavage", "provocative", "ecchi", "skimpy", "revealing", "babydoll", "flirtatious",
            // German
            "erotisch", "erotische", "verführerisch", "aufreizend", "dessous", "unterwäsche", "reizwäsche",
        ],
        phrases: ["pin up", "see through", "bedroom eyes", "lap dance", "baby doll"]
    )

    /// Clothing words that must not be negated in an image with a minor.
    static let clothing = TermList(
        words: [
            "clothes", "clothing", "clothed", "dressed", "dress", "shirt", "shirts", "pants",
            "trousers", "skirt", "shorts", "outfit", "garment", "garments", "swimsuit", "fabric",
            "kleidung", "angezogen", "bekleidet", "hemd", "kleid",
        ]
    )
}

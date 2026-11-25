// Style modifiers: camera, light and film looks for photos, comic styles
// for anime and illustration. At most one per category is picked next to
// the prompt; `compose()` adds their terms after it, and the guard checks
// them like any other part of the prompt.

import Foundation

public enum ModifierCategory: String, Codable, CaseIterable, Sendable {
    case camera
    case light
    case film
    case comic

    public var label: String {
        switch self {
        case .camera: "Camera"
        case .light: "Light"
        case .film: "Film"
        case .comic: "Comic Style"
        }
    }

    public var icon: String {
        switch self {
        case .camera: "camera"
        case .light: "sun.max"
        case .film: "film"
        case .comic: "paintbrush.pointed"
        }
    }

    /// Camera, light and film are for photos; comic styles for drawn pictures.
    public func applies(to style: PictureStyle) -> Bool {
        switch self {
        case .camera, .light, .film: style == .photo
        case .comic: style != .photo
        }
    }

    /// The categories offered for a preset of `style`, in display order.
    public static func active(for style: PictureStyle) -> [ModifierCategory] {
        allCases.filter { $0.applies(to: style) }
    }
}

public struct StyleModifier: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: ModifierCategory
    /// Terms added to the prompt.
    public var positive: String
    /// Terms added to the negative prompt.
    public var negative: String
    /// Comes with the app; can be edited and restored, not deleted.
    public var builtIn: Bool

    public init(
        id: UUID = UUID(), name: String, category: ModifierCategory, positive: String = "", negative: String = "",
        builtIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.positive = positive
        self.negative = negative
        self.builtIn = builtIn
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, positive, negative, builtIn
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        category = try c.decodeIfPresent(ModifierCategory.self, forKey: .category) ?? .camera
        positive = try c.decodeIfPresent(String.self, forKey: .positive) ?? ""
        negative = try c.decodeIfPresent(String.self, forKey: .negative) ?? ""
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }

    /// The built-in version of this modifier, for "Restore Default".
    public var original: StyleModifier? { Self.builtIns.first { $0.id == id } }

    /// The modifiers that come with the app. Their ids are fixed so edits
    /// and previews stay attached across launches.
    public static let builtIns: [StyleModifier] = {
        func m(_ n: Int, _ name: String, _ cat: ModifierCategory, _ pos: String, _ neg: String = "") -> StyleModifier {
            let id = UUID(uuidString: String(format: "5A7E0000-0000-4000-8000-%012d", n))!
            return StyleModifier(id: id, name: name, category: cat, positive: pos, negative: neg, builtIn: true)
        }
        return [
            m(1, "35 mm Street", .camera, "35mm lens, street photography, candid shot, shallow depth of field"),
            m(2, "85 mm Portrait", .camera, "85mm portrait lens, f/1.8, creamy bokeh, subject in sharp focus"),
            m(3, "Macro", .camera, "macro photography, 100mm macro lens, extreme close-up, fine detail"),
            m(4, "Telephoto", .camera, "telephoto lens, 200mm, compressed perspective, background blur"),
            m(5, "Aerial Drone", .camera, "aerial drone photo, top-down view, wide angle"),
            m(11, "Golden Hour", .light, "golden hour, warm low sunlight, long shadows, soft glow"),
            m(12, "Softbox Studio", .light, "studio lighting, large softbox, even soft light, clean background"),
            m(13, "Rim Light", .light, "dramatic rim light, backlit, dark background, glowing edges"),
            m(14, "Neon Night", .light, "neon lights at night, colorful reflections, wet street, cinematic"),
            m(15, "Overcast", .light, "overcast sky, diffuse daylight, soft shadows, muted tones"),
            m(21, "Portra 400", .film, "shot on Kodak Portra 400, film grain, warm natural skin tones"),
            m(22, "Velvia", .film, "shot on Fujifilm Velvia, saturated colors, high contrast, slide film"),
            m(23, "HP5 Black and White", .film, "black and white, shot on Ilford HP5, grainy, high contrast", "color"),
            m(24, "Cinestill 800T", .film, "shot on Cinestill 800T, tungsten film, halation, cool shadows"),
            m(25, "Polaroid", .film, "polaroid photo, instant film, faded colors, soft vignette"),
            m(31, "Manga Screentone", .comic, "manga style, monochrome, screentone, ink lineart", "color"),
            m(32, "US Comic", .comic, "american comic book style, bold ink outlines, halftone dots, flat colors"),
            m(33, "Ligne Claire", .comic, "ligne claire, clean uniform lines, flat colors, european comic"),
            m(34, "90s Cel Anime", .comic, "1990s anime style, cel shading, retro, vhs colors"),
            m(35, "Watercolor Storybook", .comic, "watercolor, storybook illustration, soft edges, paper texture"),
            m(36, "Noir Comic", .comic, "noir comic, heavy black shadows, high contrast ink, limited palette"),
        ]
    }()

    /// `stored` with every built-in it lacks added at the end. Edited
    /// built-ins keep their edits.
    public static func withBuiltIns(_ stored: [StyleModifier]) -> [StyleModifier] {
        let have = Set(stored.map(\.id))
        return stored + builtIns.filter { !have.contains($0.id) }
    }
}

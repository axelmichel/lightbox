import Foundation

/// A picture format such as 3:2. The pixel size depends on the model:
/// SDXL-based models want about one megapixel, SD 1.5 a short side of 512.
public enum AspectRatio: String, CaseIterable, Codable, Sendable {
    case square
    case r5x4, r4x5
    case r4x3, r3x4
    case r3x2, r2x3
    case r16x9, r9x16
    case r21x9, r9x21

    /// Width and height of the ratio, e.g. (3, 2).
    public var parts: (width: Int, height: Int) {
        switch self {
        case .square: (1, 1)
        case .r5x4: (5, 4)
        case .r4x5: (4, 5)
        case .r4x3: (4, 3)
        case .r3x4: (3, 4)
        case .r3x2: (3, 2)
        case .r2x3: (2, 3)
        case .r16x9: (16, 9)
        case .r9x16: (9, 16)
        case .r21x9: (21, 9)
        case .r9x21: (9, 21)
        }
    }

    public var label: String { "\(parts.width):\(parts.height)" }

    /// Width divided by height.
    public var ratio: Double { Double(parts.width) / Double(parts.height) }

    public var isPortrait: Bool { parts.height > parts.width }

    /// The same format turned by 90°.
    public var turned: AspectRatio {
        AspectRatio.allCases.first { $0.parts == (parts.height, parts.width) } ?? self
    }

    /// The size the models of `family` are usually run at in this format.
    public func size(for family: ModelFamily) -> (width: Int, height: Int) {
        switch family {
        case .sd15: size(shortSide: 512)
        default: size(area: 1024 * 1024)
        }
    }

    /// The largest size of about `area` pixels in this format, in multiples
    /// of `step`. For SDXL this gives the sizes it was trained on
    /// (1216 × 832 for 3:2, 1344 × 768 for 16:9).
    public func size(area: Int, step: Int = 64) -> (width: Int, height: Int) {
        let r = max(ratio, 1 / ratio)
        let short = max(1, Int((sqrt(Double(area) / r) / Double(step)).rounded())) * step
        let long = max(short, Int(Double(short) * r / Double(step)) * step)
        return isPortrait ? (short, long) : (long, short)
    }

    /// The size with a short side of `shortSide`, the long side rounded to `step`.
    public func size(shortSide: Int, step: Int = 64) -> (width: Int, height: Int) {
        let r = max(ratio, 1 / ratio)
        let long = max(shortSide, Int((Double(shortSide) * r / Double(step)).rounded()) * step)
        return isPortrait ? (shortSide, long) : (long, shortSide)
    }

    /// The format of `width` × `height`: one whose model size it is, else
    /// the closest one within 4 % (rounded sizes are never exact; SDXL's
    /// 4:3 is 1152 × 896, closer to 5:4 than to 4:3).
    public static func matching(width: Int, height: Int) -> AspectRatio? {
        guard width > 0, height > 0 else { return nil }
        if let exact = allCases.first(where: { f in
            [ModelFamily.sd15, .sdxl].contains { f.size(for: $0) == (width, height) }
        }) {
            return exact
        }
        let r = log(Double(width) / Double(height))
        let best = allCases.min { abs(log($0.ratio) - r) < abs(log($1.ratio) - r) }
        guard let best, abs(log(best.ratio) - r) < 0.04 else { return nil }
        return best
    }
}

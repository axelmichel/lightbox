// Editing the whole composed picture with an edit model (Flux 2 Klein with
// `ReferenceLatent`): the picture goes at about one megapixel, the model
// returns it changed as the instruction says, and the result comes back as
// a layer, whole or only inside an area.

import CoreGraphics
import Foundation

public enum ImageEdit {
    /// The size the picture is sent at: about a megapixel, its proportions,
    /// multiples of 16.
    public static func workSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let k = min(2, sqrt(1024.0 * 1024 / Double(max(1, width * height))))
        return (
            max(64, Int((Double(width) * k / 16).rounded()) * 16),
            max(64, Int((Double(height) * k / 16).rounded()) * 16)
        )
    }

    /// `picture` (the flattened composition) as sent: at the work size, as
    /// PNG; transparent parts gray, which the model handles better than black.
    public static func prepare(_ picture: CGImage) -> Data? {
        let size = workSize(width: picture.width, height: picture.height)
        return Inpaint.draw(picture, width: size.width, height: size.height, fill: 0.5).flatMap(ImageCoding.encodePNG)
    }

    /// The model's `result` as a layer for a canvas of `width` × `height`:
    /// all of it, or with `mask` only that part, with a soft edge, framed to it.
    public static func layer(from result: CGImage, width: Int, height: Int, mask: SelectionMask? = nil)
        -> (picture: PixelBuffer, frame: ImageFrame)?
    {
        guard let full = Inpaint.draw(result, width: width, height: height, fill: nil) else { return nil }
        guard let mask, let r = InpaintRegion.plan(mask: mask, family: .flux2) else {
            return PixelBuffer(full).map { ($0, ImageFrame(x: 0, y: 0, width: Double(width), height: Double(height))) }
        }
        guard let part = full.cropping(to: r.rect), let patch = Inpaint.patch(part, mask: mask, region: r) else {
            return nil
        }
        return (
            patch,
            ImageFrame(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.height))
        )
    }
}

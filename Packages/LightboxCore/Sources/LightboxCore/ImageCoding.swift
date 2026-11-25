import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The working color space and PNG reading and writing.
public enum ImageCoding {
    public static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    public static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// A picture from a file (PNG, JPEG, HEIC, …), turned upright as its
    /// orientation says and no larger than `maxSide`.
    public static func decodeUpright(_ data: Data, maxSide: Int = 8192) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxSide),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A transparent picture, as PNG.
    public static func emptyPNG(width: Int, height: Int) -> Data? {
        PixelBuffer(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
            .pngData()
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// A shadow made from the shape of what a layer shows (its non-transparent
// pixels): a drop shadow offset behind it, or a cast shadow lying on the
// ground from its lowest point, leaning away from the light. It doesn't
// change the layer's pixels; the canvas and the saved picture draw it with
// the same `render`, so they match.

import CoreGraphics
import CoreImage
import Foundation

public struct LayerShadow: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Offset behind the layer, as if the light came from the front.
        case drop
        /// On the ground, from the layer's lowest visible point.
        case cast

        public var label: String {
            switch self {
            case .drop: "Drop Shadow"
            case .cast: "Cast Shadow"
            }
        }
    }

    public var style: Style
    /// Drop: the direction the shadow falls, in degrees (0 right, 90 down).
    /// Cast: how far it leans, −70…70 (negative = to the left).
    public var angle: Double
    /// Drop: how far it falls; cast: how long it is (negative = towards
    /// the viewer). As a share of the layer's height, so it scales with it.
    public var distance: Double
    /// Softness, as a share of the layer's height.
    public var blur: Double
    public var opacity: Double

    public init(style: Style) {
        self.style = style
        switch style {
        case .drop: (angle, distance, blur, opacity) = (60, 0.03, 0.02, 0.5)
        case .cast: (angle, distance, blur, opacity) = (35, 0.35, 0.015, 0.45)
        }
    }

    /// The shadow of `image` (a layer's picture) and where it lies, in the
    /// picture's pixels from its top left (it may reach beyond the picture).
    public func render(_ image: CGImage) -> (image: CGImage, rect: CGRect)? {
        let h = Double(image.height)
        guard h > 0, opacity > 0, let content = Self.visibleBounds(image) else { return nil }
        // Only the visible part, so the shadow is no larger than it needs to be.
        let source = CIImage(cgImage: image).cropped(
            to: CGRect(x: content.minX, y: h - content.maxY, width: content.width, height: content.height))
        // Black where the picture is, with its alpha times the opacity.
        var shadow = source.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        switch style {
        case .drop:
            // Core Image has y going up; the shadow falls down for 90°.
            let a = angle * .pi / 180
            shadow = shadow.transformed(
                by: CGAffineTransform(translationX: cos(a) * distance * h, y: -sin(a) * distance * h))
        case .cast:
            // The ground line, in Core Image's y (up from the bottom).
            let y0 = h - content.maxY
            let lean = tan(min(max(angle, -70), 70) * .pi / 180)
            // Flattened onto the ground and leaning away from the light,
            // standing on the same line as the layer.
            let t = CGAffineTransform(translationX: 0, y: -y0)
                .concatenating(CGAffineTransform(a: 1, b: 0, c: lean * distance, d: distance, tx: 0, ty: 0))
                .concatenating(CGAffineTransform(translationX: 0, y: y0))
            shadow = shadow.transformed(by: t)
            // Fainter towards its far end.
            let reach = h * distance
            let fade = CIFilter(
                name: "CILinearGradient",
                parameters: [
                    "inputPoint0": CIVector(x: 0, y: y0), "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                    "inputPoint1": CIVector(x: 0, y: y0 + reach),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.15),
                ])?.outputImage
            if let fade {
                shadow = shadow.applyingFilter(
                    "CIBlendWithAlphaMask",
                    parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: fade]
                )
                .cropped(to: shadow.extent)
            }
        }
        let radius = blur * h
        if radius > 0.5 {
            shadow = shadow.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        }
        let extent = shadow.extent.integral
        guard extent.width > 0, extent.height > 0, extent.width < 20000, extent.height < 20000,
            let out = Self.context.createCGImage(
                shadow, from: extent, format: .RGBA8, colorSpace: ImageCoding.colorSpace)
        else { return nil }
        return (out, CGRect(x: extent.minX, y: h - extent.maxY, width: extent.width, height: extent.height))
    }

    /// The lowest row (from the top) with a visible pixel.
    static func lowestRow(_ image: CGImage) -> Int? {
        visibleBounds(image).map { Int($0.maxY) - 1 }
    }

    /// Where the picture's visible pixels are, from its top left.
    static func visibleBounds(_ image: CGImage) -> CGRect? {
        guard let b = PixelBuffer(image) else { return nil }
        var minX = b.width
        var minY = b.height
        var maxX = -1
        var maxY = -1
        b.pixels.withUnsafeBufferPointer { p in
            for y in 0..<b.height {
                let row = y * b.width * 4
                for x in 0..<b.width where p[row + x * 4 + 3] > 16 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Creating a context is costly; one is enough, and it is thread-safe.
    private static let context = CIContext()
}

extension CompositionLayer {
    /// Where a shadow `rect` (in the layer's picture pixels) lies on the canvas.
    public func canvasFrame(of rect: CGRect) -> ImageFrame {
        let kx = frame.width / Double(pixelWidth)
        let ky = frame.height / Double(pixelHeight)
        return ImageFrame(
            x: frame.x + rect.minX * kx, y: frame.y + rect.minY * ky, width: rect.width * kx, height: rect.height * ky)
    }
}

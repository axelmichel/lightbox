import CoreGraphics
import Foundation

/// An image's pixels: 8-bit RGBA, premultiplied, Display P3, top row first.
public struct PixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init?(_ image: CGImage) {
        let w = image.width
        let h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: ImageCoding.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: bytes)
    }

    /// Decoded from PNG or JPEG data.
    public init?(data: Data) {
        guard let image = ImageCoding.decode(data) else { return nil }
        self.init(image)
    }

    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: ImageCoding.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func pngData() -> Data? { cgImage().flatMap(ImageCoding.encodePNG) }

    /// The same pixels in gray (Rec. 709 luma), alpha kept. Luma is linear,
    /// so it can be taken of the premultiplied colors directly.
    public func grayscaled() -> PixelBuffer {
        var out = self
        out.pixels.withUnsafeMutableBufferPointer { p in
            for o in stride(from: 0, to: p.count, by: 4) {
                let y = 0.2126 * Double(p[o]) + 0.7152 * Double(p[o + 1]) + 0.0722 * Double(p[o + 2])
                let v = UInt8(min(y.rounded(), Double(p[o + 3])))
                (p[o], p[o + 1], p[o + 2]) = (v, v, v)
            }
        }
        return out
    }
}

/// Which pixels of an image are selected, top row first.
public struct SelectionMask: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// 1 = selected.
    public var values: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        values = [UInt8](repeating: 0, count: width * height)
    }

    public var isEmpty: Bool { !values.contains(1) }
    public var count: Int { values.reduce(0) { $0 + Int($1) } }

    public subscript(x: Int, y: Int) -> Bool { values[y * width + x] != 0 }

    public mutating func formUnion(_ other: SelectionMask) {
        for i in values.indices where other.values[i] != 0 { values[i] = 1 }
    }

    public mutating func subtract(_ other: SelectionMask) {
        for i in values.indices where other.values[i] != 0 { values[i] = 0 }
    }

    /// A rectangle or the ellipse in it, in the mask's pixels.
    public static func area(width: Int, height: Int, frame f: ImageFrame, ellipse: Bool) -> SelectionMask {
        var m = SelectionMask(width: width, height: height)
        let x0 = max(0, Int(f.x.rounded(.down)))
        let y0 = max(0, Int(f.y.rounded(.down)))
        let x1 = min(width, Int(f.maxX.rounded(.up)))
        let y1 = min(height, Int(f.maxY.rounded(.up)))
        guard x0 < x1, y0 < y1, f.width > 0, f.height > 0 else { return m }
        let cx = f.x + f.width / 2
        let cy = f.y + f.height / 2
        for y in y0..<y1 {
            let dy = (Double(y) + 0.5 - cy) / (f.height / 2)
            for x in x0..<x1 {
                let dx = (Double(x) + 0.5 - cx) / (f.width / 2)
                if !ellipse || dx * dx + dy * dy <= 1 { m.values[y * width + x] = 1 }
            }
        }
        return m
    }

    /// Everything that wasn't selected.
    public func inverted() -> SelectionMask {
        var out = self
        for i in out.values.indices { out.values[i] = values[i] == 0 ? 1 : 0 }
        return out
    }

    /// The selection drawn in `color` (RGB 0…1), stronger along its edge,
    /// for showing on top of the picture.
    public func overlay(red: Double, green: Double, blue: Double) -> PixelBuffer {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where values[y * width + x] != 0 {
                let edge =
                    x == 0 || y == 0 || x == width - 1 || y == height - 1 || values[y * width + x - 1] == 0
                    || values[y * width + x + 1] == 0 || values[(y - 1) * width + x] == 0
                    || values[(y + 1) * width + x] == 0
                let a = edge ? 0.95 : 0.4
                let o = (y * width + x) * 4
                out[o] = UInt8(red * a * 255)
                out[o + 1] = UInt8(green * a * 255)
                out[o + 2] = UInt8(blue * a * 255)
                out[o + 3] = UInt8(a * 255)
            }
        }
        return PixelBuffer(width: width, height: height, pixels: out)
    }
}

/// Selects pixels of a similar color, as the magic wand in image editors
/// does, and erases them.
public enum MagicWand {
    /// Pixels whose red, green, blue and alpha each differ from the clicked
    /// pixel by at most `tolerance` (0…255). `contiguous` selects only those
    /// connected to the clicked pixel; otherwise all of them in the image.
    public static func select(
        _ image: PixelBuffer, x: Int, y: Int, tolerance: Int, contiguous: Bool = true
    ) -> SelectionMask {
        let w = image.width
        let h = image.height
        var mask = SelectionMask(width: w, height: h)
        guard x >= 0, y >= 0, x < w, y < h else { return mask }
        image.pixels.withUnsafeBufferPointer { p in
            mask.values.withUnsafeMutableBufferPointer { m in
                let s = (y * w + x) * 4
                let seed = (Int(p[s]), Int(p[s + 1]), Int(p[s + 2]), Int(p[s + 3]))
                func similar(_ i: Int) -> Bool {
                    let o = i * 4
                    return abs(Int(p[o]) - seed.0) <= tolerance && abs(Int(p[o + 1]) - seed.1) <= tolerance
                        && abs(Int(p[o + 2]) - seed.2) <= tolerance && abs(Int(p[o + 3]) - seed.3) <= tolerance
                }
                guard contiguous else {
                    for i in 0..<(w * h) where similar(i) { m[i] = 1 }
                    return
                }
                // Scanline flood fill: fill a run, then queue the runs above
                // and below it.
                var stack = [(x, y)]
                while let (sx, sy) = stack.popLast() {
                    let row = sy * w
                    guard m[row + sx] == 0, similar(row + sx) else { continue }
                    var left = sx
                    while left > 0, m[row + left - 1] == 0, similar(row + left - 1) { left -= 1 }
                    var right = sx
                    while right < w - 1, m[row + right + 1] == 0, similar(row + right + 1) { right += 1 }
                    for i in (row + left)...(row + right) { m[i] = 1 }
                    for ny in [sy - 1, sy + 1] where ny >= 0 && ny < h {
                        var inRun = false
                        for nx in left...right {
                            let open = m[ny * w + nx] == 0 && similar(ny * w + nx)
                            if open, !inRun { stack.append((nx, ny)) }
                            inRun = open
                        }
                    }
                }
            }
        }
        return mask
    }

    /// `image` with the selected pixels made transparent. With `antiAlias`
    /// the pixels just outside the selection are faded a little, so the new
    /// edge isn't jagged.
    public static func erase(_ image: PixelBuffer, _ mask: SelectionMask, antiAlias: Bool = true) -> PixelBuffer {
        precondition(image.width == mask.width && image.height == mask.height)
        let w = image.width
        let h = image.height
        var out = image
        out.pixels.withUnsafeMutableBufferPointer { p in
            mask.values.withUnsafeBufferPointer { m in
                for y in 0..<h {
                    for x in 0..<w {
                        // How much of the pixel goes: all of a selected one. With
                        // anti-aliasing, kept pixels along the edge lose the share of
                        // their neighbors that is selected, so no trace of the removed
                        // color is left and the edge isn't jagged.
                        var removed = Double(m[y * w + x])
                        if antiAlias, removed == 0 {
                            var sum = 0
                            var n = 0
                            for dy in -1...1 where y + dy >= 0 && y + dy < h {
                                for dx in -1...1 where x + dx >= 0 && x + dx < w {
                                    sum += Int(m[(y + dy) * w + x + dx])
                                    n += 1
                                }
                            }
                            removed = Double(sum) / Double(n)
                        }
                        guard removed > 0 else { continue }
                        let keep = 1 - removed
                        let o = (y * w + x) * 4
                        for c in 0..<4 { p[o + c] = UInt8((Double(p[o + c]) * keep).rounded()) }
                    }
                }
            }
        }
        return out
    }
}

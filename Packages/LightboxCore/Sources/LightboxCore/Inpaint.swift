// Painting part of a layer again with the model (inpainting), as Krita's
// AI plugin does it: only the selected part and some room around it go to
// ComfyUI, scaled to the size the model works best at. The result is put
// back on the device with a soft edge, so the rest of the picture keeps
// its exact pixels.

import CoreGraphics
import Foundation

public struct InpaintRegion: Equatable, Sendable {
    /// The part of the picture sent, in its pixels (top row first).
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// The size it is sent at: about the model's own size, multiples of 16.
    public var workWidth: Int
    public var workHeight: Int
    /// How far the selection is grown, and how wide its soft edge is, in
    /// picture pixels.
    public var grow: Int
    public var feather: Int

    /// The region for `mask`; `nil` when nothing is selected.
    public static func plan(mask: SelectionMask, family: ModelFamily) -> InpaintRegion? {
        var minX = mask.width
        var minY = mask.height
        var maxX = -1
        var maxY = -1
        for y in 0..<mask.height {
            let row = y * mask.width
            for x in 0..<mask.width where mask.values[row + x] != 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let side = max(maxX - minX + 1, maxY - minY + 1)
        let grow = max(2, side / 100)
        let feather = max(3, side / 40)
        // Room around the selection, so the model sees what it must fit into.
        let pad = max(32, side * 3 / 10, 2 * (grow + feather) + 2)
        let minSide = family == .sd15 ? 256 : 384
        var x0 = minX - pad
        var x1 = maxX + 1 + pad
        var y0 = minY - pad
        var y1 = maxY + 1 + pad
        // Small selections still get enough of the picture around them.
        if x1 - x0 < minSide {
            let extra = minSide - (x1 - x0)
            x0 -= extra / 2
            x1 += extra - extra / 2
        }
        if y1 - y0 < minSide {
            let extra = minSide - (y1 - y0)
            y0 -= extra / 2
            y1 += extra - extra / 2
        }
        x0 = max(0, x0)
        y0 = max(0, y0)
        x1 = min(mask.width, x1)
        y1 = min(mask.height, y1)
        let w = x1 - x0
        let h = y1 - y0
        let area = family == .sd15 ? 512.0 * 512 : 1024.0 * 1024
        // Up to 4× for small parts (more detail); down for large ones.
        let k = min(4, sqrt(area / Double(w * h)))
        // Multiples of 16, which every model's latent fits (Flux 2's too).
        let ww = max(64, Int((Double(w) * k / 16).rounded()) * 16)
        let wh = max(64, Int((Double(h) * k / 16).rounded()) * 16)
        return InpaintRegion(
            x: x0, y: y0, width: w, height: h, workWidth: ww, workHeight: wh, grow: grow, feather: feather)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public enum Inpaint {
    /// The region of `image` and its mask (red 255 = paint again) as PNGs at
    /// the work size. Transparent parts are filled with gray, which the
    /// model can paint over more easily than black.
    public static func prepare(_ image: PixelBuffer, mask: SelectionMask, region r: InpaintRegion)
        -> (image: Data, mask: Data)?
    {
        guard let source = image.cgImage()?.cropping(to: r.rect) else { return nil }
        let grown = grow(crop(mask, r), width: r.width, height: r.height, by: r.grow)
        let maskPixels = grown.flatMap { v -> [UInt8] in
            let b = UInt8((v * 255).rounded())
            return [b, b, b, 255]
        }
        guard
            let maskImage = PixelBuffer(width: r.width, height: r.height, pixels: maskPixels).cgImage(),
            let picture = draw(source, width: r.workWidth, height: r.workHeight, fill: 0.5),
            let maskScaled = draw(maskImage, width: r.workWidth, height: r.workHeight, fill: 0),
            let png = ImageCoding.encodePNG(picture), let maskPNG = ImageCoding.encodePNG(maskScaled)
        else { return nil }
        return (png, maskPNG)
    }

    /// `image` with the model's `result` (the region at work size) put back
    /// where `mask` is, with a soft edge. Everything else stays as it was.
    public static func merge(_ result: CGImage, into image: PixelBuffer, mask: SelectionMask, region r: InpaintRegion)
        -> PixelBuffer?
    {
        guard let scaled = draw(result, width: r.width, height: r.height, fill: nil),
            let patch = PixelBuffer(scaled)
        else { return nil }
        let grown = grow(crop(mask, r), width: r.width, height: r.height, by: r.grow)
        let soft = blur(grown, width: r.width, height: r.height, radius: r.feather)
        var out = image
        out.pixels.withUnsafeMutableBufferPointer { p in
            for y in 0..<r.height {
                for x in 0..<r.width {
                    let m = Double(soft[y * r.width + x])
                    guard m > 0.002 else { continue }
                    let o = ((r.y + y) * image.width + r.x + x) * 4
                    let q = (y * r.width + x) * 4
                    for c in 0..<4 {
                        p[o + c] = UInt8((Double(p[o + c]) * (1 - m) + Double(patch.pixels[q + c]) * m).rounded())
                    }
                }
            }
        }
        return out
    }

    /// The model's `result` cut to `mask` with a soft edge, at the region's
    /// size: transparent where nothing was painted. Becomes a layer of its
    /// own at the region (redrawing an area of the whole picture).
    public static func patch(_ result: CGImage, mask: SelectionMask, region r: InpaintRegion) -> PixelBuffer? {
        guard let scaled = draw(result, width: r.width, height: r.height, fill: nil),
            let painted = PixelBuffer(scaled)
        else { return nil }
        let grown = grow(crop(mask, r), width: r.width, height: r.height, by: r.grow)
        let soft = blur(grown, width: r.width, height: r.height, radius: r.feather)
        var out = painted
        out.pixels.withUnsafeMutableBufferPointer { p in
            for i in 0..<(r.width * r.height) {
                let m = Double(soft[i])
                for c in 0..<4 { p[i * 4 + c] = UInt8((Double(p[i * 4 + c]) * m).rounded()) }
            }
        }
        return out
    }

    /// The mask inside the region, 0 or 1.
    static func crop(_ mask: SelectionMask, _ r: InpaintRegion) -> [Float] {
        var out = [Float](repeating: 0, count: r.width * r.height)
        for y in 0..<r.height {
            for x in 0..<r.width where mask.values[(r.y + y) * mask.width + r.x + x] != 0 {
                out[y * r.width + x] = 1
            }
        }
        return out
    }

    /// Everything within about `by` pixels of the mask, 0 or 1.
    static func grow(_ m: [Float], width: Int, height: Int, by r: Int) -> [Float] {
        blur(m, width: width, height: height, radius: r).map { $0 > 0.001 ? 1 : 0 }
    }

    /// A box blur, run twice for a smoother edge.
    static func blur(_ m: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        guard r > 0 else { return m }
        var a = m
        var b = [Float](repeating: 0, count: m.count)
        for _ in 0..<2 {
            boxPass(a, &b, count: h, length: w, stride: 1, step: w, radius: r)
            boxPass(b, &a, count: w, length: h, stride: w, step: 1, radius: r)
        }
        return a
    }

    /// One direction of a box blur: `count` lines of `length` values.
    private static func boxPass(
        _ src: [Float], _ dst: inout [Float], count: Int, length: Int, stride: Int, step: Int, radius r: Int
    ) {
        let scale = 1 / Float(2 * r + 1)
        for line in 0..<count {
            let base = line * step
            var sum: Float = 0
            for i in -r...r { sum += src[base + min(max(i, 0), length - 1) * stride] }
            for i in 0..<length {
                dst[base + i * stride] = sum * scale
                let add = min(i + r + 1, length - 1)
                let drop = max(i - r, 0)
                sum += src[base + add * stride] - src[base + drop * stride]
            }
        }
    }

    /// `image` scaled to `width` × `height`, over gray `fill` (nil = clear).
    static func draw(_ image: CGImage, width: Int, height: Int, fill: CGFloat?) -> CGImage? {
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: ImageCoding.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        if let fill {
            ctx.setFillColor(gray: fill, alpha: 1)
            ctx.fill(all)
        }
        ctx.draw(image, in: all)
        return ctx.makeImage()
    }
}

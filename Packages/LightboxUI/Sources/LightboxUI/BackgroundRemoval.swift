import CoreImage
import Foundation
import ImageIO
import LightboxCore
import SwiftUI
import UniformTypeIdentifiers
import Vision
import os

/// Cuts the people, animals and objects out of a picture with Apple's
/// Vision framework, on the device. The result has the same size as the
/// original, so it lines up with it.
enum BackgroundRemoval {
    enum Failure: Error, CustomStringConvertible {
        case notAnImage
        case nothingFound

        var description: String {
            switch self {
            case .notAnImage: "The picture can't be read."
            case .nothingFound: "No person, animal or object stands out from the background."
            }
        }
    }

    /// Edge strength used when nothing else is chosen.
    static let defaultEdge = 0.5
    /// The edge strength last chosen, used for new cut-outs.
    static var lastEdge: Double {
        get { UserDefaults.standard.object(forKey: "cutOutEdge") as? Double ?? defaultEdge }
        set { UserDefaults.standard.set(newValue, forKey: "cutOutEdge") }
    }

    /// PNG data of the cut-out. `edge` is how tightly the edge is cut, from
    /// 0 (Vision's soft edge) to 1 (hard, pulled in further). Runs off the
    /// main thread.
    static func cutOut(_ image: Data, edge: Double) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try run(image, edge: edge) }.value
    }

    private static func run(_ data: Data, edge: Double) throws -> Data {
        let masked = try mask(of: data)
        let cut = refine(masked.image, mask: masked.mask, edge: edge)
        guard
            let cg = context.createCGImage(cut, from: cut.extent, format: .RGBA8, colorSpace: ImageCoding.colorSpace),
            let png = ImageCoding.encodePNG(cg)
        else { throw Failure.notAnImage }
        return png
    }

    /// A picture and Vision's foreground mask of it.
    private struct Masked: @unchecked Sendable {
        var data: Data
        var image: CIImage
        var mask: CIImage
    }

    /// Creating a context is costly; one is enough, and it is thread-safe.
    private static let context = CIContext()
    /// The last few masks, so moving the Edge slider doesn't run Vision again.
    private static let masks = OSAllocatedUnfairLock<[Masked]>(initialState: [])

    private static func mask(of data: Data) throws -> Masked {
        if let cached = masks.withLock({ $0.first { $0.data == data } }) { return cached }
        guard let image = decode(data) else { throw Failure.notAnImage }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw Failure.nothingFound }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let masked = Masked(data: data, image: CIImage(cgImage: image), mask: CIImage(cvPixelBuffer: mask))
        masks.withLock { $0 = [masked] + $0.prefix(3) }
        return masked
    }

    /// Vision's mask is soft at the edge, and the edge pixels still hold the
    /// background's color, which shows as a glow. So the mask is hardened,
    /// pulled in and feathered again, both as much as `edge` says, and the
    /// colors at the edge are replaced by the colors just inside it. At the
    /// default 0.5 the edge moves in by a pixel per 600 px of picture.
    static func refine(_ image: CIImage, mask: CIImage, edge: Double) -> CIImage {
        let extent = image.extent
        let unit = max(1, min(extent.width, extent.height) / 600)
        let edge = min(max(edge, 0), 1)
        let shrink = 2 * edge * unit
        let slope = 1 + 6 * edge
        let bias = 0.5 - slope / 2
        // The mask's value in all channels, so every filter reads the same one.
        let soft = mask.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        // A steeper ramp around 0.5; at the default, 0.375 → 0 and 0.625 → 1.
        let hard = soft.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: slope, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: slope, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: slope, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ]
        ).applyingFilter("CIColorClamp")
        func eroded(_ radius: Double) -> CIImage {
            guard radius > 0.1 else { return hard.clampedToExtent() }
            return hard.clampedToExtent().applyingFilter(
                "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
        }
        let alpha = eroded(shrink).applyingGaussianBlur(sigma: 0.6 * unit).cropped(to: extent)
        // Colors from well inside the shape, spread outward over the edge:
        // blurred with their coverage, divided by it, then made opaque so
        // the final mask alone decides how see-through the edge is. The blur
        // reaches past the edge at every strength, Soft included.
        let inner = eroded(shrink + 2).cropped(to: extent)
        let clear = CIImage(color: .clear).cropped(to: extent)
        let inside = image.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: inner])
        let spread = inside.clampedToExtent().applyingGaussianBlur(sigma: 3 * unit + shrink)
            .applyingFilter("CIUnpremultiply").settingAlphaOne(in: extent).cropped(to: extent)
        let colors = image.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: spread, kCIInputMaskImageKey: inner])
        return colors.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: alpha])
    }
}

/// How tightly a cut-out's edge is cut. The picture is cut again when the
/// slider is let go, which takes a moment.
struct EdgeSlider: View {
    let edge: Double
    let busy: Bool
    let apply: (Double) -> Void
    /// While dragging, and until the new cut-out is there.
    @State private var value: Double?

    var body: some View {
        HStack {
            Slider(
                value: Binding(get: { value ?? edge }, set: { value = $0 }), in: 0...1,
                label: { Text("Edge") }, minimumValueLabel: { Text("Soft").font(.caption) },
                maximumValueLabel: { Text("Tight").font(.caption) },
                onEditingChanged: { editing in
                    if !editing, let value, abs(value - edge) > 0.005 { apply(value) }
                })
            if busy { ProgressView().controlSize(.small) }
        }
        .disabled(busy)
        .help("Soft keeps Vision's edge; tight cuts closer and removes more of the background's rim")
        .onChange(of: edge) { value = nil }
        .onChange(of: busy) { _, now in if !now { value = nil } }
    }
}

/// Shows through the transparent parts of a cut-out.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell = 8.0
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col).isMultiple(of: 2) {
                    ctx.fill(
                        Path(CGRect(x: Double(col) * cell, y: Double(row) * cell, width: cell, height: cell)),
                        with: .color(.gray.opacity(0.18)))
                }
            }
        }
        .background(.white)
    }
}

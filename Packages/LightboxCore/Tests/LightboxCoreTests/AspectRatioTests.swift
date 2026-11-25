import Testing

@testable import LightboxCore

@Test func sdxlSizesAreTheTrainedBuckets() {
    #expect(AspectRatio.square.size(for: .sdxl) == (1024, 1024))
    #expect(AspectRatio.r3x2.size(for: .sdxl) == (1216, 832))
    #expect(AspectRatio.r2x3.size(for: .illustrious) == (832, 1216))
    #expect(AspectRatio.r4x3.size(for: .pony) == (1152, 896))
    #expect(AspectRatio.r16x9.size(for: .sdxl) == (1344, 768))
    #expect(AspectRatio.r9x16.size(for: .sdxl) == (768, 1344))
}

@Test func sd15SizesKeepAShortSideOf512() {
    #expect(AspectRatio.square.size(for: .sd15) == (512, 512))
    #expect(AspectRatio.r2x3.size(for: .sd15) == (512, 768))
    #expect(AspectRatio.r16x9.size(for: .sd15) == (896, 512))
}

@Test(arguments: AspectRatio.allCases, [ModelFamily.sd15, .sdxl])
func sizesFitTheFormat(_ format: AspectRatio, _ family: ModelFamily) {
    let (w, h) = format.size(for: family)
    #expect(w % 64 == 0 && h % 64 == 0)
    #expect((w > h) == (format.ratio > 1) || w == h)
    #expect(AspectRatio.matching(width: w, height: h) == format, "\(format.label) \(w)×\(h)")
    if family == .sdxl {
        #expect(abs(Double(w * h) / Double(1024 * 1024) - 1) < 0.15)
    }
}

@Test func otherSizesAreCustom() {
    #expect(AspectRatio.matching(width: 1000, height: 300) == nil)
    #expect(AspectRatio.matching(width: 0, height: 300) == nil)
    #expect(AspectRatio.matching(width: 1920, height: 1080) == .r16x9)
}

@Test func turnedSwapsTheSides() {
    #expect(AspectRatio.r3x2.turned == .r2x3)
    #expect(AspectRatio.square.turned == .square)
    #expect(AspectRatio.r9x21.turned == .r21x9)
}

@Test func canvasSizesUseAFinerStep() {
    let (w, h) = AspectRatio.r3x2.size(area: 1500 * 1000, step: 8)
    #expect(w % 8 == 0 && h % 8 == 0)
    #expect(abs(Double(w) / Double(h) - 1.5) < 0.02)
}

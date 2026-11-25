import ComfyKit
import Testing

@testable import LightboxUI

@Test func promptsAndPicturesAreLocked() {
    #expect(NodeRowText.isLocked(NodeRole(.positive), input: "text"))
    #expect(NodeRowText.isLocked(NodeRole(.negative), input: "text"))
    #expect(NodeRowText.isLocked(NodeRole(.guide, .image, key: "0"), input: "image"))
    #expect(NodeRowText.isLocked(NodeRole(.reference, .image, key: "0"), input: "image"))
    #expect(NodeRowText.isLocked(NodeRole(.inpaint, .mask), input: "image"))
    #expect(!NodeRowText.isLocked(NodeRole(.inpaint, .mask), input: "channel"))
    #expect(!NodeRowText.isLocked(NodeRole(.sampler), input: "steps"))
    #expect(!NodeRowText.isLocked(NodeRole(.guidance), input: "guidance"))
    #expect(!NodeRowText.isLocked(nil, input: "text"))
}

@Test func valuesReadAsInComfyUI() {
    #expect(NodeRowText.value(.double(0.35)) == "0.35")
    #expect(NodeRowText.value(.double(6)) == "6")
    #expect(NodeRowText.value(.double(0.123456)) == "0.123")
    #expect(NodeRowText.value(.double(-0.5)) == "-0.5")
    #expect(NodeRowText.value(.int(1024)) == "1024")
    #expect(NodeRowText.value(.bool(true)) == "true")
    #expect(NodeRowText.value(.string("euler")) == "euler")
    #expect(NodeRowText.value(nil) == "—")
}

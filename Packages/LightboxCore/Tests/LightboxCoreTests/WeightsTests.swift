import Testing

@testable import LightboxCore

// Ported from image-master `im-core/src/weights.rs`.

private func weights(_ text: String) -> [(String, Double)] {
    Weights.parse(text).map { s in
        switch s {
        case .text(let t, let w): (t, (w * 1000).rounded() / 1000)
        case .brk: ("BREAK", -1)
        }
    }
}

private func expectWeights(_ text: String, _ expected: [(String, Double)]) {
    let got = weights(text)
    #expect(got.map(\.0) == expected.map(\.0), "\(text)")
    #expect(got.map(\.1) == expected.map(\.1), "\(text)")
}

@Test func parsesLikeTheEngine() {
    expectWeights("normal text", [("normal text", 1.0)])
    #expect(weights("an (important) word")[1] == ("important", 1.1))
    expectWeights("(unnecessary)(parens)", [("unnecessaryparens", 1.1)])
    let w = weights("a (((house:1.3)) [on] a (hill:0.5), sun, (((sky))).")
    #expect(w[1] == ("house", 1.573))
    #expect(w[3] == ("on", 1.0))
    #expect(w[5] == ("hill", 0.55))
    #expect(w[7] == ("sky", 1.464))
    // Unmatched closers stay as text; unclosed openers weight the rest.
    expectWeights("a) b", [("a) b", 1.0)])
    expectWeights("a [[b", [("a ", 1.0), ("b", 0.826)])
}

@Test func canonicalBalancesClampsAndIsIdempotent() {
    #expect(Weights.canonical("red hair, (green eyes:1.3)") == "red hair, (green eyes:1.3)")
    #expect(Weights.canonical("((house))") == "(house:1.21)")
    #expect(Weights.canonical("(a:9), (b:-1), (c:.)") == "(a:2), (b:0.3), c")
    // A stray opener only affects its own fragment, and is closed.
    #expect(Weights.canonical("pretty [[[[[[ ugly") == "pretty (ugly:0.56)")
    #expect(Weights.canonical("a ) b ] c") == "a b c")
    #expect(Weights.canonical("(sun, sky:1.2)") == "(sun, sky:1.2)")
    #expect(Weights.canonical("a BREAK b") == "a BREAK b")
    for s in [
        "a (((house:1.3)) [on] a (hill:0.5), sun, (((sky))).",
        "x [[[[ y",
        "\\(literal\\) (w:1.25)",
    ] {
        let once = Weights.canonical(s)
        #expect(Weights.canonical(once) == once, "\(s)")
    }
}

@Test func emphasisMultipliesWithinTheSliderRange() {
    #expect(Weights.emphasize("cozy bedroom, bed", 1.3) == "(cozy bedroom, bed:1.3)")
    #expect(Weights.emphasize("(bed:1.2)", 1.5) == "(bed:1.8)")
    #expect(Weights.emphasize("bed", 9.0) == "(bed:1.5)")
    #expect(Weights.emphasize("bed", 1.0) == "bed")
}

@Test func fullWeightWords() {
    #expect(Weights.hasFullWeightWord("1girl, adult woman", "adult"))
    #expect(!Weights.hasFullWeightWord("1girl, (adult:0.5)", "adult"))
    #expect(Weights.hasFullWeightWord("(adult woman:1.2)", "adult"))
}

@Test func splitsTermsOutsideGroups() {
    #expect(Weights.splitTerms("a, (b, c:1.2), d") == ["a", " (b, c:1.2)", " d"])
}

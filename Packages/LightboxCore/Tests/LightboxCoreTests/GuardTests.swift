import Testing

@testable import LightboxCore

private func check(
    _ positive: String, negative: String = "", loras: [String] = [], rating: ContentRating = .mature
) -> Result<GuardResult, GuardError> {
    Result { () throws(GuardError) in
        try ContentGuard.check(GuardInput(positive: [positive], negative: [negative], loraNames: loras, rating: rating))
    }
}

@Test(arguments: [
    "a kid on a skateboard, sunny street",
    "two children building a sandcastle",
    "ein Kind mit einer Puppe auf der Wiese",
    "8-year-old boy reading a comic",
    "school uniform, classroom, raising hand",
    "teenager with headphones, bus stop",
    "baby in a stroller, park",
])
func childrenInNormalScenesPass(_ prompt: String) throws {
    let result = try check(prompt, rating: .allAges).get()
    #expect(result.minorSignal != nil, "should be seen as a minor: \(prompt)")
    #expect(result.forcedNegatives == ContentGuard.minorNegatives)
}

@Test func childPassesAndForcesSafetyNegatives() throws {
    let result = try check("a child playing in the garden", rating: .mature).get()
    #expect(result.minorSignal == "child")
    #expect(result.forcedNegatives.contains("nude"))
}

@Test(arguments: [
    "a kid, sexy pose",
    "little girl in lingerie",
    "teen, n.u.d.e",
    "Kind, nackt",
    "child, (naked:0.3)",
    "15yo, bikini",
    "aged 12, seductive look",
    "schoolgirl, see-through blouse",
    "kid, undressing",
])
func minorPlusSexualTermIsBlocked(_ prompt: String) {
    guard case .failure(.sexualWithMinor) = check(prompt, rating: .mature) else {
        Issue.record("should block: \(prompt)")
        return
    }
}

@Test func childWithSexualSceneIsBlocked() {
    guard case .failure(.sexualWithMinor(let term, _)) = check("a child, sexy pose") else {
        Issue.record("should block")
        return
    }
    #expect(term == "sexy")
}

@Test func sexualLoraNameWithChildIsBlocked() {
    let result = check("a child, standing", loras: ["nude_style_v2.safetensors"])
    guard case .failure(.sexualWithMinor(let term, _)) = result else {
        Issue.record("should block")
        return
    }
    #expect(term == "nude")
}

@Test func childLoraNameCountsAsMinorSignal() {
    guard case .failure(.sexualWithMinor) = check("lingerie", loras: ["kid_hero_v1.safetensors"]) else {
        Issue.record("should block")
        return
    }
}

@Test func negatedClothingWithMinorIsBlocked() {
    guard case .failure(.clothingNegatedWithMinor) = check("a child, standing", negative: "(clothes:1.5)")
    else {
        Issue.record("should block")
        return
    }
    // Without a minor, a negative like this is just a style choice.
    #expect((try? check("standing", negative: "shirt").get()) != nil)
}

@Test(arguments: ["loli", "l0li", "l o l i", "Sh-o-ta", "lolicon art", "jailbait"])
func alwaysBlockedTerms(_ prompt: String) {
    guard case .failure(.blocked) = check(prompt, rating: .mature) else {
        Issue.record("should block: \(prompt)")
        return
    }
}

@Test(arguments: [
    "apollo lighting, rocket launch",
    "lollipop shop",
    "a kind smile",
    "what kind of light",
    "minor details in the background",
    "baby blue sky",
    "18 years old woman",
    "aged 30, freckles",
    "comic strip, four panels",
    "shot a basketball",
])
func benignTextHasNoMinorAndIsNotBlocked(_ prompt: String) throws {
    let result = try check(prompt, rating: .allAges).get()
    #expect(result.minorSignal == nil, "\(prompt)")
}

@Test func ratingControlsSexualTermsForAdults() {
    if case .success = check("sexy pose", rating: .allAges) {
        Issue.record("all ages must block suggestive")
    }
    #expect((try? check("sexy pose", rating: .teen).get()) != nil)
    if case .success = check("nude", rating: .teen) {
        Issue.record("teen must block explicit")
    }
    #expect((try? check("nude", rating: .mature).get())?.forcedNegatives == [])
}

@Test func youngAges() {
    for text in ["8 years old", "15yo", "a 14 y/o", "aged 12", "16 Jahre alt", "17-jährige", "16jährige"] {
        #expect(ContentGuard.youngAge(in: text) != nil, "\(text)")
    }
    for text in ["18 years old", "25 yo", "aged 30", "4 panels", "2 years later", "3 years ago"] {
        #expect(ContentGuard.youngAge(in: text) == nil, "\(text)")
    }
}

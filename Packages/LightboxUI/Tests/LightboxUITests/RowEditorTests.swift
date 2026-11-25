import ComfyKit
import CoreGraphics
import Testing

@testable import LightboxUI

@Test func typedNumbersBecomeValues() {
    #expect(RowEdit.number(" 30 ", isInteger: true) == .int(30))
    #expect(RowEdit.number("29.6", isInteger: true) == .int(30))
    #expect(RowEdit.number("4,5", isInteger: false) == .double(4.5))
    #expect(RowEdit.number("abc", isInteger: false) == nil)
    #expect(RowEdit.number("", isInteger: true) == nil)
    #expect(RowEdit.number("inf", isInteger: false) == nil)
}

private func samplerTarget(_ input: String, control: Bool = false, role: NodeRole? = NodeRole(.sampler))
    -> RowEdit.Target?
{
    var n = node("KSampler", kSampler, at: .zero, size: CGSize(width: 320, height: 100))
    let values: [JSONValue] = [
        .int(7), .string("fixed"), .int(30), .double(5), .string("euler"), .string("normal"), .double(1),
    ]
    n.widgetsValues = .array(values)
    var catalog = ComfyCatalog()
    catalog.nodes["KSampler"] = kSampler
    let layout = NodeLayout(n, spec: kSampler)
    let kind: NodeLayout.Row.Kind = control ? .control : .value
    guard let row = layout.rows.first(where: { $0.name == input && $0.kind == kind }) else { return nil }
    let point = CGPoint(x: row.rect.midX, y: row.rect.midY)
    return RowEdit.target(n, layout, role: role, at: point, catalog: catalog)
}

@Test func editableRowsOpenTheirEditor() {
    let steps = samplerTarget("steps")
    #expect(steps?.kind == .number(isInteger: true))
    #expect(steps?.value == "30")
    #expect(samplerTarget("cfg")?.kind == .number(isInteger: false))
    let options: [String] = ["euler", "dpmpp_2m"]
    #expect(samplerTarget("sampler_name")?.kind == .choice(options))
    #expect(samplerTarget("seed")?.value == "7")
    // The seed's control row is not the seed.
    #expect(samplerTarget("seed", control: true) == nil)
    // Denoise stands for no setting of the form; nodes without a role are the user's.
    #expect(samplerTarget("denoise") == nil)
    #expect(samplerTarget("steps", role: nil) == nil)
}

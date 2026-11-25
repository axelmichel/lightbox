import CoreGraphics
import Testing

@testable import LightboxUI

@Test func fitCentresTheGraph() {
    let v = NodeViewport.fit(
        CGRect(x: 100, y: 50, width: 1000, height: 500), in: CGSize(width: 548, height: 548), margin: 24)
    #expect(v.scale == 0.5)
    #expect(v.toView(CGPoint(x: 100, y: 50)) == CGPoint(x: 24, y: 149))
    #expect(v.toView(CGPoint(x: 1100, y: 550)) == CGPoint(x: 524, y: 399))
    // Small graphs aren't blown up.
    #expect(NodeViewport.fit(CGRect(x: 0, y: 0, width: 10, height: 10), in: CGSize(width: 500, height: 500)).scale == 1)
}

@Test func zoomKeepsThePointUnderThePointer() {
    let v = NodeViewport(scale: 0.5, offset: CGPoint(x: 30, y: -20))
    let pointer = CGPoint(x: 200, y: 120)
    let under = v.toCanvas(pointer)
    let zoomed = v.zoomed(by: 2, around: pointer)
    #expect(zoomed.scale == 1)
    #expect(zoomed.toView(under) == pointer)
    #expect(zoomed.toCanvas(pointer) == under)
}

@Test func zoomStaysInItsRange() {
    let v = NodeViewport()
    #expect(v.zoomed(by: 100, around: .zero).scale == NodeViewport.scales.upperBound)
    #expect(v.zoomed(by: 0.001, around: .zero).scale == NodeViewport.scales.lowerBound)
    // At the limit, zooming further doesn't move the canvas.
    let top = v.zoomed(by: 100, around: CGPoint(x: 50, y: 50))
    #expect(top.zoomed(by: 2, around: CGPoint(x: 10, y: 10)) == top)
}

@Test func panMovesTheCanvas() {
    let v = NodeViewport(scale: 2, offset: CGPoint(x: 10, y: 10)).panned(by: CGSize(width: 5, height: -15))
    #expect(v == NodeViewport(scale: 2, offset: CGPoint(x: 15, y: -5)))
}

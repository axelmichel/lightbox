import Foundation
import Testing

@testable import LightboxCore

@Test func guidesAreAddedMovedAndRemoved() throws {
    var c = Composition(name: "C", width: 400, height: 300)
    #expect(c.guideLines.isEmpty)
    let id = c.addGuide(.vertical, at: 100)
    c.moveGuide(id, to: 120)
    #expect(c.guideLines == [CanvasGuide(id: id, axis: .vertical, position: 120)])
    // Saved with the composition; older files without guides still load.
    let data = try JSONEncoder.gallery.encode(c)
    #expect(try JSONDecoder.gallery.decode(Composition.self, from: data).guideLines.count == 1)
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    json["guides"] = nil
    let old = try JSONDecoder.gallery.decode(Composition.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.guideLines.isEmpty)
    c.removeGuide(id)
    #expect(c.guideLines.isEmpty)
}

@Test func targetsIncludeGuidesGridAndCanvasEdges() {
    var c = Composition(name: "C", width: 400, height: 300)
    c.addGuide(.vertical, at: 100)
    c.addGuide(.horizontal, at: 50)
    let t = c.snapTargets(grid: nil, guides: true)
    #expect(t.xs == [100, 0, 200, 400])
    #expect(t.ys == [50, 0, 150, 300])
    #expect(c.snapTargets(grid: nil, guides: false).isEmpty)
    let grid = c.snapTargets(grid: 32, guides: false)
    #expect(grid.grid == 32 && grid.xs == [0, 200, 400])
}

@Test func movingSnapsTheClosestEdgeOrCenter() {
    let targets = SnapTargets(xs: [100], ys: [200])
    // Left edge 97 → 100.
    var s = Snapping.move(ImageFrame(x: 97, y: 0, width: 50, height: 50), to: targets, threshold: 5)
    #expect(s.frame.x == 100 && s.x == 100 && s.y == nil)
    // Right edge 103 → 100.
    s = Snapping.move(ImageFrame(x: 53, y: 0, width: 50, height: 50), to: targets, threshold: 5)
    #expect(s.frame.x == 50)
    // Center 198 → 200 on y.
    s = Snapping.move(ImageFrame(x: 0, y: 173, width: 50, height: 50), to: targets, threshold: 5)
    #expect(s.frame.y == 175 && s.y == 200)
    // Too far away: unchanged.
    s = Snapping.move(ImageFrame(x: 10, y: 10, width: 50, height: 50), to: targets, threshold: 5)
    #expect(s.frame == ImageFrame(x: 10, y: 10, width: 50, height: 50) && s.x == nil)
}

@Test func gridSnapsToTheNearestLine() {
    let targets = SnapTargets(grid: 32)
    let s = Snapping.move(ImageFrame(x: 30, y: 70, width: 10, height: 10), to: targets, threshold: 4)
    #expect(s.frame.x == 32)  // left edge 30 → 32
    #expect(s.frame.y == 70)  // 70 is 6 from 64: too far; bottom 80 is 16 from 96, center 75 is 11
    let p = Snapping.point(63, 10, to: targets, threshold: 4)
    #expect(p.x == 64 && p.lineX == 64 && p.y == 10 && p.lineY == nil)
}

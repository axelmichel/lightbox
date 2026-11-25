import ComfyKit
import CoreGraphics
import Testing

@testable import LightboxUI

private func doc() -> WorkflowDocument {
    var d = WorkflowDocument()
    for (id, x) in [(1, 0.0), (2, 100.0), (3, 600.0)] {
        d.graph.nodes.append(GraphNode(id: id, type: "Test", position: CGPoint(x: x, y: 50)))
    }
    return d
}

@Test func theNodeOnTopIsHit() {
    let d = doc()
    let layouts = Dictionary(uniqueKeysWithValues: d.graph.nodes.map { ($0.id, NodeLayout($0, spec: nil)) })
    // 1 and 2 overlap (320 wide); 2 is drawn later.
    #expect(NodeEditing.node(at: CGPoint(x: 150, y: 60), in: d.graph.nodes, layouts: layouts) == 2)
    #expect(NodeEditing.node(at: CGPoint(x: 50, y: 30), in: d.graph.nodes, layouts: layouts) == 1)  // title
    #expect(NodeEditing.node(at: CGPoint(x: 500, y: 60), in: d.graph.nodes, layouts: layouts) == nil)
}

@Test func clicksSelect() {
    #expect(NodeEditing.select(2, in: [1, 3], extend: false) == [2])
    #expect(NodeEditing.select(2, in: [1, 3], extend: true) == [1, 2, 3])
    #expect(NodeEditing.select(3, in: [1, 3], extend: true) == [1])
    #expect(NodeEditing.select(nil, in: [1, 3], extend: false) == [])
    #expect(NodeEditing.select(nil, in: [1, 3], extend: true) == [1, 3])
}

@Test func dragsMoveTheSelectionOrOneNode() {
    #expect(NodeEditing.dragged(1, selection: [1, 2]) == [1, 2])
    #expect(NodeEditing.dragged(3, selection: [1, 2]) == [3])
    let moved = NodeEditing.moved(doc(), [1, 3], by: CGSize(width: 10.4, height: -20.6))
    #expect(
        moved.graph.nodes.map(\.position) == [
            CGPoint(x: 10, y: 29), CGPoint(x: 100, y: 50), CGPoint(x: 610, y: 29),
        ])
}

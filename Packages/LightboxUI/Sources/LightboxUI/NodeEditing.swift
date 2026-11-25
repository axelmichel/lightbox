import ComfyKit
import CoreGraphics

/// Selecting and moving nodes in the graph view, without the view.
enum NodeEditing {
    /// The node at `point` (canvas units); the one drawn last is on top.
    static func node(at point: CGPoint, in nodes: [GraphNode], layouts: [Int: NodeLayout]) -> Int? {
        nodes.last { layouts[$0.id]?.bounds.contains(point) == true }?.id
    }

    /// The selection after a click on `node` (`nil`: the background).
    /// `extend` (⇧ or ⌘) adds the node, or takes it out again.
    static func select(_ node: Int?, in selection: Set<Int>, extend: Bool) -> Set<Int> {
        guard let node else { return extend ? selection : [] }
        guard extend else { return [node] }
        return selection.symmetricDifference([node])
    }

    /// What a drag that starts on `node` moves: the selection if the node
    /// is in it, else the node alone.
    static func dragged(_ node: Int, selection: Set<Int>) -> Set<Int> {
        selection.contains(node) ? selection : [node]
    }

    /// `doc` with `nodes` moved by `delta` (canvas units), on whole points.
    static func moved(_ doc: WorkflowDocument, _ nodes: Set<Int>, by delta: CGSize) -> WorkflowDocument {
        var d = doc
        for i in d.graph.nodes.indices where nodes.contains(d.graph.nodes[i].id) {
            d.graph.nodes[i].position.x = (d.graph.nodes[i].position.x + delta.width).rounded()
            d.graph.nodes[i].position.y = (d.graph.nodes[i].position.y + delta.height).rounded()
        }
        return d
    }
}

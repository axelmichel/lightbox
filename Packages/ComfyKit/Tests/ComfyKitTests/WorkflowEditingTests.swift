import CoreGraphics
import Foundation
import Testing

@testable import ComfyKit

/// A node with one output linked into one with one input: link 1.
private func twoNodes() -> NodeGraph {
    var g = NodeGraph()
    var a = GraphNode(id: 1, type: "A", position: .zero)
    a.outputs = [NodeOutputSlot(name: "IMAGE", type: "IMAGE", links: [])]
    var b = GraphNode(id: 2, type: "B", position: CGPoint(x: 600, y: 0))
    b.inputs = [NodeInputSlot(name: "images", type: "IMAGE", link: nil)]
    g.nodes = [a, b]
    g.lastNodeID = 2
    _ = g.connect(from: 1, 0, to: 2, 0)
    return g
}

@Test func reroutesAreAddedWhereTheLinkWasClicked() throws {
    var g = twoNodes()
    let firstAdded = g.addReroute(on: 1, segment: 0, at: CGPoint(x: 200, y: 0))
    let first = try #require(firstAdded)
    #expect(g.rerouteChain(of: 1) == [first])
    // After the first, toward the input.
    let lastAdded = g.addReroute(on: 1, segment: 1, at: CGPoint(x: 400, y: 0))
    let last = try #require(lastAdded)
    #expect(g.rerouteChain(of: 1) == [first, last])
    // Before the first, next to the output.
    let startAdded = g.addReroute(on: 1, segment: 0, at: CGPoint(x: 100, y: 0))
    let start = try #require(startAdded)
    #expect(g.rerouteChain(of: 1) == [start, first, last])
    #expect(g.reroutes.allSatisfy { $0.linkIDs == [1] })
    let pastTheEnd = g.addReroute(on: 1, segment: 9, at: .zero)
    let noLink = g.addReroute(on: 7, segment: 0, at: .zero)
    #expect(pastTheEnd == nil && noLink == nil)

    g.removeReroute(first)
    #expect(g.rerouteChain(of: 1) == [start, last])
    g.removeReroute(last)
    #expect(g.rerouteChain(of: 1) == [start])
    #expect(g.link(1)?.parentReroute == start)
}

@Test func aRerouteSharedByLinksStaysOnAllOfThem() throws {
    var g = twoNodes()
    var c = GraphNode(id: 3, type: "B", position: CGPoint(x: 600, y: 200))
    c.inputs = [NodeInputSlot(name: "images", type: "IMAGE", link: nil)]
    g.nodes.append(c)
    _ = g.connect(from: 1, 0, to: 3, 0)
    let sharedAdded = g.addReroute(on: 1, segment: 0, at: CGPoint(x: 300, y: 100))
    let shared = try #require(sharedAdded)
    // The second link branches off the same reroute.
    g.links[1].parentReroute = shared
    g.reroutes[0].linkIDs = [1, 2]
    let beforeAdded = g.addReroute(on: 1, segment: 0, at: CGPoint(x: 150, y: 50))
    let before = try #require(beforeAdded)
    #expect(g.rerouteChain(of: 1) == [before, shared])
    #expect(g.rerouteChain(of: 2) == [before, shared])
    #expect(g.reroutes.first { $0.id == before }?.linkIDs == [1, 2])
}

@Test(arguments: [WorkflowDocument.Schema.v04, .v1])
func addedReroutesAreWrittenForComfyUI(_ schema: WorkflowDocument.Schema) throws {
    var doc = WorkflowDocument()
    doc.schema = schema
    doc.graph = twoNodes()
    let aAdded = doc.graph.addReroute(on: 1, segment: 0, at: CGPoint(x: 200, y: 10))
    let a = try #require(aAdded)
    let bAdded = doc.graph.addReroute(on: 1, segment: 1, at: CGPoint(x: 400, y: 20))
    let b = try #require(bAdded)
    let read = try WorkflowDocument(data: doc.data())
    #expect(read.graph.rerouteChain(of: 1) == [a, b])
    #expect(read.graph.reroutes.map(\.position) == [CGPoint(x: 200, y: 10), CGPoint(x: 400, y: 20)])
    #expect(read.graph.lastRerouteID == b)
}

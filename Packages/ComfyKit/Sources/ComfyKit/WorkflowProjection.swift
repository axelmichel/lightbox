// A standard graph as a document for the node editor: the nodes of
// `WorkflowBuilder.build`, laid out by `ApiLayout`, with each node's role
// in its properties so it survives a save and a trip through ComfyUI.

import Foundation

extension WorkflowDocument {
    /// The property a node's role is written to.
    public static let roleProperty = "lightbox_role"

    /// The document of a built graph. Node ids stay those of the API graph.
    public init(_ built: BuiltWorkflow, catalog: ComfyCatalog) throws(WorkflowDocumentError) {
        let data: Data
        do { data = try built.graph.jsonData() } catch { throw .notAWorkflow }
        try self.init(api: data, catalog: catalog)
        for i in graph.nodes.indices {
            guard let role = built.roles[String(graph.nodes[i].id)] else { continue }
            graph.nodes[i].properties[Self.roleProperty] = .string(role.description)
        }
    }

    /// The roles of the root graph's nodes, by node id. Nodes without one
    /// were added by the user.
    public var roles: [Int: NodeRole] {
        var roles: [Int: NodeRole] = [:]
        for n in graph.nodes {
            if let text = n.properties[Self.roleProperty]?.string, let role = NodeRole(text) { roles[n.id] = role }
        }
        return roles
    }
}

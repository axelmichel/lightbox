// ComfyUI's UI workflow format (what "Save" writes), for the node editor.
//
// Two schemas are read and written back in the one they came in:
// - 0.4: "links" are arrays [id, from, fromSlot, to, toSlot, type], native
//   reroutes are in extra.reroutes and extra.linkExtensions;
// - 1: "links" are objects, "state" holds the last ids, "reroutes" is top
//   level.
// Subgraphs ("definitions.subgraphs") have the same parts as the root
// graph. Fields not listed here are kept in `extra` and written back
// unchanged, so files from newer frontends and custom nodes survive a save.

import CoreGraphics
import Foundation

public enum WorkflowDocumentError: Error, Equatable, Sendable, CustomStringConvertible {
    case notJSON
    case notAWorkflow

    public var description: String {
        switch self {
        case .notJSON: "The file isn't JSON."
        case .notAWorkflow: "The file isn't a ComfyUI workflow."
        }
    }
}

/// What a node does when the workflow runs.
public enum NodeMode: Int, Equatable, Hashable, Sendable {
    case always = 0
    case onEvent = 1
    /// Muted: never runs; what depends on it doesn't run either.
    case never = 2
    case onTrigger = 3
    /// Bypassed: passes its inputs on to its outputs of the same type.
    case bypass = 4
}

public struct NodeInputSlot: Equatable, Sendable {
    public var name: String
    public var type: String
    public var link: Int?
    /// A widget that is also a socket: a link here replaces the widget's value.
    public var widget: String?
    public var label: String?
    public var extra: [String: JSONValue] = [:]

    public init(name: String, type: String, link: Int? = nil, widget: String? = nil) {
        self.name = name
        self.type = type
        self.link = link
        self.widget = widget
    }
}

public struct NodeOutputSlot: Equatable, Sendable {
    public var name: String
    public var type: String
    public var links: [Int] = []
    public var label: String?
    public var extra: [String: JSONValue] = [:]

    public init(name: String, type: String, links: [Int] = []) {
        self.name = name
        self.type = type
        self.links = links
    }
}

public struct GraphNode: Equatable, Identifiable, Sendable {
    public var id: Int
    /// The node class, or a subgraph's id for a subgraph node.
    public var type: String
    public var position: CGPoint
    public var size: CGSize
    public var mode: NodeMode = .always
    public var title: String?
    public var color: String?
    public var bgcolor: String?
    public var collapsed = false
    public var pinned = false
    public var inputs: [NodeInputSlot] = []
    public var outputs: [NodeOutputSlot] = []
    public var properties: [String: JSONValue] = [:]
    /// Usually a list in widget order (see `WidgetLayout`); some custom
    /// nodes store an object by name.
    public var widgetsValues: JSONValue?
    /// Other node fields ("order", "shape", …) and other flags.
    public var extra: [String: JSONValue] = [:]
    public var flagsExtra: [String: JSONValue] = [:]

    public init(id: Int, type: String, position: CGPoint = .zero, size: CGSize = CGSize(width: 320, height: 120)) {
        self.id = id
        self.type = type
        self.position = position
        self.size = size
    }

    public var frame: CGRect { CGRect(origin: position, size: size) }
}

public struct GraphLink: Equatable, Identifiable, Sendable {
    public var id: Int
    public var origin: Int
    public var originSlot: Int
    public var target: Int
    public var targetSlot: Int
    public var type: String
    /// The last native reroute on its way (schema 1, or extra.linkExtensions).
    public var parentReroute: Int?
    public var extra: [String: JSONValue] = [:]

    public init(id: Int, origin: Int, originSlot: Int, target: Int, targetSlot: Int, type: String) {
        self.id = id
        self.origin = origin
        self.originSlot = originSlot
        self.target = target
        self.targetSlot = targetSlot
        self.type = type
    }

    /// Inside a subgraph: links from its inputs start at this node id,
    /// links to its outputs end at `subgraphOutputID`.
    public static let subgraphInputID = -10
    public static let subgraphOutputID = -20
}

public struct GraphGroup: Equatable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var frame: CGRect
    public var color: String?
    public var fontSize: Double?
    public var extra: [String: JSONValue] = [:]

    public init(id: Int, title: String, frame: CGRect) {
        self.id = id
        self.title = title
        self.frame = frame
    }
}

/// A native reroute: a point links pass through.
public struct GraphReroute: Equatable, Identifiable, Sendable {
    public var id: Int
    public var position: CGPoint
    public var parent: Int?
    public var linkIDs: [Int] = []
    public var extra: [String: JSONValue] = [:]

    public init(id: Int, position: CGPoint) {
        self.id = id
        self.position = position
    }
}

/// Nodes, links, groups and reroutes: the root graph or a subgraph's.
public struct NodeGraph: Equatable, Sendable {
    public var nodes: [GraphNode] = []
    public var links: [GraphLink] = []
    public var groups: [GraphGroup] = []
    public var reroutes: [GraphReroute] = []
    public var lastNodeID = 0
    public var lastLinkID = 0
    public var lastGroupID = 0
    public var lastRerouteID = 0

    public init() {}

    public func node(_ id: Int) -> GraphNode? { nodes.first { $0.id == id } }
    public func link(_ id: Int) -> GraphLink? { links.first { $0.id == id } }
    public func index(of node: Int) -> Int? { nodes.firstIndex { $0.id == node } }
}

/// An input or output of a subgraph.
public struct SubgraphSlot: Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var linkIDs: [Int] = []
    public var extra: [String: JSONValue] = [:]
}

public struct SubgraphDefinition: Equatable, Identifiable, Sendable {
    /// A UUID; nodes using the subgraph have it as their `type`.
    public var id: String
    public var name: String
    public var graph: NodeGraph
    public var inputs: [SubgraphSlot] = []
    public var outputs: [SubgraphSlot] = []
    public var extra: [String: JSONValue] = [:]
}

public struct WorkflowDocument: Equatable, Sendable {
    public enum Schema: Equatable, Sendable {
        case v04
        case v1
    }

    public var schema: Schema = .v04
    public var graph = NodeGraph()
    public var subgraphs: [SubgraphDefinition] = []
    /// The editor's zoom and scroll (extra.ds).
    public var scale = 1.0
    public var offset = CGPoint.zero
    /// Other top-level fields ("id", "config", "extra", …).
    public var extra: [String: JSONValue] = [:]

    public init() {
        extra["config"] = .object([:])
        extra["extra"] = .object([:])
    }

    public func subgraph(_ id: String) -> SubgraphDefinition? { subgraphs.first { $0.id == id } }

    // MARK: - Reading

    /// Read a UI-format file. API-format files are read with `WorkflowDocument(api:catalog:)`.
    public init(data: Data) throws(WorkflowDocumentError) {
        guard let json = JSONValue.parse(data) else { throw .notJSON }
        try self.init(json: json)
    }

    public init(json: JSONValue) throws(WorkflowDocumentError) {
        guard var root = json.object else { throw .notAWorkflow }
        // Some tools wrap it: {"workflow": {...}}.
        if root["nodes"] == nil, let inner = root["workflow"]?.object, inner["nodes"] != nil { root = inner }
        guard root["nodes"]?.array != nil else { throw .notAWorkflow }
        schema = (root["version"]?.double ?? 0.4) >= 1 ? .v1 : .v04
        var rest = root
        for key in ["nodes", "links", "groups", "reroutes", "state", "last_node_id", "last_link_id", "version"] {
            rest[key] = nil
        }
        var extraObject = rest["extra"]?.object ?? [:]
        if let ds = extraObject["ds"]?.object {
            scale = ds["scale"]?.double ?? 1
            offset = Self.point(ds["offset"]) ?? .zero
            extraObject["ds"] = nil
        }
        // 0.4 keeps native reroutes in extra.
        var reroutes = root["reroutes"]
        var linkExtensions: [JSONValue] = []
        if schema == .v04 {
            reroutes = extraObject["reroutes"]
            linkExtensions = extraObject["linkExtensions"]?.array ?? []
            extraObject["reroutes"] = nil
            extraObject["linkExtensions"] = nil
        }
        rest["extra"] = .object(extraObject)
        graph = Self.graph(root, reroutes: reroutes, linkExtensions: linkExtensions)
        if var definitions = rest["definitions"]?.object {
            subgraphs = (definitions["subgraphs"]?.array ?? []).compactMap(Self.subgraph)
            definitions["subgraphs"] = nil
            rest["definitions"] = definitions.isEmpty ? nil : .object(definitions)
        }
        extra = rest
    }

    static func graph(_ o: [String: JSONValue], reroutes: JSONValue?, linkExtensions: [JSONValue]) -> NodeGraph {
        var g = NodeGraph()
        g.nodes = (o["nodes"]?.array ?? []).compactMap(node)
        g.links = (o["links"]?.array ?? []).compactMap(link)
        for ext in linkExtensions {
            guard let id = ext["id"]?.int, let i = g.links.firstIndex(where: { $0.id == id }) else { continue }
            g.links[i].parentReroute = ext["parentId"]?.int
        }
        g.groups = (o["groups"]?.array ?? []).enumerated().compactMap { group($1, index: $0) }
        g.reroutes = (reroutes?.array ?? []).compactMap(reroute)
        let state = o["state"]?.object ?? [:]
        g.lastNodeID = max(o["last_node_id"]?.int ?? state["lastNodeId"]?.int ?? 0, g.nodes.map(\.id).max() ?? 0)
        g.lastLinkID = max(o["last_link_id"]?.int ?? state["lastLinkId"]?.int ?? 0, g.links.map(\.id).max() ?? 0)
        g.lastGroupID = max(state["lastGroupId"]?.int ?? 0, g.groups.map(\.id).max() ?? 0)
        g.lastRerouteID = max(state["lastRerouteId"]?.int ?? 0, g.reroutes.map(\.id).max() ?? 0)
        return g
    }

    static func node(_ v: JSONValue) -> GraphNode? {
        guard var o = v.object, let id = o["id"]?.int, let type = o["type"]?.string else { return nil }
        var n = GraphNode(
            id: id, type: type, position: point(o["pos"]) ?? .zero,
            size: size(o["size"]) ?? CGSize(width: 320, height: 120))
        n.mode = NodeMode(rawValue: o["mode"]?.int ?? 0) ?? .always
        n.title = o["title"]?.string
        n.color = o["color"]?.string
        n.bgcolor = o["bgcolor"]?.string
        var flags = o["flags"]?.object ?? [:]
        n.collapsed = flags["collapsed"]?.bool ?? false
        n.pinned = flags["pinned"]?.bool ?? false
        flags["collapsed"] = nil
        flags["pinned"] = nil
        n.flagsExtra = flags
        n.inputs = (o["inputs"]?.array ?? []).compactMap { raw in
            guard var i = raw.object, let name = i["name"]?.string else { return nil }
            var slot = NodeInputSlot(
                name: name, type: typeName(i["type"]), link: i["link"]?.int, widget: i["widget"]?["name"]?.string)
            slot.label = i["label"]?.string
            for key in ["name", "type", "link", "widget", "label"] { i[key] = nil }
            // Keep the widget object's other fields.
            if var w = raw["widget"]?.object {
                w["name"] = nil
                if !w.isEmpty { i["widget_extra"] = .object(w) }
            }
            slot.extra = i
            return slot
        }
        n.outputs = (o["outputs"]?.array ?? []).compactMap { raw in
            guard var out = raw.object, let name = out["name"]?.string else { return nil }
            var slot = NodeOutputSlot(
                name: name, type: typeName(out["type"]), links: out["links"]?.array?.compactMap(\.int) ?? [])
            slot.label = out["label"]?.string
            for key in ["name", "type", "links", "label"] { out[key] = nil }
            slot.extra = out
            return slot
        }
        n.properties = o["properties"]?.object ?? [:]
        n.widgetsValues = o["widgets_values"]
        for key in [
            "id", "type", "pos", "size", "mode", "title", "color", "bgcolor", "flags", "inputs", "outputs",
            "properties", "widgets_values",
        ] {
            o[key] = nil
        }
        n.extra = o
        return n
    }

    /// Types are strings, or 0/-1 for "any" in some files.
    static func typeName(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: s
        case .int(let i)? where i <= 0: "*"
        default: "*"
        }
    }

    static func link(_ v: JSONValue) -> GraphLink? {
        if let a = v.array, a.count >= 6, let id = a[0].int, let from = a[1].int, let fromSlot = a[2].int,
            let to = a[3].int, let toSlot = a[4].int
        {
            return GraphLink(
                id: id, origin: from, originSlot: fromSlot, target: to, targetSlot: toSlot, type: typeName(a[5]))
        }
        guard var o = v.object, let id = o["id"]?.int, let from = o["origin_id"]?.int,
            let fromSlot = o["origin_slot"]?.int, let to = o["target_id"]?.int, let toSlot = o["target_slot"]?.int
        else { return nil }
        var l = GraphLink(
            id: id, origin: from, originSlot: fromSlot, target: to, targetSlot: toSlot, type: typeName(o["type"]))
        l.parentReroute = o["parentId"]?.int
        for key in ["id", "origin_id", "origin_slot", "target_id", "target_slot", "type", "parentId"] { o[key] = nil }
        l.extra = o
        return l
    }

    static func group(_ v: JSONValue, index: Int) -> GraphGroup? {
        guard var o = v.object, let b = o["bounding"]?.array?.compactMap(\.double), b.count == 4 else { return nil }
        var g = GraphGroup(
            id: o["id"]?.int ?? index + 1, title: o["title"]?.string ?? "Group",
            frame: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]))
        g.color = o["color"]?.string
        g.fontSize = o["font_size"]?.double
        for key in ["id", "title", "bounding", "color", "font_size"] { o[key] = nil }
        g.extra = o
        return g
    }

    static func reroute(_ v: JSONValue) -> GraphReroute? {
        guard var o = v.object, let id = o["id"]?.int, let pos = point(o["pos"]) else { return nil }
        var r = GraphReroute(id: id, position: pos)
        r.parent = o["parentId"]?.int
        r.linkIDs = o["linkIds"]?.array?.compactMap(\.int) ?? []
        for key in ["id", "pos", "parentId", "linkIds"] { o[key] = nil }
        r.extra = o
        return r
    }

    static func subgraph(_ v: JSONValue) -> SubgraphDefinition? {
        guard var o = v.object, let id = o["id"]?.string else { return nil }
        func slots(_ key: String) -> [SubgraphSlot] {
            (o[key]?.array ?? []).enumerated().compactMap { i, raw in
                guard var s = raw.object else { return nil }
                var slot = SubgraphSlot(
                    id: s["id"]?.string ?? "\(key)\(i)", name: s["name"]?.string ?? "", type: typeName(s["type"]),
                    linkIDs: s["linkIds"]?.array?.compactMap(\.int) ?? [])
                for key in ["id", "name", "type", "linkIds"] { s[key] = nil }
                slot.extra = s
                return slot
            }
        }
        let def = SubgraphDefinition(
            id: id, name: o["name"]?.string ?? "Subgraph", graph: graph(o, reroutes: o["reroutes"], linkExtensions: []),
            inputs: slots("inputs"), outputs: slots("outputs"))
        for key in ["id", "name", "nodes", "links", "groups", "reroutes", "state", "inputs", "outputs"] { o[key] = nil }
        var d = def
        d.extra = o
        return d
    }

    static func point(_ v: JSONValue?) -> CGPoint? {
        if let a = v?.array?.compactMap(\.double), a.count >= 2 { return CGPoint(x: a[0], y: a[1]) }
        // Some old files store {"0": x, "1": y}.
        if let o = v?.object, let x = o["0"]?.double, let y = o["1"]?.double { return CGPoint(x: x, y: y) }
        return nil
    }

    static func size(_ v: JSONValue?) -> CGSize? {
        point(v).map { CGSize(width: $0.x, height: $0.y) }
    }

    // MARK: - Writing

    public func json() -> JSONValue {
        var root = extra
        var extraObject = root["extra"]?.object ?? [:]
        extraObject["ds"] = .object(["scale": .double(scale), "offset": Self.pair(offset.x, offset.y)])
        var g = Self.write(graph, schema: schema)
        if schema == .v04 {
            if !graph.reroutes.isEmpty { extraObject["reroutes"] = g["reroutes"] }
            let ext = graph.links.compactMap { l in
                l.parentReroute.map { JSONValue.object(["id": .int(l.id), "parentId": .int($0)]) }
            }
            if !ext.isEmpty { extraObject["linkExtensions"] = .array(ext) }
            g["reroutes"] = nil
            g["last_node_id"] = .int(graph.lastNodeID)
            g["last_link_id"] = .int(graph.lastLinkID)
            g["state"] = nil
            root["version"] = .double(0.4)
        } else {
            root["version"] = .int(1)
        }
        root["extra"] = .object(extraObject)
        for (k, v) in g { root[k] = v }
        if !subgraphs.isEmpty {
            var definitions = root["definitions"]?.object ?? [:]
            definitions["subgraphs"] = .array(subgraphs.map(Self.write))
            root["definitions"] = .object(definitions)
        }
        return .object(root)
    }

    public func data() throws -> Data { try json().data(pretty: true) }

    static func pair(_ a: Double, _ b: Double) -> JSONValue { .array([number(a), number(b)]) }

    /// Whole numbers as ints, as the frontend writes most of them.
    static func number(_ d: Double) -> JSONValue {
        d.rounded() == d && abs(d) < 1e15 ? .int(Int(d)) : .double(d)
    }

    static func write(_ g: NodeGraph, schema: Schema) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        o["nodes"] = .array(g.nodes.map(write))
        o["links"] = .array(g.links.map { write($0, schema: schema) })
        o["groups"] = .array(g.groups.map(write))
        o["reroutes"] = .array(g.reroutes.map(write))
        o["state"] = .object([
            "lastNodeId": .int(g.lastNodeID), "lastLinkId": .int(g.lastLinkID), "lastGroupId": .int(g.lastGroupID),
            "lastRerouteId": .int(g.lastRerouteID),
        ])
        if schema == .v1, g.reroutes.isEmpty { o["reroutes"] = nil }
        return o
    }

    static func write(_ n: GraphNode) -> JSONValue {
        var o = n.extra
        o["id"] = .int(n.id)
        o["type"] = .string(n.type)
        o["pos"] = pair(n.position.x, n.position.y)
        o["size"] = pair(n.size.width, n.size.height)
        var flags = n.flagsExtra
        if n.collapsed { flags["collapsed"] = .bool(true) }
        if n.pinned { flags["pinned"] = .bool(true) }
        o["flags"] = .object(flags)
        o["mode"] = .int(n.mode.rawValue)
        if let t = n.title { o["title"] = .string(t) }
        if let c = n.color { o["color"] = .string(c) }
        if let c = n.bgcolor { o["bgcolor"] = .string(c) }
        o["inputs"] = .array(
            n.inputs.map { s in
                var i = s.extra
                let widgetExtra = i["widget_extra"]?.object ?? [:]
                i["widget_extra"] = nil
                i["name"] = .string(s.name)
                i["type"] = .string(s.type)
                i["link"] = s.link.map(JSONValue.int) ?? .null
                if let w = s.widget { i["widget"] = .object(widgetExtra.merging(["name": .string(w)]) { $1 }) }
                if let l = s.label { i["label"] = .string(l) }
                return .object(i)
            })
        o["outputs"] = .array(
            n.outputs.map { s in
                var out = s.extra
                out["name"] = .string(s.name)
                out["type"] = .string(s.type)
                out["links"] = s.links.isEmpty ? .null : .array(s.links.map(JSONValue.int))
                if let l = s.label { out["label"] = .string(l) }
                return .object(out)
            })
        o["properties"] = .object(n.properties)
        if let w = n.widgetsValues { o["widgets_values"] = w }
        return .object(o)
    }

    static func write(_ l: GraphLink, schema: Schema) -> JSONValue {
        switch schema {
        case .v04:
            return .array([
                .int(l.id), .int(l.origin), .int(l.originSlot), .int(l.target), .int(l.targetSlot), .string(l.type),
            ])
        case .v1:
            var o = l.extra
            o["id"] = .int(l.id)
            o["origin_id"] = .int(l.origin)
            o["origin_slot"] = .int(l.originSlot)
            o["target_id"] = .int(l.target)
            o["target_slot"] = .int(l.targetSlot)
            o["type"] = .string(l.type)
            if let p = l.parentReroute { o["parentId"] = .int(p) }
            return .object(o)
        }
    }

    static func write(_ g: GraphGroup) -> JSONValue {
        var o = g.extra
        o["id"] = .int(g.id)
        o["title"] = .string(g.title)
        o["bounding"] = .array(
            [g.frame.minX, g.frame.minY, g.frame.width, g.frame.height].map(number))
        if let c = g.color { o["color"] = .string(c) }
        if let f = g.fontSize { o["font_size"] = number(f) }
        return .object(o)
    }

    static func write(_ r: GraphReroute) -> JSONValue {
        var o = r.extra
        o["id"] = .int(r.id)
        o["pos"] = pair(r.position.x, r.position.y)
        if let p = r.parent { o["parentId"] = .int(p) }
        o["linkIds"] = .array(r.linkIDs.map(JSONValue.int))
        return .object(o)
    }

    static func write(_ s: SubgraphDefinition) -> JSONValue {
        var o = s.extra
        o["id"] = .string(s.id)
        o["name"] = .string(s.name)
        for (k, v) in write(s.graph, schema: .v1) { o[k] = v }
        func slots(_ list: [SubgraphSlot]) -> JSONValue {
            .array(
                list.map { slot in
                    var x = slot.extra
                    x["id"] = .string(slot.id)
                    x["name"] = .string(slot.name)
                    x["type"] = .string(slot.type)
                    x["linkIds"] = .array(slot.linkIDs.map(JSONValue.int))
                    return .object(x)
                })
        }
        o["inputs"] = slots(s.inputs)
        o["outputs"] = slots(s.outputs)
        return .object(o)
    }
}

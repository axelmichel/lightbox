import Foundation

/// Any JSON value. Workflow files keep fields Lightbox doesn't know in
/// these, so they are written back unchanged.
public enum JSONValue: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// From `JSONSerialization` output.
    public init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) || n.compare(NSNumber(value: Int.max)) == .orderedDescending {
                // Also past Int's range: the largest seeds are UInt64.max.
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let a as [Any]: self = .array(a.map { JSONValue($0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue($0) })
        default: self = .null
        }
    }

    /// For `JSONSerialization`.
    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    public static func parse(_ data: Data) -> JSONValue? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).map { JSONValue($0) }
    }

    public func data(pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
        return try JSONSerialization.data(withJSONObject: any, options: options)
    }

    public var string: String? {
        if case .string(let s) = self { s } else { nil }
    }
    public var int: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d && abs(d) < 9e18: Int(d)
        default: nil
        }
    }
    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
    public var bool: Bool? {
        if case .bool(let b) = self { b } else { nil }
    }
    public var array: [JSONValue]? {
        if case .array(let a) = self { a } else { nil }
    }
    public var object: [String: JSONValue]? {
        if case .object(let o) = self { o } else { nil }
    }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }
}

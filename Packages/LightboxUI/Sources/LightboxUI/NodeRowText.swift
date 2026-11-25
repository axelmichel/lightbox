import ComfyKit

/// What a widget row of the node graph says, and whether it is locked.
enum NodeRowText {
    /// Rows the configurator keeps for itself, even in a workflow changed
    /// in the graph: the prompt texts and the pictures.
    static func isLocked(_ role: NodeRole?, input: String) -> Bool {
        guard let role else { return false }
        switch (role.kind, role.part) {
        case (.positive, nil), (.negative, nil): return input == "text"
        case (_, .image?), (_, .mask?): return input == "image"
        default: return false
        }
    }

    /// A value as ComfyUI shows it: numbers with a point and at most three
    /// decimals, whole numbers without.
    static func value(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?:
            let r = (d * 1000).rounded() / 1000
            return r == r.rounded() && abs(r) < 1e15 ? String(Int(r)) : String(r)
        case .bool(let b)?: return b ? "true" : "false"
        case .array?, .object?: return "…"
        case .null?, nil: return "—"
        }
    }
}

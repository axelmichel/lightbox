// Which value in a node's `widgets_values` belongs to which input.
//
// The UI format stores widget values as a list without names, in the order
// the frontend creates the widgets: the node's value inputs as
// `/object_info` lists them (required, then optional), skipping sockets
// and `forceInput` ones. Two inputs add a widget of their own after them:
// a seed (`control_after_generate`) adds "fixed" / "increment" / … and an
// image combo (`image_upload`) adds the upload button's value. Older files
// lack some of these, so they are taken only when the value fits.

import Foundation

public enum WidgetLayout {
    public enum Kind: Equatable, Sendable {
        /// The value of the input with the widget's name.
        case value
        /// What happens to the seed before which this sits after a run.
        case control
        /// The upload button of an image combo.
        case upload
    }

    public struct Widget: Equatable, Sendable {
        /// The input's name; for control and upload widgets the input they follow.
        public var name: String
        public var kind: Kind
        public var spec: InputSpec?
    }

    /// Values a seed control can have.
    public static let controlValues = ["fixed", "increment", "decrement", "randomize"]

    /// The widgets of a node of this kind, in file order.
    public static func widgets(_ spec: NodeSpec) -> [Widget] {
        var out: [Widget] = []
        for name in spec.inputOrder {
            guard let input = spec.inputs[name], input.isWidget else { continue }
            out.append(Widget(name: name, kind: .value, spec: input))
            if input.controlAfterGenerate { out.append(Widget(name: name, kind: .control, spec: nil)) }
            if input.imageUpload { out.append(Widget(name: name, kind: .upload, spec: nil)) }
        }
        return out
    }

    /// Where each widget's value is in a `widgets_values` list.
    public struct Slots: Equatable, Sendable {
        /// Input name → index of its value.
        public var values: [String: Int] = [:]
        /// Input name → index of its seed control.
        public var controls: [String: Int] = [:]
    }

    /// Match `values` (a node's widgets_values list) to the widgets.
    public static func slots(_ spec: NodeSpec, values: [JSONValue]) -> Slots {
        let widgets = widgets(spec)
        // As many values as widgets: take them in order. Fewer: the file was
        // written without some control or upload values; an extra widget
        // takes a value only if it fits and enough values are left for the
        // inputs after it.
        let complete = values.count >= widgets.count
        var slots = Slots()
        var i = 0
        for (n, w) in widgets.enumerated() where i < values.count {
            let inputsAfter = widgets[(n + 1)...].filter { $0.kind == .value }.count
            let spare = values.count - i > inputsAfter
            switch w.kind {
            case .value:
                slots.values[w.name] = i
                i += 1
            case .control:
                if complete || (spare && values[i].string.map(controlValues.contains) == true) {
                    slots.controls[w.name] = i
                    i += 1
                }
            case .upload:
                if complete || (spare && values[i].string != nil) { i += 1 }
            }
        }
        return slots
    }

    /// The default `widgets_values` of a new node.
    public static func defaults(_ spec: NodeSpec) -> [JSONValue] {
        widgets(spec).map { w in
            switch w.kind {
            case .value: w.spec.map(defaultValue) ?? .null
            case .control: .string("randomize")
            case .upload: .string("image")
            }
        }
    }

    public static func defaultValue(_ spec: InputSpec) -> JSONValue {
        switch spec.defaultValue {
        case .string(let s)?: return .string(s)
        case .int(let i)?: return .int(i)
        case .double(let d)?: return .double(d)
        case .bool(let b)?: return .bool(b)
        case .json(let v)?: return v
        case .link?, nil: break
        }
        switch spec.type {
        case "INT": return .int(spec.min.map { Int(max($0, -9e15)) } ?? 0)
        case "FLOAT": return .double(spec.min ?? 0)
        case "BOOLEAN": return .bool(false)
        case "COMBO": return .string(spec.options.first ?? "")
        default: return .string("")
        }
    }
}

extension GraphNode {
    /// The value of widget `name`, using the server's definition of the node.
    public func widgetValue(_ name: String, spec: NodeSpec?) -> JSONValue? {
        switch widgetsValues {
        case .object(let o)?: return o[name]
        case .array(let a)?:
            guard let spec, let i = WidgetLayout.slots(spec, values: a).values[name] else { return nil }
            return a[i]
        default: return nil
        }
    }

    /// The seed control after widget `name` ("randomize", …).
    public func controlValue(_ name: String, spec: NodeSpec?) -> String? {
        guard let spec, case .array(let a)? = widgetsValues,
            let i = WidgetLayout.slots(spec, values: a).controls[name]
        else { return nil }
        return a[i].string
    }

    /// Change widget `name`; other values, and fields the editor doesn't
    /// know, stay as they are.
    public mutating func setWidgetValue(_ name: String, _ value: JSONValue, spec: NodeSpec?) {
        switch widgetsValues {
        case .object(var o)?:
            o[name] = value
            widgetsValues = .object(o)
        case .array(var a)?:
            guard let spec, let i = WidgetLayout.slots(spec, values: a).values[name] else { return }
            a[i] = value
            widgetsValues = .array(a)
        default:
            guard let spec else { return }
            widgetsValues = .array(WidgetLayout.defaults(spec))
            if widgetValue(name, spec: spec) != nil { setWidgetValue(name, value, spec: spec) }
        }
        // Frontend 1.49 also writes the values by name.
        if case .object(var named)? = extra["widgets_values_named"] {
            named[name] = value
            extra["widgets_values_named"] = .object(named)
        }
    }

    public mutating func setControlValue(_ name: String, _ value: String, spec: NodeSpec?) {
        guard let spec, case .array(var a)? = widgetsValues,
            let i = WidgetLayout.slots(spec, values: a).controls[name]
        else { return }
        a[i] = .string(value)
        widgetsValues = .array(a)
    }
}

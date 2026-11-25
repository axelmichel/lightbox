import Foundation

/// One input of a node, as described by `/object_info`.
public struct InputSpec: Equatable, Sendable {
    /// "INT", "FLOAT", "BOOLEAN", "STRING", "COMBO", or a link type such as "IMAGE".
    public var type: String
    /// Options of a combo input.
    public var options: [String]
    public var defaultValue: NodeInput?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    /// A text box with several lines (prompts).
    public var multiline = false
    /// A seed: the editor offers fixed / increment / decrement / randomize
    /// after it, stored as an extra widget value.
    public var controlAfterGenerate = false
    /// A file combo with an upload button (Load Image); the button is
    /// stored as an extra widget value too.
    public var imageUpload = false
    /// A value type shown as a socket only, never as a widget.
    public var forceInput = false
    public var tooltip: String?

    /// Takes a link from another node rather than a value.
    public var isLink: Bool {
        !Self.valueTypes.contains(type)
    }

    /// A widget in the node editor (and in UI-format `widgets_values`).
    public var isWidget: Bool { !isLink && !forceInput }

    static let valueTypes: Set<String> = ["INT", "FLOAT", "BOOLEAN", "STRING", "COMBO"]

    public init(type: String, options: [String] = [], defaultValue: NodeInput? = nil, multiline: Bool = false) {
        self.type = type
        self.options = options
        self.defaultValue = defaultValue
        self.multiline = multiline
    }
}

/// One output of a node.
public struct OutputSpec: Equatable, Sendable {
    public var type: String
    public var name: String
    public var isList = false
}

public struct NodeSpec: Equatable, Sendable {
    /// Required inputs, in the server's order.
    public var required: [String]
    public var optional: [String]
    public var inputs: [String: InputSpec]
    public var outputs: [OutputSpec] = []
    /// The name shown in the editor; `nil` = the class name.
    public var displayName: String?
    /// "loaders", "sampling/custom_sampling", …
    public var category = ""
    public var description = ""
    /// Ends a workflow (Save Image, Preview Image): ComfyUI runs what leads to these.
    public var isOutputNode = false
    public var isDeprecated = false

    /// Inputs in order: required, then optional.
    public var inputOrder: [String] { required + optional }
}

/// What the server offers, read from `GET /object_info`.
public struct ComfyCatalog: Equatable, Sendable {
    public var nodes: [String: NodeSpec] = [:]

    public init() {}

    /// Parse the `/object_info` JSON.
    public init(objectInfo data: Data) throws(ComfyError) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .unexpectedResponse("object_info is not a JSON object")
        }
        for (name, value) in root {
            guard let info = value as? [String: Any], let input = info["input"] as? [String: Any] else { continue }
            var spec = NodeSpec(required: [], optional: [], inputs: [:])
            let order = info["input_order"] as? [String: [String]]
            for group in ["required", "optional"] {
                let specs = input[group] as? [String: Any] ?? [:]
                let names = order?[group]?.filter { specs[$0] != nil } ?? specs.keys.sorted()
                for key in names {
                    guard let raw = specs[key] as? [Any], let parsed = Self.parse(raw) else { continue }
                    spec.inputs[key] = parsed
                    if group == "required" { spec.required.append(key) } else { spec.optional.append(key) }
                }
            }
            let types = info["output"] as? [Any] ?? []
            let names = info["output_name"] as? [Any] ?? []
            let lists = info["output_is_list"] as? [Any] ?? []
            spec.outputs = types.enumerated().map { i, raw in
                // A combo output is listed as its options.
                let type = raw as? String ?? "COMBO"
                return OutputSpec(
                    type: type, name: (i < names.count ? names[i] as? String : nil) ?? type,
                    isList: (i < lists.count ? lists[i] as? Bool : nil) ?? false)
            }
            spec.displayName = (info["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            spec.category = info["category"] as? String ?? ""
            spec.description = info["description"] as? String ?? ""
            spec.isOutputNode = info["output_node"] as? Bool ?? false
            spec.isDeprecated = info["deprecated"] as? Bool ?? false
            nodes[name] = spec
        }
    }

    /// `["INT", {"default": 3}]`, `[["a", "b"], {...}]` or `["COMBO", {"options": [...]}]`.
    static func parse(_ raw: [Any]) -> InputSpec? {
        guard let first = raw.first else { return nil }
        let extra = raw.count > 1 ? raw[1] as? [String: Any] ?? [:] : [:]
        var spec: InputSpec
        if let options = first as? [Any] {
            spec = InputSpec(type: "COMBO", options: options.compactMap { $0 as? String }, defaultValue: nil)
        } else if let type = first as? String {
            let options = (extra["options"] as? [Any])?.compactMap { $0 as? String } ?? []
            spec = InputSpec(type: type, options: options, defaultValue: nil)
        } else {
            return nil
        }
        switch (spec.type, extra["default"]) {
        case ("INT", let v as NSNumber): spec.defaultValue = .int(v.intValue)
        case ("FLOAT", let v as NSNumber): spec.defaultValue = .double(v.doubleValue)
        case ("BOOLEAN", let v as Bool): spec.defaultValue = .bool(v)
        case ("STRING", let v as String), ("COMBO", let v as String): spec.defaultValue = .string(v)
        default: break
        }
        spec.min = (extra["min"] as? NSNumber)?.doubleValue
        spec.max = (extra["max"] as? NSNumber)?.doubleValue
        spec.step = (extra["step"] as? NSNumber)?.doubleValue
        spec.multiline = extra["multiline"] as? Bool ?? false
        spec.controlAfterGenerate = extra["control_after_generate"] as? Bool ?? false
        spec.imageUpload = extra["image_upload"] as? Bool ?? false
        spec.forceInput = extra["forceInput"] as? Bool ?? false
        spec.tooltip = extra["tooltip"] as? String
        return spec
    }

    public func has(_ node: String) -> Bool { nodes[node] != nil }

    /// Options of a combo input.
    public func options(_ node: String, _ input: String) -> [String] {
        nodes[node]?.inputs[input]?.options ?? []
    }

    // MARK: - Model lists

    public var checkpoints: [String] { options("CheckpointLoaderSimple", "ckpt_name") }
    public var vaes: [String] { options("VAELoader", "vae_name") }
    /// Diffusion models without text encoder and VAE (Flux, Z-Image), also GGUF ones.
    public var diffusionModels: [String] {
        unique(options("UNETLoader", "unet_name") + options("UnetLoaderGGUF", "unet_name"))
    }
    /// Text encoder files for split models, also GGUF ones.
    public var textEncoders: [String] {
        unique(options("CLIPLoader", "clip_name") + options("CLIPLoaderGGUF", "clip_name"))
    }

    /// Whether the server has the loader nodes for `split`.
    public func canLoad(_ split: SplitModelRequest) -> Bool { split.requiredNodes.allSatisfy(has) }

    private func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
    public var loras: [String] { options("LoraLoader", "lora_name") }
    public var controlNets: [String] { options("ControlNetLoader", "control_net_name") }
    public var samplers: [String] { options("KSampler", "sampler_name") }
    public var schedulers: [String] { options("KSampler", "scheduler") }
    public var ipAdapters: [String] { options("IPAdapterModelLoader", "ipadapter_file") }
    public var clipVisions: [String] { options("CLIPVisionLoader", "clip_name") }
    /// Impact Pack detectors such as "bbox/face_yolov8m.pt".
    public var detectors: [String] { options("UltralyticsDetectorProvider", "model_name") }

    // MARK: - Features

    /// comfyui_controlnet_aux's all-in-one node; renamed in newer versions.
    public var auxPreprocessorNode: String? {
        ["AIO_Preprocessor", "AIO_Aux_Preprocessor"].first(where: has)
    }

    /// Preprocessors of comfyui_controlnet_aux.
    public var auxPreprocessors: [String] {
        auxPreprocessorNode.map { options($0, "preprocessor").filter { $0 != "none" } } ?? []
    }

    public var hasAuxPreprocessors: Bool { !auxPreprocessors.isEmpty }
    /// ComfyUI's own `Canny` node.
    public var hasCanny: Bool { has("Canny") }
    /// `ControlNetApplyAdvanced` takes a `vae` input (newer ComfyUI).
    public var controlNetTakesVAE: Bool { nodes["ControlNetApplyAdvanced"]?.inputs["vae"] != nil }
    /// Types of `SetUnionControlNetType` ("openpose", "depth", …).
    public var unionTypes: [String] { options("SetUnionControlNetType", "type") }
    /// ComfyUI_IPAdapter_plus.
    public var hasIPAdapter: Bool { has("IPAdapterAdvanced") && has("IPAdapterModelLoader") && has("CLIPVisionLoader") }
    /// Impact Pack's FaceDetailer plus the Ultralytics detector (Impact Subpack).
    /// Painting part of a picture again (core nodes, but checked like the rest).
    public var canInpaint: Bool {
        has("LoadImage") && has("LoadImageMask") && has("VAEEncode") && has("SetLatentNoiseMask")
    }

    /// Editing a picture by instruction with an edit model (Flux 2).
    public var canEditWithReference: Bool { has("ReferenceLatent") && has("LoadImage") && has("VAEEncode") }

    public var hasDetailer: Bool { has("FaceDetailer") && has("UltralyticsDetectorProvider") }
    /// comfyui-tooling-nodes (Krita AI Diffusion's nodes) are installed.
    public var hasToolingNodes: Bool { nodes.keys.contains { $0.hasPrefix("ETN_") } }
    public var nodeCount: Int { nodes.count }

    /// The first detector for faces / hands.
    public var faceDetector: String? { detectors.first { $0.lowercased().contains("face") } }
    public var handDetector: String? { detectors.first { $0.lowercased().contains("hand") } }
}

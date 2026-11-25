// Guides by purpose, as in Krita AI Diffusion: the user picks "Pose" or
// "Composition", and the app finds the model, preprocessor and node setup
// for the checkpoint's architecture. Models are matched by file name, the
// way Krita names them on install (and the common upstream names).

import Foundation

/// The base architecture a checkpoint belongs to; decides which control
/// models fit.
public enum ModelArch: String, Codable, CaseIterable, Sendable {
    case sd15
    case sdxl
    /// Illustrious / NoobAI: SDXL-based anime models with their own ControlNets.
    case illustrious
}

public enum ControlKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Structure (ControlNet)
    case scribble, lineart, softEdge, canny, depth, normal, pose, unblur
    // Image prompts (IP-Adapter)
    case reference, style, composition

    public var id: Self { self }

    public var isImagePrompt: Bool {
        switch self {
        case .reference, .style, .composition: true
        default: false
        }
    }

    public static var structure: [ControlKind] { allCases.filter { !$0.isImagePrompt } }
    public static var imagePrompts: [ControlKind] { allCases.filter(\.isImagePrompt) }
}

/// How a guide is realized on the server.
public enum ControlSetup: Equatable, Sendable {
    /// `extractor` turns an arbitrary picture into what the model expects
    /// (lines, depth, pose skeleton); `nil` when the picture is used as is.
    case controlNet(model: String, unionType: String?, extractor: Preprocessor?)
    case ipAdapter(model: String, clipVision: String, weightType: String)
}

public struct MissingModel: Error, Equatable, Sendable {
    /// What to install, e.g. "a depth ControlNet for Illustrious".
    public var need: String
    /// File names that would be found.
    public var examples: [String]
}

public enum ControlResolver {
    public static func resolve(_ kind: ControlKind, arch: ModelArch, catalog: ComfyCatalog) -> Result<
        ControlSetup, MissingModel
    > {
        if kind.isImagePrompt { return resolveIPAdapter(kind, arch: arch, catalog: catalog) }

        let dedicated = dedicatedControlNets(kind, arch)
        if let model = find(dedicated, in: catalog.controlNets) {
            return .success(.controlNet(model: model, unionType: nil, extractor: extractor(kind, arch, catalog)))
        }
        // Union ControlNets cover most kinds with one file (SDXL only).
        if arch != .sd15,
            let union = find(
                ["controlnet-union-sdxl", "union-sdxl", "union_sdxl", "union-promax"], in: catalog.controlNets),
            let type = unionType(kind), catalog.unionTypes.contains(type)
        {
            return .success(.controlNet(model: union, unionType: type, extractor: extractor(kind, arch, catalog)))
        }
        let examples = dedicated.prefix(2) + (arch == .sd15 ? [] : ["xinsir-controlnet-union-sdxl-1.0-promax"])
        return .failure(
            MissingModel(need: "a \(kindName(kind)) ControlNet for \(archName(arch))", examples: Array(examples)))
    }

    static func resolveIPAdapter(_ kind: ControlKind, arch: ModelArch, catalog: ComfyCatalog) -> Result<
        ControlSetup, MissingModel
    > {
        guard catalog.hasIPAdapter else {
            return .failure(MissingModel(need: "the ComfyUI_IPAdapter_plus nodes", examples: []))
        }
        let models: [String] =
            switch arch {
            case .sd15: ["ip-adapter-plus_sd15", "ip-adapter_sd15"]
            case .sdxl: ["ip-adapter-plus_sdxl_vit-h", "ip-adapter_sdxl_vit-h"]
            case .illustrious: ["noobipamark1", "ip-adapter-plus_sdxl_vit-h", "ip-adapter_sdxl_vit-h"]
            }
        guard let model = find(models, in: catalog.ipAdapters) else {
            return .failure(MissingModel(need: "an IP-Adapter model for \(archName(arch))", examples: [models[0]]))
        }
        // NoobAI's IP-Adapter is trained on ViT-bigG, the others on ViT-H.
        let vision = model.lowercased().contains("noob") ? ["vit-g", "bigg"] : ["vit-h"]
        guard let clip = find(vision, in: catalog.clipVisions) else {
            return .failure(MissingModel(need: "a matching CLIP vision model", examples: ["clip-vision_\(vision[0])"]))
        }
        // Style and composition need SDXL's layer layout.
        let weight: String =
            switch kind {
            case .style: arch == .sd15 ? "linear" : "style transfer"
            case .composition: arch == .sd15 ? "linear" : "composition"
            default: "linear"
            }
        return .success(.ipAdapter(model: model, clipVision: clip, weightType: weight))
    }

    /// File-name fragments, best first. Compared ignoring case, `-`, `_` and `.`.
    static func dedicatedControlNets(_ kind: ControlKind, _ arch: ModelArch) -> [String] {
        switch arch {
        case .illustrious:
            switch kind {
            case .scribble: ["noob-sdxl-controlnet-scribble"]
            case .lineart: ["noob-sdxl-controlnet-lineart"]
            case .softEdge: ["noob-sdxl-controlnet-softedge"]
            case .canny: ["noob-sdxl-controlnet-canny", "noob_sdxl_controlnet_canny"]
            case .depth: ["noob-sdxl-controlnet-depth"]
            case .normal: ["noob-sdxl-controlnet-normal"]
            case .pose: ["noobaixlcontrolnet_openpose", "noob-sdxl-controlnet-openpose", "noob_openpose"]
            case .unblur: ["noob-sdxl-controlnet-tile"]
            default: []
            }
        case .sdxl:
            switch kind {
            case .scribble: ["xinsir-controlnet-scribble-sdxl", "controlnet-scribble-sdxl"]
            case .lineart: ["controlnet-lineart-sdxl", "mistoline"]
            case .softEdge: ["controlnet-softedge-sdxl", "hed-sdxl"]
            case .canny: ["xinsir-controlnet-canny-sdxl", "controlnet-canny-sdxl", "diffusers_xl_canny"]
            case .depth: ["xinsir-controlnet-depth-sdxl", "controlnet-depth-sdxl", "diffusers_xl_depth"]
            case .normal: ["controlnet-normal-sdxl"]
            case .pose: ["xinsir-controlnet-openpose-sdxl", "controlnet-openpose-sdxl", "openpose-sdxl"]
            case .unblur: ["xinsir-controlnet-tile-sdxl", "controlnet-tile-sdxl", "ttplanet-sdxl-controlnet-tile"]
            default: []
            }
        case .sd15:
            switch kind {
            case .scribble: ["control_v11p_sd15_scribble"]
            case .lineart: ["control_v11p_sd15_lineart", "control_v11p_sd15s2_lineart_anime"]
            case .softEdge: ["control_v11p_sd15_softedge"]
            case .canny: ["control_v11p_sd15_canny"]
            case .depth: ["control_v11f1p_sd15_depth"]
            case .normal: ["control_v11p_sd15_normalbae"]
            case .pose: ["control_v11p_sd15_openpose"]
            case .unblur: ["control_v11f1e_sd15_tile", "control_v11u_sd15_tile"]
            default: []
            }
        }
    }

    static func unionType(_ kind: ControlKind) -> String? {
        switch kind {
        case .scribble, .softEdge: "hed/pidi/scribble/ted"
        case .lineart, .canny: "canny/lineart/anime_lineart/mlsd"
        case .depth: "depth"
        case .normal: "normal"
        case .pose: "openpose"
        case .unblur: "tile"
        default: nil
        }
    }

    /// The preprocessor that turns a picture into this kind's guide, if the
    /// server has one.
    static func extractor(_ kind: ControlKind, _ arch: ModelArch, _ catalog: ComfyCatalog) -> Preprocessor? {
        let candidates: [String] =
            switch kind {
            case .scribble:
                [
                    "Scribble_PiDiNet_Preprocessor", "PiDiNetPreprocessor", "FakeScribblePreprocessor",
                    "ScribblePreprocessor",
                ]
            case .lineart:
                arch == .sd15
                    ? ["LineArtPreprocessor", "AnimeLineArtPreprocessor"]
                    : arch == .illustrious
                        ? ["AnimeLineArtPreprocessor", "LineArtPreprocessor"]
                        : ["LineArtPreprocessor", "AnimeLineArtPreprocessor"]
            case .softEdge: ["HEDPreprocessor", "PiDiNetPreprocessor", "TEEDPreprocessor"]
            case .canny: ["CannyEdgePreprocessor"]
            case .depth:
                [
                    "DepthAnythingV2Preprocessor", "DepthAnythingPreprocessor", "MiDaS-DepthMapPreprocessor",
                    "Zoe-DepthMapPreprocessor",
                ]
            case .normal: ["BAE-NormalMapPreprocessor", "DSINE-NormalMapPreprocessor", "MiDaS-NormalMapPreprocessor"]
            case .pose: ["DWPreprocessor", "OpenposePreprocessor"]
            case .unblur, .reference, .style, .composition: []
            }
        let resolution = arch == .sd15 ? 512 : 1024
        if let name = candidates.first(where: catalog.auxPreprocessors.contains) {
            return .aux(name, resolution: resolution)
        }
        if kind == .canny, catalog.hasCanny { return .canny(low: 0.4, high: 0.8) }
        return nil
    }

    static func find(_ fragments: [String], in files: [String]) -> String? {
        func key(_ s: String) -> String { s.lowercased().filter { !"-_. ".contains($0) } }
        for fragment in fragments {
            let k = key(fragment)
            if let file = files.first(where: { key($0).contains(k) }) { return file }
        }
        return nil
    }

    static func kindName(_ kind: ControlKind) -> String {
        switch kind {
        case .softEdge: "soft edge"
        case .lineart: "line art"
        case .unblur: "tile"
        default: kind.rawValue
        }
    }

    static func archName(_ arch: ModelArch) -> String {
        switch arch {
        case .sd15: "SD 1.5"
        case .sdxl: "SDXL"
        case .illustrious: "Illustrious/NoobAI"
        }
    }
}

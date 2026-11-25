import ComfyKit
import LightboxCore

/// How each guide kind is presented: what it does, in plain words.
extension ControlKind {
    var title: String {
        switch self {
        case .scribble: "Scribble"
        case .lineart: "Line art"
        case .softEdge: "Soft edges"
        case .canny: "Hard edges"
        case .depth: "Depth"
        case .normal: "Surfaces"
        case .pose: "Pose"
        case .unblur: "Unblur"
        case .reference: "Reference"
        case .style: "Style"
        case .composition: "Composition"
        }
    }

    var icon: String {
        switch self {
        case .scribble: "scribble"
        case .lineart: "pencil.line"
        case .softEdge: "circle.dashed"
        case .canny: "square.dashed"
        case .depth: "square.3.layers.3d"
        case .normal: "cube"
        case .pose: "figure.walk"
        case .unblur: "sparkles"
        case .reference: "photo"
        case .style: "paintpalette"
        case .composition: "rectangle.3.group"
        }
    }

    var summary: String {
        switch self {
        case .scribble: "Follows a rough sketch loosely: the main shapes and where things are."
        case .lineart: "Keeps your lines exactly and colors them in. For inked drawings."
        case .softEdge: "Follows the outlines of a picture, but leaves the details free."
        case .canny: "Copies every edge of a picture precisely, down to small details."
        case .depth: "Keeps what is near and what is far: the layout of a scene, not its look."
        case .normal: "Keeps the shape of objects and how light falls on them."
        case .pose: "Copies the body pose of the people in a photo or drawing."
        case .unblur: "Redraws a blurry or small picture with fresh detail, keeping what it shows."
        case .reference: "Takes the subject and look of a picture and re-imagines it freely."
        case .style: "Takes colors, rendering and mood only, not what the picture shows."
        case .composition: "Takes the layout and arrangement only, not the style."
        }
    }

    /// Label of the "extract first" switch; `nil` for kinds that use the
    /// picture directly.
    var extractLabel: String? {
        switch self {
        case .scribble: "Trace the picture into a scribble"
        case .lineart: "Extract the lines from the picture"
        case .softEdge: "Extract soft edges"
        case .canny: "Detect the edges"
        case .depth: "Estimate depth from the picture"
        case .normal: "Estimate surfaces from the picture"
        case .pose: "Detect the pose in the picture"
        case .unblur, .reference, .style, .composition: nil
        }
    }

    var extractHint: String {
        switch self {
        case .scribble: "Turn off if the picture already is a rough sketch."
        case .lineart: "Turn off for your own clean line art: dark lines on white."
        case .depth: "Turn off if the picture already is a depth map (white is near)."
        case .normal: "Turn off if the picture already is a normal map."
        case .pose: "Turn off if the picture already is a pose skeleton."
        default: "Turn off if the picture already is an edge map."
        }
    }

    var strengthLabel: String { isImagePrompt ? "Influence" : "Strength" }

    var defaultStrength: Double {
        switch self {
        case .lineart, .pose: 0.8
        case .depth, .normal, .unblur: 0.6
        case .scribble, .softEdge, .canny, .reference: 0.7
        case .composition: 0.8
        case .style: 0.9
        }
    }
}

extension ModelFamily {
    var arch: ModelArch {
        switch self {
        case .sd15: .sd15
        case .illustrious: .illustrious
        // Pony is SDXL underneath; SDXL ControlNets and IP-Adapters work.
        // Flux and Z-Image have no guides in Lightbox (`supportsGuides`).
        case .sdxl, .pony, .flux, .zImage, .flux2, .anima, .unsupported: .sdxl
        }
    }
}

extension MissingModel {
    var message: String {
        examples.isEmpty ? "Needs \(need)." : "Needs \(need), e.g. \(examples.joined(separator: " or "))."
    }
}

import Foundation

public enum ComfyError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidURL(String)
    case http(status: Int, message: String)
    /// ComfyUI rejected the workflow (`POST /prompt` → 400).
    case invalidWorkflow(String)
    /// The workflow failed while running.
    case execution(node: String, message: String)
    case unexpectedResponse(String)
    case noImages

    public var description: String {
        switch self {
        case .invalidURL(let s): "Not a valid server address: \(s)"
        case .http(let status, let message): "Server answered \(status): \(message)"
        case .invalidWorkflow(let message): "ComfyUI rejected the workflow: \(message)"
        case .execution(let node, let message): "ComfyUI failed in \(node): \(message)"
        case .unexpectedResponse(let s): "Unexpected answer from the server: \(s)"
        case .noImages: "The workflow finished without images."
        }
    }
}

public enum ComfyServer {
    /// "192.168.1.20:8188" → "http://192.168.1.20:8188"; trailing slashes dropped.
    public static func normalizedURL(from input: String) throws(ComfyError) -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host() != nil
        else { throw .invalidURL(input) }
        return url
    }
}

/// `GET /system_stats`.
public struct SystemStats: Decodable, Equatable, Sendable {
    public struct System: Decodable, Equatable, Sendable {
        public var os: String?
        public var comfyuiVersion: String?
        public var pythonVersion: String?
        public var pytorchVersion: String?
        public var ramTotal: Int64?
        public var ramFree: Int64?

        enum CodingKeys: String, CodingKey {
            case os
            case comfyuiVersion = "comfyui_version"
            case pythonVersion = "python_version"
            case pytorchVersion = "pytorch_version"
            case ramTotal = "ram_total"
            case ramFree = "ram_free"
        }
    }

    public struct Device: Decodable, Equatable, Sendable {
        public var name: String
        public var type: String
        public var vramTotal: Int64?
        public var vramFree: Int64?

        enum CodingKeys: String, CodingKey {
            case name, type
            case vramTotal = "vram_total"
            case vramFree = "vram_free"
        }
    }

    public var system: System
    public var devices: [Device]

    /// "NVIDIA GeForce GPU (8 GB)"
    public var gpuSummary: String {
        guard let d = devices.first else { return "no GPU reported" }
        // ComfyUI reports "cuda:0 NVIDIA GeForce GPU : cudaMallocAsync".
        var name = d.name
        if let colon = name.range(of: " : ") { name = String(name[..<colon.lowerBound]) }
        if let space = name.firstIndex(of: " "), name.hasPrefix("cuda:") || name.hasPrefix("mps") {
            name = String(name[name.index(after: space)...])
        }
        guard let vram = d.vramTotal, vram > 0 else { return name }
        return "\(name) (\(Int((Double(vram) / 1_073_741_824).rounded())) GB)"
    }
}

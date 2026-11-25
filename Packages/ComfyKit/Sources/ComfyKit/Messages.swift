import Foundation

/// A message on ComfyUI's WebSocket (`/ws?clientId=`).
public enum ServerMessage: Equatable, Sendable {
    case status(queueRemaining: Int?)
    case executionStart(promptID: String)
    /// `node == nil` marks the end of a prompt (older servers send only this).
    case executing(promptID: String?, node: String?)
    case progress(promptID: String?, value: Int, max: Int)
    case success(promptID: String)
    case error(promptID: String, node: String, message: String)
    case interrupted(promptID: String)
    /// A node finished and shows pictures (Save Image, Preview Image).
    case executed(promptID: String, node: String, images: [ImageRef])
    /// Nodes ComfyUI didn't run again because their inputs didn't change.
    case cached(promptID: String, nodes: [String])
    /// Live preview of the image being sampled (JPEG or PNG).
    case preview(Data)
    case other(String)

    public static func parse(text: String) -> ServerMessage? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
            let type = obj["type"] as? String
        else { return nil }
        let data = obj["data"] as? [String: Any] ?? [:]
        let prompt = data["prompt_id"] as? String
        switch type {
        case "status":
            let info = (data["status"] as? [String: Any])?["exec_info"] as? [String: Any]
            return .status(queueRemaining: info?["queue_remaining"] as? Int)
        case "execution_start":
            return prompt.map { .executionStart(promptID: $0) } ?? .other(type)
        case "executing":
            return .executing(promptID: prompt, node: data["node"] as? String)
        case "progress":
            return .progress(promptID: prompt, value: data["value"] as? Int ?? 0, max: data["max"] as? Int ?? 0)
        case "execution_success":
            return prompt.map { .success(promptID: $0) } ?? .other(type)
        case "execution_error":
            guard let prompt else { return .other(type) }
            let node = [data["node_type"], data["node_id"]].compactMap { $0 as? String }.joined(separator: " #")
            let message = (data["exception_message"] as? String ?? "unknown error")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(promptID: prompt, node: node.isEmpty ? "a node" : node, message: message)
        case "execution_interrupted":
            return prompt.map { .interrupted(promptID: $0) } ?? .other(type)
        case "executed":
            guard let prompt, let node = data["node"] as? String else { return .other(type) }
            let images = ((data["output"] as? [String: Any])?["images"] as? [[String: Any]] ?? []).compactMap(
                ImageRef.init(history:))
            return .executed(promptID: prompt, node: node, images: images)
        case "execution_cached":
            guard let prompt else { return .other(type) }
            return .cached(promptID: prompt, nodes: data["nodes"] as? [String] ?? [])
        default:
            return .other(type)
        }
    }

    /// Binary frames: 4-byte big-endian event type, then the payload.
    /// Type 1 = preview (4-byte image format + image), type 4 = preview with
    /// metadata (4-byte JSON length + JSON + image).
    public static func parse(binary data: Data) -> ServerMessage? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int? {
            guard bytes.count >= at + 4 else { return nil }
            return bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
        }
        switch u32(0) {
        case 1:
            guard bytes.count > 8 else { return nil }
            return .preview(Data(bytes[8...]))
        case 4:
            guard let length = u32(4), bytes.count > 8 + length else { return nil }
            return .preview(Data(bytes[(8 + length)...]))
        default:
            return nil
        }
    }
}

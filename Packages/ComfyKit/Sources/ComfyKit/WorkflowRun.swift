// Running a workflow from the node editor: any graph, with what happens at
// each node, so the editor can mark the running node and show each output
// node's pictures.

import Foundation

extension ImageRef {
    public init(file filename: String, subfolder: String = "", type: String = "output") {
        self.filename = filename
        self.subfolder = subfolder
        self.type = type
    }

    /// From an entry in `/history` or an `executed` message.
    init?(history i: [String: Any]) {
        guard let name = i["filename"] as? String else { return nil }
        filename = name
        subfolder = i["subfolder"] as? String ?? ""
        type = i["type"] as? String ?? "output"
    }
}

public enum RunEvent: Equatable, Sendable {
    case queued(promptID: String)
    /// The node running now (API id, "5" or "5:3").
    case executing(node: String)
    /// Nodes not run again because nothing they use changed.
    case cached(nodes: [String])
    case progress(node: String?, step: Int, total: Int)
    case preview(Data)
    /// A node finished with pictures.
    case executed(node: String, images: [ImageRef])
    case finished
    case cancelled
}

public enum WorkflowRunError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `POST /prompt` refused it; `nodes` has the messages by API id.
    case rejected(message: String, nodes: [String: [String]])
    /// A node failed while running.
    case failed(node: String?, nodeType: String?, message: String)

    public var description: String {
        switch self {
        case .rejected(let message, let nodes):
            let lines = nodes.keys.sorted().flatMap { id in nodes[id, default: []].map { "#\(id): \($0)" } }
            return (["ComfyUI rejected the workflow: \(message)"] + lines).joined(separator: "\n")
        case .failed(_, let type, let message):
            return "ComfyUI failed in \(type ?? "a node"): \(message)"
        }
    }
}

extension ComfyClient {
    /// Run any graph and report it as `generate` reports a request: a stage
    /// per node type, progress and previews, and at the end the pictures of
    /// every output node.
    public func generate(_ graph: WorkflowGraph, workflow: JSONValue? = nil) -> AsyncThrowingStream<
        GenerationEvent, Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var images: [GeneratedImage] = []
                    var started = false
                    for try await event in run(graph, workflow: workflow) {
                        switch event {
                        case .queued(let id): continuation.yield(.queued(promptID: id))
                        case .executing(let node):
                            if !started {
                                started = true
                                continuation.yield(.started)
                            }
                            if let type = graph.nodes[node]?.classType { continuation.yield(.stage(type)) }
                            continuation.yield(.node(node))
                        case .cached: break
                        case .progress(_, let step, let total): continuation.yield(.progress(step: step, total: total))
                        case .preview(let data): continuation.yield(.preview(data))
                        case .executed(_, let refs):
                            for ref in refs { images.append(GeneratedImage(data: try await image(ref), ref: ref)) }
                        case .finished: continuation.yield(.finished(images))
                        case .cancelled: continuation.yield(.cancelled)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Queue `graph` and follow it. `workflow` (the UI-format file) is
    /// stored with the prompt, as ComfyUI's frontend does, so Save Image
    /// writes it into the picture. Cancelling the consuming task cancels the
    /// prompt on the server.
    public func run(_ graph: WorkflowGraph, workflow: JSONValue? = nil) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runWorkflow(graph, workflow: workflow, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runWorkflow(
        _ graph: WorkflowGraph, workflow: JSONValue?, _ out: AsyncThrowingStream<RunEvent, Error>.Continuation
    ) async throws {
        let clientID = UUID().uuidString
        let socket = session.webSocketTask(with: webSocketURL(clientID: clientID))
        socket.maximumMessageSize = 64 << 20
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await Self.waitUntilConnected(socket)

        let promptID = try await queuePrompt(graph, clientID: clientID, workflow: workflow)
        out.yield(.queued(promptID: promptID))
        do {
            try await withTaskCancellationHandler {
                try await followRun(socket, promptID: promptID, out)
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                let client = self
                await Task.detached { try? await client.cancel(promptID: promptID) }.value
                out.yield(.cancelled)
                return
            }
            if error is WorkflowRunError { throw error }
            // Socket dropped: wait for the history, then report its pictures.
            try await poll(promptID: promptID)
            for (node, images) in try await outputsByNode(promptID: promptID) {
                out.yield(.executed(node: node, images: images))
            }
        }
        out.yield(.finished)
    }

    /// `POST /prompt` with the editor's workflow in extra_pnginfo.
    func queuePrompt(_ graph: WorkflowGraph, clientID: String, workflow: JSONValue?) async throws -> String {
        var body: [String: Any] = ["prompt": graph.jsonObject(), "client_id": clientID]
        if let workflow { body["extra_data"] = ["extra_pnginfo": ["workflow": workflow.any]] }
        var req = URLRequest(url: url("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await raw(req, body: try JSONSerialization.data(withJSONObject: body))
        if status == 400 {
            throw WorkflowRunError.rejected(message: Self.workflowError(data), nodes: Self.nodeErrors(data))
        }
        guard (200..<300).contains(status) else { throw ComfyError.http(status: status, message: Self.text(data)) }
        guard let id = try await json(data)["prompt_id"] as? String else {
            throw ComfyError.unexpectedResponse("prompt without prompt_id")
        }
        return id
    }

    /// The messages of a 400 answer by node id.
    static func nodeErrors(_ data: Data) -> [String: [String]] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let nodes = obj["node_errors"] as? [String: Any]
        else { return [:] }
        var out: [String: [String]] = [:]
        for (id, raw) in nodes {
            for e in (raw as? [String: Any])?["errors"] as? [[String: Any]] ?? [] {
                let parts = [e["message"], e["details"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                out[id, default: []].append(parts.joined(separator: ": "))
            }
        }
        return out
    }

    private func followRun(
        _ socket: URLSessionWebSocketTask, promptID: String, _ out: AsyncThrowingStream<RunEvent, Error>.Continuation
    ) async throws {
        var current: String?
        while true {
            try Task.checkCancellation()
            let message: ServerMessage? =
                switch try await socket.receive() {
                case .string(let text): ServerMessage.parse(text: text)
                case .data(let data): ServerMessage.parse(binary: data)
                @unknown default: nil
                }
            switch message {
            case .executing(let id, let node?) where id == promptID:
                current = node
                out.yield(.executing(node: node))
            case .executing(let id, nil) where id == promptID:
                return
            case .success(let id) where id == promptID:
                return
            case .progress(let id, let value, let max) where id == promptID || (id == nil && current != nil):
                out.yield(.progress(node: current, step: value, total: max))
            case .preview(let data) where current != nil:
                out.yield(.preview(data))
            case .cached(let id, let nodes) where id == promptID:
                out.yield(.cached(nodes: nodes))
            case .executed(let id, let node, let images) where id == promptID:
                out.yield(.executed(node: node, images: images))
            case .error(let id, let node, let message) where id == promptID:
                // "KSampler #12".
                let parts = node.components(separatedBy: " #")
                throw WorkflowRunError.failed(
                    node: parts.count == 2 ? parts[1] : current, nodeType: parts.first, message: message)
            case .interrupted(let id) where id == promptID:
                throw CancellationError()
            case .executionStart, .executing, .progress, .preview, .success, .error, .interrupted, .executed, .cached,
                .status, .other, nil:
                continue
            }
        }
    }

    /// The pictures of a finished prompt, by node.
    func outputsByNode(promptID: String) async throws -> [(String, [ImageRef])] {
        let obj = try await json(try await get("history/\(promptID)"))
        let outputs = (obj[promptID] as? [String: Any])?["outputs"] as? [String: Any] ?? [:]
        return outputs.keys.sorted().map { key in
            let images = (outputs[key] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            return (key, images.compactMap(ImageRef.init(history:)))
        }
    }

    /// The node definitions again, for one node kind (cheap; used to refresh a combo).
    public func nodeInfo(_ type: String) async throws -> NodeSpec? {
        let data = try await get("object_info/\(type)")
        return try ComfyCatalog(objectInfo: data).nodes[type]
    }
}

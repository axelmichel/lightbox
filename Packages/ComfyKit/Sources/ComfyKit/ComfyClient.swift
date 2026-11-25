import Foundation

/// A file in ComfyUI's input, output or temp folder.
public struct ImageRef: Equatable, Hashable, Sendable {
    public var filename: String
    public var subfolder: String
    public var type: String
}

public struct GeneratedImage: Equatable, Sendable {
    public var data: Data
    public var ref: ImageRef
}

public enum GenerationEvent: Equatable, Sendable {
    case uploading
    case queued(promptID: String)
    case started
    /// A node started; its class type, e.g. "KSampler" or "FaceDetailer".
    case stage(String)
    case progress(step: Int, total: Int)
    case preview(Data)
    case finished([GeneratedImage])
    case cancelled
}

/// HTTP + WebSocket client for one ComfyUI server.
public struct ComfyClient: Sendable {
    public let baseURL: URL
    /// Subfolder of ComfyUI's input folder that guide pictures go to.
    public var uploadFolder: String
    let session: URLSession

    public init(baseURL: URL, uploadFolder: String = "lightbox", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.uploadFolder = uploadFolder
        self.session = session
    }

    // MARK: - Plain requests

    public func systemStats() async throws -> SystemStats {
        try JSONDecoder().decode(SystemStats.self, from: try await get("system_stats"))
    }

    public func catalog() async throws -> ComfyCatalog {
        try ComfyCatalog(objectInfo: try await get("object_info"))
    }

    /// The metadata stored in a model file's header (`GET /view_metadata`),
    /// e.g. `modelspec.architecture` or a LoRA's training tags. `nil` when
    /// the file has none (not a safetensors file, or nothing stored).
    public func modelMetadata(folder: String = "checkpoints", filename: String) async throws -> [String: String]? {
        var c = URLComponents(url: url("view_metadata/\(folder)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "filename", value: filename)]
        let (data, status) = try await raw(URLRequest(url: c.url!), body: nil)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw ComfyError.http(status: status, message: Self.text(data)) }
        return Self.metadata(data)
    }

    /// Header metadata values are strings; some (training tags) hold JSON.
    static func metadata(_ data: Data) -> [String: String]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, value) in obj {
            if let s = value as? String {
                out[key] = s
            } else if JSONSerialization.isValidJSONObject(value),
                let d = try? JSONSerialization.data(withJSONObject: value)
            {
                out[key] = String(decoding: d, as: UTF8.self)
            } else {
                out[key] = "\(value)"
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Upload to ComfyUI's input folder; returns the name to use in `LoadImage`.
    public func upload(image: Data, filename: String) async throws -> String {
        let boundary = "comfykit-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(
                Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("type", "input")
        field("subfolder", uploadFolder)
        field("overwrite", "true")
        body.append(
            Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                    .utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url("upload/image"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let obj = try await json(try await send(req, body: body))
        guard let name = obj["name"] as? String else { throw ComfyError.unexpectedResponse("upload without name") }
        let sub = obj["subfolder"] as? String ?? ""
        return sub.isEmpty ? name : "\(sub)/\(name)"
    }

    /// Queue a workflow; returns its prompt id.
    public func queue(_ graph: WorkflowGraph, clientID: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": graph.jsonObject(), "client_id": clientID])
        var req = URLRequest(url: url("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await raw(req, body: body)
        if status == 400 { throw ComfyError.invalidWorkflow(Self.workflowError(data)) }
        guard (200..<300).contains(status) else { throw ComfyError.http(status: status, message: Self.text(data)) }
        guard let id = try await json(data)["prompt_id"] as? String else {
            throw ComfyError.unexpectedResponse("prompt without prompt_id")
        }
        return id
    }

    /// Output images of a finished prompt; `nil` while it is not done.
    public func outputs(promptID: String) async throws -> [ImageRef]? {
        let obj = try await json(try await get("history/\(promptID)"))
        guard let entry = obj[promptID] as? [String: Any] else { return nil }
        if let status = entry["status"] as? [String: Any], status["status_str"] as? String == "error" {
            throw ComfyError.execution(node: "the workflow", message: "see the ComfyUI console")
        }
        let outputs = entry["outputs"] as? [String: Any] ?? [:]
        return outputs.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.flatMap { key in
            let images = (outputs[key] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            return images.compactMap(ImageRef.init(history:))
        }
    }

    public func image(_ ref: ImageRef) async throws -> Data {
        var c = URLComponents(url: url("view"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "filename", value: ref.filename),
            URLQueryItem(name: "subfolder", value: ref.subfolder),
            URLQueryItem(name: "type", value: ref.type),
        ]
        return try await send(URLRequest(url: c.url!))
    }

    /// Stop a prompt: drop it from the queue, or interrupt it if it runs.
    /// Newer servers only interrupt the given prompt; older ones whatever runs.
    public func cancel(promptID: String) async throws {
        var del = URLRequest(url: url("queue"))
        del.httpMethod = "POST"
        _ = try await send(del, body: try JSONSerialization.data(withJSONObject: ["delete": [promptID]]))
        var stop = URLRequest(url: url("interrupt"))
        stop.httpMethod = "POST"
        _ = try await send(stop, body: try JSONSerialization.data(withJSONObject: ["prompt_id": promptID]))
    }

    // MARK: - Generation

    /// Upload the guide images (and the picture to inpaint), queue the
    /// workflow and stream its progress.
    /// Cancelling the consuming task cancels the prompt on the server.
    public func generate(_ request: GenerationRequest, catalog: ComfyCatalog) -> AsyncThrowingStream<
        GenerationEvent, Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, catalog: catalog, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: GenerationRequest, catalog: ComfyCatalog,
        _ out: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var request = request
        if !request.guides.isEmpty || request.inpaint != nil || !request.references.isEmpty { out.yield(.uploading) }
        for i in request.references.indices {
            let reference = request.references[i]
            request.references[i].imageName = try await upload(
                image: reference.image, filename: "\(reference.filename).png")
        }
        if let source = request.inpaint {
            request.inpaint?.imageName = try await upload(image: source.image, filename: "\(source.filename).png")
            request.inpaint?.maskName = try await upload(image: source.mask, filename: "\(source.filename)-mask.png")
        }
        for i in request.guides.indices {
            let guide = request.guides[i]
            request.guides[i].imageName = try await upload(image: guide.image, filename: guide.filename)
        }

        // Listen before queueing, so no event of this prompt is missed.
        let clientID = UUID().uuidString
        let socket = session.webSocketTask(with: webSocketURL(clientID: clientID))
        socket.maximumMessageSize = 64 << 20
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        // An idle server starts within milliseconds; queueing before the
        // socket is connected loses the first events of the prompt.
        try await Self.waitUntilConnected(socket)

        let graph = WorkflowBuilder.txt2img(request, catalog: catalog)
        let promptID = try await queue(graph, clientID: clientID)
        out.yield(.queued(promptID: promptID))

        do {
            // `receive()` ignores task cancellation; closing the socket ends it.
            try await withTaskCancellationHandler {
                try await follow(socket, promptID: promptID, graph: graph, out)
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                // The consumer went away (or ComfyUI interrupted the prompt):
                // make sure it stops on the server too. Detached, because
                // requests from this cancelled task would fail at once.
                let client = self
                await Task.detached { try? await client.cancel(promptID: promptID) }.value
                out.yield(.cancelled)
                return
            }
            if error is ComfyError { throw error }
            // Socket dropped: fall back to polling the history.
            try await poll(promptID: promptID)
        }

        guard let refs = try await outputs(promptID: promptID), !refs.isEmpty else { throw ComfyError.noImages }
        var images: [GeneratedImage] = []
        for ref in refs { images.append(GeneratedImage(data: try await image(ref), ref: ref)) }
        out.yield(.finished(images))
    }

    /// Follow the WebSocket until the prompt is done. Throws `ComfyError` for
    /// failures reported by the server, other errors if the socket breaks.
    private func follow(
        _ socket: URLSessionWebSocketTask, promptID: String, graph: WorkflowGraph,
        _ out: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        // Any event naming our prompt means it runs, even if `execution_start`
        // was missed.
        var running = false
        while true {
            try Task.checkCancellation()
            let message: ServerMessage? =
                switch try await socket.receive() {
                case .string(let text): ServerMessage.parse(text: text)
                case .data(let data): ServerMessage.parse(binary: data)
                @unknown default: nil
                }
            switch message {
            case .executionStart(let id) where id == promptID:
                running = true
                out.yield(.started)
            case .progress(let id, let value, let max) where id == promptID || (id == nil && running):
                if !running {
                    running = true
                    out.yield(.started)
                }
                out.yield(.progress(step: value, total: max))
            case .preview(let data) where running:
                out.yield(.preview(data))
            case .success(let id) where id == promptID:
                return
            case .executing(let id, nil) where id == promptID:
                return
            case .executing(let id, let node?) where id == promptID:
                if !running {
                    running = true
                    out.yield(.started)
                }
                if let type = graph.nodes[node]?.classType { out.yield(.stage(type)) }
            case .error(let id, let node, let message) where id == promptID:
                throw ComfyError.execution(node: node, message: message)
            case .interrupted(let id) where id == promptID:
                throw CancellationError()
            case .executionStart, .executing, .progress, .preview, .success, .error, .interrupted, .executed, .cached,
                .status, .other, nil:
                continue
            }
        }
    }

    /// Resolves once the socket is open: ComfyUI greets every new socket
    /// with a `status` message. (`sendPing` is no use here: its answer never
    /// arrives while no `receive()` is pending.) Gives up after `timeout`.
    static func waitUntilConnected(_ socket: URLSessionWebSocketTask, timeout: Duration = .seconds(10))
        async throws
    {
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        do {
            _ = try await withTaskCancellationHandler {
                try await socket.receive()
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            try Task.checkCancellation()
            throw ComfyError.unexpectedResponse(
                "The live connection (WebSocket) to ComfyUI did not open: \(error.localizedDescription)")
        }
    }

    func poll(promptID: String) async throws {
        while try await outputs(promptID: promptID) == nil {
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Plumbing

    func url(_ path: String) -> URL { baseURL.appending(path: path) }

    func webSocketURL(clientID: String) -> URL {
        var c = URLComponents(url: url("ws"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        return c.url!
    }

    func get(_ path: String) async throws -> Data {
        try await send(URLRequest(url: url(path)))
    }

    func send(_ req: URLRequest, body: Data? = nil) async throws -> Data {
        let (data, status) = try await raw(req, body: body)
        guard (200..<300).contains(status) else { throw ComfyError.http(status: status, message: Self.text(data)) }
        return data
    }

    func raw(_ req: URLRequest, body: Data?) async throws -> (Data, Int) {
        var req = req
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func json(_ data: Data) async throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ComfyError.unexpectedResponse(Self.text(data))
        }
        return obj
    }

    static func text(_ data: Data) -> String {
        String(decoding: data.prefix(500), as: UTF8.self)
    }

    /// Readable summary of a `POST /prompt` 400 answer.
    static func workflowError(_ data: Data) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return text(data) }
        var lines: [String] = []
        if let e = obj["error"] as? [String: Any] {
            lines.append(
                [e["message"], e["details"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: ": ")
            )
        }
        let nodes = obj["node_errors"] as? [String: Any] ?? [:]
        for key in nodes.keys.sorted() {
            guard let n = nodes[key] as? [String: Any] else { continue }
            let cls = n["class_type"] as? String ?? "node"
            for e in n["errors"] as? [[String: Any]] ?? [] {
                let msg = [e["message"], e["details"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                lines.append("\(cls) #\(key): \(msg.joined(separator: ": "))")
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

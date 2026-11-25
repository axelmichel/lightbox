// A small client for a local Ollama server (https://ollama.com), used to
// rewrite prompts. Only the model list and one-shot chat are used.

import Foundation

public enum OllamaError: Error, CustomStringConvertible, Sendable {
    case badAddress(String)
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case .badAddress(let a): "“\(a)” is not a valid Ollama address."
        case .http(let code, let text): "Ollama answered \(code)\(text.isEmpty ? "" : ": \(text)")"
        case .badResponse: "Ollama sent an answer Lightbox doesn't understand."
        }
    }
}

public struct OllamaClient: Sendable {
    public static let defaultAddress = "localhost:11434"

    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `localhost:11434`, `http://mac.local:11434/` and the like.
    public init(address: String, session: URLSession = .shared) throws(OllamaError) {
        var text = address.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { text = Self.defaultAddress }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host() != nil else { throw .badAddress(address) }
        self.init(baseURL: url, session: session)
    }

    /// The models pulled on the server, by name ("llama3.2:3b").
    public func models() async throws -> [String] {
        let (data, _) = try await send(URLRequest(url: baseURL.appending(path: "api/tags")))
        struct Tags: Decodable {
            struct Model: Decodable { var name: String }
            var models: [Model]
        }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else { throw OllamaError.badResponse }
        return tags.models.map(\.name).sorted()
    }

    /// One answer from `model` to `user`, told how to behave by `system`.
    public func chat(model: String, system: String, user: String) async throws -> String {
        struct Message: Codable { var role: String, content: String }
        struct Body: Encodable {
            var model: String
            var messages: [Message]
            var stream = false
            var options = ["temperature": 0.7]
        }
        struct Answer: Decodable { var message: Message }
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Body(
                model: model,
                messages: [Message(role: "system", content: system), Message(role: "user", content: user)]))
        // Loading a model the first time can take a while.
        request.timeoutInterval = 180
        let (data, _) = try await send(request)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw OllamaError.badResponse }
        return answer.message.content
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OllamaError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text =
                (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw OllamaError.http(http.statusCode, text)
        }
        return (data, http)
    }
}

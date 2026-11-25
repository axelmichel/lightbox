import Foundation
import Testing

@testable import LightboxCore

final class OllamaStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest, Data) -> (Int, Data) = { _, _ in (404, Data()) }
    nonisolated(unsafe) static var seen: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.seen.append((request, body))
        let (status, data) = Self.respond(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct OllamaTests {
    let client: OllamaClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaStub.self]
        return try! OllamaClient(address: "localhost:11434", session: URLSession(configuration: config))
    }()

    @Test func addresses() throws {
        #expect(try OllamaClient(address: "").baseURL.absoluteString == "http://localhost:11434")
        #expect(try OllamaClient(address: "https://mac.local:11434/").baseURL.host() == "mac.local")
        #expect(throws: OllamaError.self) { try OllamaClient(address: "http://") }
    }

    @Test func listsModels() async throws {
        OllamaStub.respond = { req, _ in
            #expect(req.url?.path == "/api/tags")
            return (200, Data(#"{"models":[{"name":"qwen3:8b","size":1},{"name":"llama3.2:3b"}]}"#.utf8))
        }
        #expect(try await client.models() == ["llama3.2:3b", "qwen3:8b"])
    }

    @Test func chatSendsSystemAndUser() async throws {
        OllamaStub.seen = []
        OllamaStub.respond = { _, _ in
            (200, Data(#"{"model":"m","message":{"role":"assistant","content":"a red fox"},"done":true}"#.utf8))
        }
        let answer = try await client.chat(model: "m", system: "be brief", user: "fox")
        #expect(answer == "a red fox")
        let (req, body) = try #require(OllamaStub.seen.last)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/chat")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == false)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages.last?["content"] == "fox")
    }

    @Test func errorsCarryOllamasMessage() async {
        OllamaStub.respond = { _, _ in (404, Data(#"{"error":"model \"x\" not found"}"#.utf8)) }
        await #expect {
            _ = try await client.chat(model: "x", system: "", user: "fox")
        } throws: { error in
            guard case OllamaError.http(404, let text) = error else { return false }
            return text.contains("not found")
        }
    }
}

// Looking a LoRA up on Civitai (https://civitai.com/api/v1), only when the
// user asks: first by the hash of its weights (`sshs_model_hash` in the
// file, Civitai's "AutoV3"), then by its file name.

import Foundation

public struct CivitaiModel: Equatable, Sendable {
    public var modelID: Int
    public var versionID: Int
    public var name: String
    public var version: String
    public var baseModel: String
    public var trainedWords: [String]
    /// Plain text, without HTML.
    public var description: String
    /// The prompt of a safe example picture.
    public var samplePrompt: String?
    /// A safe example picture (Civitai's lowest rating, no videos).
    public var sampleImage: URL?

    public var link: String { "https://civitai.com/models/\(modelID)?modelVersionId=\(versionID)" }

    /// The family `baseModel` names, if Lightbox knows it.
    public var family: ModelFamily? {
        let b = baseModel.lowercased()
        if b.contains("illustrious") || b.contains("noobai") { return .illustrious }
        if b.contains("pony") { return .pony }
        if b.contains("sdxl") { return .sdxl }
        if b.contains("sd 1.") { return .sd15 }
        if b.contains("flux.2") || b.contains("flux 2") || b.contains("klein") { return .flux2 }
        if b.contains("flux.1") || b == "flux" { return .flux }
        if b.contains("zimage") || b.contains("z-image") || b.contains("z image") { return .zImage }
        if b.contains("flux") || b.contains("sd 3") || b.contains("hunyuan") || b.contains("wan") {
            return .unsupported
        }
        return nil
    }

    /// A strength named in the description ("weight 0.7").
    public var strength: Double? { LoraDetector.recommendedWeight(description) }
}

public enum CivitaiError: Error, CustomStringConvertible, Sendable {
    case http(Int)
    case badResponse

    public var description: String {
        switch self {
        case .http(let code): "Civitai answered \(code)."
        case .badResponse: "Civitai sent an answer Lightbox doesn't understand."
        }
    }
}

public struct CivitaiClient: Sendable {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = URL(string: "https://civitai.com/api/v1/")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// The model `fileName` is, found by `hash` if there is one, else by
    /// name. `nil` = not on Civitai.
    public func lookUp(fileName: String, hash: String?) async throws -> CivitaiModel? {
        if let hash, !hash.isEmpty {
            for h in [hash, String(hash.prefix(12))] {
                if var found = try await byHash(h) {
                    found.description = try await modelDescription(found.modelID) ?? found.description
                    return found
                }
            }
        }
        return try await byName(fileName)
    }

    func byHash(_ hash: String) async throws -> CivitaiModel? {
        guard let json = try await get("model-versions/by-hash/\(hash)") as? [String: Any] else { return nil }
        return Self.version(json, model: json["model"] as? [String: Any], modelID: json["modelId"] as? Int)
    }

    /// Search by the file's name; only a version with exactly this file counts.
    func byName(_ fileName: String) async throws -> CivitaiModel? {
        let file = (fileName as NSString).lastPathComponent
        let query = PresetDetector.displayName(file)
        var components = URLComponents(
            url: baseURL.appending(path: "models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "query", value: query), .init(name: "types", value: "LORA"), .init(name: "limit", value: "20"),
        ]
        guard let json = try await get(components.url!) as? [String: Any], let items = json["items"] as? [[String: Any]]
        else { return nil }
        for model in items {
            for case let version as [String: Any] in model["modelVersions"] as? [Any] ?? [] {
                let files = (version["files"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                if files.contains(where: { $0.caseInsensitiveCompare(file) == .orderedSame }) {
                    var found = Self.version(version, model: model, modelID: model["id"] as? Int)
                    if let text = model["description"] as? String { found?.description = Self.plainText(text) }
                    return found
                }
            }
        }
        return nil
    }

    func modelDescription(_ id: Int) async throws -> String? {
        guard let json = try? await get("models/\(id)") as? [String: Any], let html = json["description"] as? String
        else { return nil }
        return Self.plainText(html)
    }

    static func version(_ v: [String: Any], model: [String: Any]?, modelID: Int?) -> CivitaiModel? {
        guard let versionID = v["id"] as? Int, let modelID = modelID ?? v["modelId"] as? Int else { return nil }
        let images = v["images"] as? [[String: Any]] ?? []
        // Only pictures Civitai rates as safe (nsfwLevel 1).
        let safe = images.filter { ($0["nsfwLevel"] as? Int ?? 99) == 1 }
        let sample = safe.lazy.compactMap { ($0["meta"] as? [String: Any])?["prompt"] as? String }
            .first { !$0.isEmpty }
        let picture = safe.lazy.filter { ($0["type"] as? String ?? "image") == "image" }
            .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
            .first { $0.scheme == "https" }
        return CivitaiModel(
            modelID: modelID, versionID: versionID, name: model?["name"] as? String ?? "",
            version: v["name"] as? String ?? "", baseModel: v["baseModel"] as? String ?? "",
            trainedWords: (v["trainedWords"] as? [String] ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty },
            description: (v["description"] as? String).map(plainText) ?? "", samplePrompt: sample,
            sampleImage: picture)
    }

    /// Civitai descriptions are HTML.
    static func plainText(_ html: String) -> String {
        var t = html.replacingOccurrences(
            of: #"<\s*(br|/p|/li|/h\d|/div)\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<li[^>]*>"#, with: "• ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        t = t.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func get(_ path: String) async throws -> Any? {
        try await get(baseURL.appending(path: path))
    }

    private func get(_ url: URL) async throws -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CivitaiError.badResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CivitaiError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw CivitaiError.badResponse }
        return json
    }
}

extension LoraNote {
    /// Take over what Civitai knows: link, trigger words, family, a named
    /// strength and a sample prompt; its description goes on top of the notes.
    public mutating func merge(_ c: CivitaiModel) {
        link = c.link
        if !c.trainedWords.isEmpty { triggers = c.trainedWords.joined(separator: ", ") }
        if let f = c.family { family = f }
        if let s = c.strength { strength = s }
        if let sample = c.samplePrompt, !sample.isEmpty { samplePrompt = sample }
        var block = "Civitai: \(c.name)" + (c.version.isEmpty ? "" : " · \(c.version)")
        if !c.baseModel.isEmpty { block += " (\(c.baseModel))" }
        // One paragraph, so the block can be found again.
        let text = c.description.replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)
        if !text.isEmpty { block += "\n" + String(text.prefix(1200)) }
        // A new lookup replaces the earlier Civitai block.
        let rest = notes.components(separatedBy: "\n\n").filter { !$0.hasPrefix("Civitai: ") }
        notes = ([block] + rest).filter { !$0.isEmpty }.joined(separator: "\n\n")
        edited = true
    }
}

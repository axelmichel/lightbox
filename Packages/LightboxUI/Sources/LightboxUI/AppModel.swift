import ComfyKit
import CoreGraphics
import Foundation
import LightboxCore
import Observation

/// App-wide state: the server connection, what it offers, the presets, the
/// gallery and the Generate form.
@MainActor @Observable
public final class AppModel {
    public enum Connection: Equatable {
        case idle
        case connecting
        case connected(SystemStats)
        case failed(String)
    }

    public enum HelperStatus: Equatable {
        case idle
        case checking
        case ready
        case failed(String)
    }

    /// Per device (UserDefaults): the Mac and the iPad may reach the PC differently.
    public var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.addressKey) }
    }
    public private(set) var connection: Connection = .idle
    public private(set) var client: ComfyClient?
    public private(set) var catalog = ComfyCatalog()

    public var library: Library {
        didSet { if library != oldValue { LibraryStore.save(library) } }
    }
    /// Checkpoints being looked at by the preset detector.
    public private(set) var detecting: Set<String> = []
    /// What the LoRA detector found, by file name.
    public private(set) var loraInfo: [String: LoraInfo] = [:]

    public let gallery: GalleryModel
    /// Compositions made of gallery pictures, and the one being edited.
    public let compositions: CompositionsModel
    /// The node editor's saved workflows.
    public let workflows: WorkflowsModel
    public let generation = GenerationModel()

    /// The presets editor is open.
    public var showingPresets = false

    /// Ollama, for the prompt helper; per device like the ComfyUI address.
    /// Empty = `OllamaClient.defaultAddress`.
    public var ollamaAddress: String {
        didSet {
            UserDefaults.standard.set(ollamaAddress, forKey: Self.ollamaAddressKey)
            ollamaModels = []
            ollamaStatus = .idle
        }
    }
    /// The model that rewrites prompts; empty = the helper is off.
    public var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Self.ollamaModelKey) }
    }
    public private(set) var ollamaModels: [String] = []
    public private(set) var ollamaStatus: HelperStatus = .idle

    /// Style previews, by modifier id.
    public private(set) var previews: [UUID: CGImage] = [:]

    private static let addressKey = "comfyServerAddress"
    private static let ollamaAddressKey = "ollamaAddress"
    private static let ollamaModelKey = "ollamaModel"

    public init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        ollamaAddress = UserDefaults.standard.string(forKey: Self.ollamaAddressKey) ?? ""
        ollamaModel = UserDefaults.standard.string(forKey: Self.ollamaModelKey) ?? ""
        library = LibraryStore.load()
        gallery = GalleryModel(store: GalleryStore(root: LibraryStore.folder.appending(path: "Gallery")))
        compositions = CompositionsModel(store: CompositionStore(root: gallery.store.root), gallery: gallery)
        workflows = WorkflowsModel(store: WorkflowStore(root: gallery.store.root))
        previews = PreviewStore.loadAll(
            library.modifiers.map(\.id) + library.loraNotes.values.compactMap(\.picture))
        gallery.recoverOrphans(rating: library.rating, presets: library.presets)
        if !serverAddress.isEmpty {
            Task { await connect() }
        }
    }

    public var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    public func connect() async {
        connection = .connecting
        do {
            let url = try ComfyServer.normalizedURL(from: serverAddress)
            let client = ComfyClient(baseURL: url)
            let stats = try await client.systemStats()
            catalog = try await client.catalog()
            self.client = client
            connection = .connected(stats)
        } catch {
            client = nil
            connection = .failed(Self.describe(error))
            return
        }
        await addPresetsForNewCheckpoints()
    }

    /// Re-read the model lists (after adding files on the server).
    public func refreshCatalog() async {
        guard let client else { return }
        loraInfo = [:]
        do {
            catalog = try await client.catalog()
        } catch {
            connection = .failed(Self.describe(error))
            return
        }
        await addPresetsForNewCheckpoints()
    }

    /// A detected preset for each checkpoint new on the server (all of them
    /// on the first connection). Unsupported models are skipped; they can
    /// still be added in the presets editor.
    func addPresetsForNewCheckpoints() async {
        let new = library.newCheckpoints(models)
        guard !new.isEmpty else { return }
        let added = await addDetectedPresets(for: new, skipUnsupported: true)
        guard !added.isEmpty else { return }
        generation.notice =
            added.count == 1
            ? "New on the server: a preset for “\(added[0].name)” was added."
            : "New on the server: presets for \(added.map { "“\($0.name)”" }.joined(separator: ", ")) were added."
    }

    // MARK: - Presets

    /// Every model file a preset can use: checkpoints, then diffusion
    /// models (Flux, Z-Image) that need separate text encoders.
    public var models: [String] {
        catalog.checkpoints + catalog.diffusionModels.filter { !catalog.checkpoints.contains($0) }
    }

    /// Look at a checkpoint: its header metadata (if the server can read
    /// it), its name, and the LoRAs it will be used with.
    public func detect(checkpoint: String, loras: [String] = []) async -> Detection {
        detecting.insert(checkpoint)
        defer { detecting.remove(checkpoint) }
        let diffusion = !catalog.checkpoints.contains(checkpoint) && catalog.diffusionModels.contains(checkpoint)
        // The server reads the header of safetensors files only.
        let metadata =
            checkpoint.lowercased().hasSuffix(".gguf")
            ? nil
            : try? await client?.modelMetadata(
                folder: diffusion ? "diffusion_models" : "checkpoints", filename: checkpoint)
        return PresetDetector.detect(
            checkpoint: checkpoint, metadata: metadata, loras: loras, diffusionModel: diffusion)
    }

    /// Flux and Z-Image: pick the text encoders and VAE from the server's
    /// files where the preset has none yet, with a note on each.
    func fillSplitParts(_ preset: inout GenerationPreset) {
        guard preset.family.isSplit else { return }
        let choice = SplitParts.choose(
            for: preset.family, model: preset.checkpoint, textEncoders: catalog.textEncoders, vaes: catalog.vaes)
        if preset.textEncoders.count != preset.family.textEncoderCount { preset.textEncoders = choice.textEncoders }
        if preset.vae?.isEmpty ?? true { preset.vae = choice.vae }
        preset.detectionNotes += choice.notes
    }

    /// Look at a LoRA: what it was trained for, its trigger words and a
    /// starting strength. Kept until the model lists are reloaded.
    @discardableResult
    public func inspectLora(_ name: String) async -> LoraInfo? {
        guard !name.isEmpty else { return nil }
        if let known = loraInfo[name] { return known }
        guard let client else { return LoraDetector.detect(name: name) }
        do {
            let metadata = try await client.modelMetadata(folder: "loras", filename: name)
            let info = LoraDetector.detect(name: name, metadata: metadata)
            loraInfo[name] = info
            // The info page starts from what the file says, until it is edited.
            if library.loraNotes[name]?.edited != true {
                var fresh = LoraNote(detected: info, name: name)
                fresh.picture = library.loraNotes[name]?.picture
                library.loraNotes[name] = fresh
            }
            return info
        } catch {
            return LoraDetector.detect(name: name)
        }
    }

    /// Add a detected preset for each checkpoint that has none yet. Returns
    /// the new presets.
    @discardableResult
    public func addDetectedPresets(for checkpoints: [String], skipUnsupported: Bool = false) async
        -> [GenerationPreset]
    {
        var added: [GenerationPreset] = []
        for checkpoint in checkpoints where !library.presets.contains(where: { $0.checkpoint == checkpoint }) {
            let detection = await detect(checkpoint: checkpoint)
            // Not marked as seen while unsupported, so it is offered again
            // once a later version can load it.
            if skipUnsupported, !detection.family.isSupported { continue }
            library.knownCheckpoints.insert(checkpoint)
            var preset = detection.preset(checkpoint: checkpoint)
            fillSplitParts(&preset)
            library.presets.append(preset)
            added.append(preset)
        }
        if generation.presetID == nil { generation.presetID = library.presets.first?.id }
        return added
    }

    /// Replace a preset's settings with the suggested ones for its
    /// checkpoint and LoRAs.
    public func suggestSettings(for presetID: UUID) async {
        guard let preset = library.presets.first(where: { $0.id == presetID }), !preset.checkpoint.isEmpty else {
            return
        }
        let loras = (preset.loras + library.extraLoras).filter(\.isActive).map(\.name)
        let detection = await detect(checkpoint: preset.checkpoint, loras: loras)
        guard let i = library.presets.firstIndex(where: { $0.id == presetID }) else { return }
        detection.apply(to: &library.presets[i])
        fillSplitParts(&library.presets[i])
    }

    // MARK: - LoRA notes

    /// Fill a LoRA's note in again from its file, dropping the user's edits.
    /// The picture stays.
    public func resetLoraNote(_ name: String) async {
        let picture = library.loraNotes[name]?.picture
        library.loraNotes[name] = nil
        loraInfo[name] = nil
        if let info = await inspectLora(name), library.loraNotes[name] == nil {
            library.loraNotes[name] = LoraNote(detected: info, name: name)
        }
        library.loraNotes[name]?.picture = picture
    }

    // MARK: - LoRA pictures

    public func loraPicture(_ name: String) -> CGImage? {
        library.loraNotes[name]?.picture.flatMap { previews[$0] }
    }

    /// Use `image` (PNG or JPEG data) as the LoRA's picture.
    public func setLoraPicture(_ name: String, image: Data) {
        var note =
            library.loraNotes[name] ?? loraInfo[name].map { LoraNote(detected: $0, name: name) } ?? LoraNote(name: name)
        let id = note.picture ?? UUID()
        setPreview(id, image: image)
        guard previews[id] != nil else { return }
        note.picture = id
        library.loraNotes[name] = note
    }

    public func removeLoraPicture(_ name: String) {
        guard let id = library.loraNotes[name]?.picture else { return }
        removePreview(id)
        library.loraNotes[name]?.picture = nil
    }

    /// A slot for a LoRA picked in the chooser: its trigger words and
    /// strength from the info page if edited there, else from the file.
    public func slot(forPicked name: String) async -> LoraSlot {
        let info = await inspectLora(name)
        if let note = library.loraNotes[name], note.edited {
            return LoraSlot(
                name: name, strength: note.strength, clipStrength: note.clipStrength, triggers: note.triggers)
        }
        return LoraSlot(name: name, strength: info?.strength ?? 0.8, triggers: info?.triggers.first ?? "")
    }

    /// Look a LoRA up on Civitai and take over what it says. Returns what
    /// happened, for the info page.
    public func lookUpOnCivitai(_ name: String) async -> String {
        let info = await inspectLora(name)
        let file = (name as NSString).lastPathComponent
        do {
            guard let found = try await CivitaiClient().lookUp(fileName: file, hash: info?.modelHash) else {
                return info?.modelHash == nil
                    ? "Not found on Civitai: the file has no weight hash, and no Civitai LoRA has a file named “\(file)”."
                    : "Not found on Civitai."
            }
            var note =
                library.loraNotes[name] ?? info.map { LoraNote(detected: $0, name: name) } ?? LoraNote(name: name)
            note.merge(found)
            library.loraNotes[name] = note
            // A safe example picture, if the LoRA has none yet.
            if note.picture == nil, let url = found.sampleImage,
                let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                setLoraPicture(name, image: data)
                if loraPicture(name) != nil { return "Found “\(found.name)” on Civitai, with an example picture." }
            }
            return "Found “\(found.name)” on Civitai."
        } catch {
            if let e = error as? CivitaiError { return e.description }
            return "Could not reach Civitai: \(error.localizedDescription)"
        }
    }

    // MARK: - Styles

    /// Use `image` (PNG or JPEG data) as a style's preview.
    public func setPreview(_ id: UUID, image: Data) {
        guard let jpeg = PreviewStore.save(image, for: id), let cg = decode(jpeg) else {
            gallery.problem = "Could not make a preview from that picture."
            return
        }
        previews[id] = cg
    }

    public func removePreview(_ id: UUID) {
        PreviewStore.remove(id)
        previews[id] = nil
    }

    public func deleteModifier(_ id: UUID) {
        guard let m = library.modifier(id), !m.builtIn else { return }
        library.modifiers.removeAll { $0.id == id }
        removePreview(id)
        for (category, chosen) in generation.modifierIDs where chosen == id { generation.modifierIDs[category] = nil }
    }

    // MARK: - Prompt helper

    public var ollama: OllamaClient? { try? OllamaClient(address: ollamaAddress) }

    /// Ask Ollama which models it has.
    public func checkOllama() async {
        guard let ollama else {
            ollamaStatus = .failed("“\(ollamaAddress)” is not a valid address.")
            return
        }
        ollamaStatus = .checking
        do {
            ollamaModels = try await ollama.models()
            ollamaStatus = .ready
            if ollamaModel.isEmpty, let first = ollamaModels.first { ollamaModel = first }
        } catch {
            ollamaModels = []
            ollamaStatus = .failed(Self.describeOllama(error, address: ollama.baseURL))
        }
    }

    static func describeOllama(_ error: any Error, address: URL) -> String {
        if let e = error as? OllamaError { return e.description }
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost:
                return
                    "Cannot reach Ollama at \(address.host() ?? address.absoluteString). Is it running (ollama serve)?"
            default:
                return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Reuse

    /// Fill the Generate form with the settings a picture was made with,
    /// guides included. A deleted preset is added back; a missing guide
    /// picture is listed. The content rating is not changed. Generating
    /// still goes through `compose()`.
    public func useSettings(of recipe: GenerationRecipe, includingSeed: Bool = true) {
        var notes: [String] = []
        let gen = generation
        if let stored = library.presets.first(where: { $0.id == recipe.preset.id }) {
            if !Self.sameSettings(stored, recipe.preset) {
                notes.append("The preset “\(stored.name)” was changed since; its current settings are used.")
            }
        } else {
            var restored = recipe.preset
            restored.name += " (restored)"
            library.presets.append(restored)
            notes.append("The preset “\(recipe.preset.name)” had been deleted; it was added back.")
        }
        gen.presetID = recipe.preset.id
        let preset = gen.preset(in: library)
        let size = ImageSize(width: recipe.preset.width, height: recipe.preset.height)
        gen.size = size == preset.map { ImageSize(width: $0.width, height: $0.height) } ? nil : size
        gen.prompt = recipe.prompt
        gen.negative = recipe.negative
        gen.modifierIDs = [:]
        for m in recipe.modifiers {
            if library.modifier(m.id) == nil {
                library.modifiers.append(m)
                notes.append("The style “\(m.name)” had been deleted; it was added back.")
            }
            gen.modifierIDs[m.category] = m.id
        }
        gen.seedText = includingSeed ? String(recipe.seed) : ""
        library.extraLoras = recipe.extraLoras
        library.finish = recipe.finish
        let images = gallery.store.guideImages(of: recipe)
        var guides: [Guide] = []
        for use in recipe.guides {
            guard let kind = ControlKind(rawValue: use.kind), let data = images[use.image], let image = decode(data)
            else {
                notes.append("A \(use.kind) guide's picture is missing.")
                continue
            }
            guides.append(
                Guide(
                    kind: kind, data: data, filename: use.image, image: image, extract: use.extract,
                    strength: use.strength, startPercent: use.startPercent, endPercent: use.endPercent))
        }
        gen.guides = guides
        if recipe.rating != library.rating {
            notes.append("It was made with the rating \(recipe.rating.label); the current rating stays.")
        }
        let lead = includingSeed ? "Settings loaded, including the seed." : "Settings loaded with a new seed."
        gen.notice = ([lead] + notes).joined(separator: " ")
        gen.focusRequests += 1
    }

    /// Add gallery pictures as guides of `kind` and show the Generate form.
    public func useAsGuides(_ ids: some Collection<UUID>, kind: ControlKind) {
        let gen = generation
        let before = gen.guides.count
        for id in ids {
            if let png = gallery.pngData(id) { gen.addGuide(kind, data: png, name: "\(id.uuidString).png") }
        }
        let added = gen.guides.count - before
        guard added > 0 else { return }
        gen.notice = added == 1 ? "Added a \(kind.title) guide." : "Added \(added) \(kind.title) guides."
        gen.focusRequests += 1
    }

    public func useSeed(of recipe: GenerationRecipe) {
        generation.seedText = String(recipe.seed)
        generation.notice = "Seed \(recipe.seed) set."
    }

    /// Presets compared without the size (which a generation may override)
    /// and the detector's notes.
    static func sameSettings(_ a: GenerationPreset, _ b: GenerationPreset) -> Bool {
        var a = a
        var b = b
        (a.width, a.height, a.detectionNotes, a.name) = (0, 0, [], "")
        (b.width, b.height, b.detectionNotes, b.name) = (0, 0, [], "")
        return a == b
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? ComfyError { return e.description }
        if let e = error as? GalleryError { return e.description }
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut:
                return "Cannot reach the server. Is ComfyUI running with --listen, and is the address right?"
            case .notConnectedToInternet:
                return "No network connection."
            default:
                return e.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Style previews: small JPEGs in Application Support, by modifier id.
enum PreviewStore {
    static var folder: URL { LibraryStore.folder.appending(path: "Previews") }
    static func url(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).jpg") }

    static func loadAll(_ ids: [UUID]) -> [UUID: CGImage] {
        var out: [UUID: CGImage] = [:]
        for id in ids {
            if let data = try? Data(contentsOf: url(id)), let image = decode(data) { out[id] = image }
        }
        return out
    }

    /// Write a preview made from `image`; returns the JPEG written.
    static func save(_ image: Data, for id: UUID) -> Data? {
        guard let jpeg = GalleryStore.thumbnail(image, maxPixels: 384) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try jpeg.write(to: url(id), options: .atomic)
            return jpeg
        } catch {
            return nil
        }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}

/// Presets and settings as one JSON file in Application Support.
enum LibraryStore {
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "Lightbox") }
    static var url: URL { folder.appending(path: "library.json") }

    static func load() -> Library {
        guard let data = try? Data(contentsOf: url), let lib = try? JSONDecoder().decode(Library.self, from: data)
        else { return Library() }
        return lib
    }

    static func save(_ library: Library) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(library).write(to: url, options: .atomic)
        } catch {
            print("Lightbox: could not save the library: \(error)")
        }
    }
}

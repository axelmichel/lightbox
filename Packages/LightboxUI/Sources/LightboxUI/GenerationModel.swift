import ComfyKit
import CoreGraphics
import Foundation
import LightboxCore
import Observation

/// A picture that guides the generation, used the way `kind` says.
public struct Guide: Identifiable {
    public let id = UUID()
    public var kind: ControlKind
    public var data: Data
    /// Name it gets in ComfyUI's input folder and in the gallery.
    public var filename: String
    public var image: CGImage
    /// Run the kind's extractor (lines, depth, pose) on the picture first.
    public var extract = true
    public var strength: Double
    public var startPercent = 0.0
    public var endPercent = 1.0
}

public struct ImageSize: Hashable, Sendable {
    public var width: Int
    public var height: Int
}

/// The Generate form and the generation running on the server. Finished
/// pictures go straight into the gallery folder that is shown.
@MainActor @Observable
public final class GenerationModel {
    public enum State: Equatable {
        case idle
        case running(String)
        case failed(String)
    }

    public var presetID: UUID?
    /// The saved workflow the node graph shows, per preset; none: the
    /// standard graph, made from the preset each time. Kept on this device.
    public private(set) var workflowChoices: [UUID: UUID] = GenerationModel.loadChoices() {
        didSet { Self.saveChoices(workflowChoices) }
    }
    public var prompt = ""
    public var negative = ""
    /// The camera, light, film or comic style picked per category. Only
    /// the categories that fit the preset's style are used.
    public var modifierIDs: [ModifierCategory: UUID] = [:]
    public var guides: [Guide] = []
    /// Empty = a new random seed for every run.
    public var seedText = ""
    /// `nil` = the preset's size.
    public var size: ImageSize?
    /// Pictures per run; they share the seed.
    public var batchSize = 1
    /// Shown above the form, e.g. what loading a picture's settings did.
    public var notice: String?
    /// Counts requests to show the form (after "Use Settings").
    public var focusRequests = 0

    public private(set) var state: State = .idle
    /// What the server is doing right now ("Drawing", "Fixing faces").
    public private(set) var stage = ""
    public private(set) var step = 0
    public private(set) var totalSteps = 0
    public private(set) var preview: CGImage?
    /// The style whose preview is being rendered.
    public private(set) var renderingPreview: UUID?

    /// Prompt helper: an extra wish for the rewrite ("make it rainy").
    public var enhanceDirection = ""
    public private(set) var enhancing = false
    /// The rewritten prompt, waiting to be used or discarded.
    public var suggestion: String?
    /// The prompt before the last suggestion was used, for Undo.
    public private(set) var promptBeforeSuggestion: String?

    private var task: Task<Void, Never>?

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public func preset(in library: Library) -> GenerationPreset? {
        library.presets.first { $0.id == presetID } ?? library.presets.first
    }

    /// The preset with the changes of the workflow shown in the node graph:
    /// what is generated with. The preset itself stays as it is.
    public func effectivePreset(_ app: AppModel) -> GenerationPreset? {
        guard let preset = preset(in: app.library) else { return nil }
        return shownWorkflow(app, preset: preset).map { $0.overrides.applied(to: preset) } ?? preset
    }

    /// The styles picked that fit `preset`, in category order.
    public func activeModifiers(for preset: GenerationPreset, in library: Library) -> [StyleModifier] {
        ModifierCategory.active(for: preset.style).compactMap { modifier(for: $0, in: library) }
    }

    /// The style picked for `category`, if it still exists and still is one.
    public func modifier(for category: ModifierCategory, in library: Library) -> StyleModifier? {
        library.modifier(modifierIDs[category]).flatMap { $0.category == category ? $0 : nil }
    }

    /// Compose the prompt for display; the reason when the guard refuses.
    public func previewPrompt(_ app: AppModel) -> Result<ComposedPrompt, GuardError>? {
        guard let preset = preset(in: app.library) else { return nil }
        return Result { () throws(GuardError) in try compose(input(preset, app.library)) }
    }

    // MARK: - Guides

    public func addGuide(_ kind: ControlKind, data: Data, name: String) {
        guard let image = decode(data) else {
            return showError("“\(name)” is not an image this device can read.")
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let token = UUID().uuidString.prefix(8)
        guides.append(
            Guide(
                kind: kind, data: data, filename: "guide-\(token).\(ext.isEmpty ? "png" : ext)", image: image,
                strength: kind.defaultStrength))
    }

    public func replacePicture(of id: Guide.ID, data: Data, name: String) {
        guard let i = guides.firstIndex(where: { $0.id == id }), let image = decode(data) else {
            return showError("“\(name)” is not an image this device can read.")
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guides[i].data = data
        guides[i].image = image
        // A new name, so the gallery keeps the old picture for earlier recipes.
        guides[i].filename = "guide-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "png" : ext)"
    }

    public func removeGuide(_ id: Guide.ID) {
        guides.removeAll { $0.id == id }
    }

    /// How a guide will be realized on the server, or what is missing.
    public func setup(for kind: ControlKind, _ app: AppModel) -> Result<ControlSetup, MissingModel> {
        let arch = preset(in: app.library)?.family.arch ?? .sdxl
        return ControlResolver.resolve(kind, arch: arch, catalog: app.catalog)
    }

    // MARK: - Running

    public func generate(_ app: AppModel) {
        guard !isRunning else { return }
        guard let client = app.client else { return fail("Not connected to ComfyUI. Check the Settings.") }
        guard let preset = effectivePreset(app) else { return fail("Create a preset first.") }
        if let problem = preset.problem(with: app.catalog) { return fail(problem) }
        if !guides.isEmpty, !preset.family.supportsGuides {
            return fail("Guides don't work with \(preset.family.label) models yet; remove them to generate.")
        }
        let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) ?? Int.random(in: 0...Int(UInt32.max))
        let prepared: Prepared
        switch prepare(preset, seed: seed, app) {
        case .success(let p): prepared = p
        case .failure(let problem): return fail(problem.message)
        }
        let (recipe, guideImages) = (prepared.recipe, prepared.guideImages)
        totalSteps = prepared.preset.steps
        let gallery = app.gallery
        run(prepared.request, client: client, catalog: app.catalog) { images in
            gallery.add(
                images.enumerated().map { index, image in
                    var own = recipe
                    own.batchIndex = index
                    return (image.data, own)
                }, guides: guideImages)
        }
    }

    /// What a run of the form sends, and what the gallery keeps of it.
    struct Prepared {
        /// The preset at the size used.
        var preset: GenerationPreset
        var request: GenerationRequest
        var recipe: GenerationRecipe
        var guideImages: [String: Data]
        /// Why the guard refused the prompt, when it was left out to show
        /// the graph anyway.
        var refusal: String?
    }

    struct Problem: Error {
        var message: String
    }

    /// The request the form makes with `preset`: the prompt composed (and
    /// so checked by the guard), the guides resolved, the finish applied.
    /// With `showingRefused`, a prompt the guard refuses is left empty
    /// instead of failing, so the graph can be shown with the reason. Such a
    /// request has no text from the user in it and is never sent.
    func prepare(_ preset: GenerationPreset, seed: Int, _ app: AppModel, showingRefused: Bool = false)
        -> Result<Prepared, Problem>
    {
        var preset = preset
        // The preset only gives the default size; the recipe records the one used.
        if let size {
            preset.width = size.width
            preset.height = size.height
        }

        let input = input(preset, app.library)
        let prompt: ComposedPrompt
        var refusal: String?
        do {
            prompt = try compose(input)
        } catch {
            guard showingRefused else { return .failure(Problem(message: error.description)) }
            prompt = ComposedPrompt(positive: "", negative: "", loras: composedLoras(input))
            refusal = error.description
        }

        var guideRequests: [GuideRequest] = []
        for guide in guides {
            switch setup(for: guide.kind, app) {
            case .success(let setup):
                guideRequests.append(
                    GuideRequest(
                        setup: setup, image: guide.data, filename: guide.filename, extract: guide.extract,
                        strength: guide.strength, startPercent: guide.startPercent, endPercent: guide.endPercent))
            case .failure(let missing):
                return .failure(Problem(message: "\(guide.kind.title) guide: \(missing.message)"))
            }
        }
        let guideUses = guides.map {
            GenerationRecipe.GuideUse(
                kind: $0.kind.rawValue, strength: $0.strength, startPercent: $0.startPercent,
                endPercent: $0.endPercent, extract: $0.extract, image: $0.filename)
        }
        let guideImages = Dictionary(guides.map { ($0.filename, $0.data) }, uniquingKeysWith: { a, _ in a })

        let finish = app.library.finish
        let catalog = app.catalog
        let guideSize = preset.family == .sd15 ? 512 : 1024
        // The face/hand fix samples with a KSampler, which Flux 2's schedule doesn't fit.
        let canFix = catalog.hasDetailer && preset.family != .flux2
        let faceDetector = canFix && finish.fixFaces ? catalog.faceDetector : nil
        let handDetector = canFix && finish.fixHands ? catalog.handDetector : nil
        var server = app.serverAddress
        if case .connected(let stats) = app.connection, let version = stats.system.comfyuiVersion {
            server += " · ComfyUI \(version)"
        }
        let recipe = GenerationRecipe(
            input: input, sent: prompt, seed: seed, finish: finish, guides: guideUses, faceDetector: faceDetector,
            handDetector: handDetector, server: server)
        let request = preset.request(
            prompt, seed: seed, batchSize: batchSize, guides: guideRequests,
            faceFix: faceDetector.map {
                DetailerRequest(detector: $0, denoise: finish.faceStrength, guideSize: guideSize)
            },
            handFix: handDetector.map {
                DetailerRequest(detector: $0, denoise: finish.handStrength, guideSize: guideSize)
            })

        return .success(
            Prepared(preset: preset, request: request, recipe: recipe, guideImages: guideImages, refusal: refusal))
    }

    /// What the node graph shows.
    struct GraphState {
        var doc: WorkflowDocument
        /// The saved workflow shown, brought up to date with the form.
        var workflow: WorkflowEntry?
        /// Why the guard refused the prompt; the prompt nodes are empty then.
        var refusal: String?
        /// No seed typed: each run picks one, the graph shows 0.
        var randomSeed: Bool
    }

    /// What the form would send now, as a node-editor document.
    func graph(_ app: AppModel) -> Result<GraphState, Problem> {
        guard let preset = effectivePreset(app) else { return .failure(Problem(message: "Create a preset first.")) }
        let typed = Int(seedText.trimmingCharacters(in: .whitespaces))
        return prepare(preset, seed: typed ?? 0, app, showingRefused: true).flatMap { prepared in
            let built = WorkflowBuilder.build(prepared.request, catalog: app.catalog)
            let workflow = shownWorkflow(app, preset: preset)
            return Result { () throws(WorkflowDocumentError) in try WorkflowDocument(built, catalog: app.catalog) }
                .map { standard in
                    // A saved workflow keeps its layout and takes the form's values.
                    let doc = workflow.flatMap { app.workflows.document($0.id) }?.reconciled(with: standard)
                    return GraphState(
                        doc: doc ?? standard, workflow: doc == nil ? nil : workflow, refusal: prepared.refusal,
                        randomSeed: typed == nil)
                }
                .mapError { Problem(message: $0.description) }
        }
    }

    /// What the form holds that the node graph can change.
    func graphTarget(_ app: AppModel) -> GraphTarget? {
        guard let preset = preset(in: app.library) else { return nil }
        var t = GraphTarget(preset: preset)
        t.overrides = shownWorkflow(app, preset: preset)?.overrides ?? PresetOverrides()
        t.size = size
        t.seedText = seedText
        t.extraLoras = app.library.extraLoras
        t.guides = guides.map {
            GraphTarget.GuideReach(strength: $0.strength, start: $0.startPercent, end: $0.endPercent)
        }
        t.finish = app.library.finish
        return t
    }

    /// Values changed in the node graph go into the form. Preset values
    /// become the shown workflow's overrides; on the standard graph that
    /// workflow is saved first (`saveStandard` gives its id).
    func applyGraph(_ changes: [GraphChange], _ app: AppModel, saveStandard: () -> UUID?) {
        guard !changes.isEmpty, var t = graphTarget(app) else { return }
        let before = t
        for change in changes { t.apply(change) }
        size = t.size
        seedText = t.seedText
        if app.library.extraLoras != t.extraLoras { app.library.extraLoras = t.extraLoras }
        for (i, reach) in t.guides.enumerated() where guides.indices.contains(i) {
            (guides[i].strength, guides[i].startPercent, guides[i].endPercent) = (
                reach.strength, reach.start, reach.end
            )
        }
        if app.library.finish != t.finish { app.library.finish = t.finish }
        guard t.overrides != before.overrides else { return }
        let id = shownWorkflow(app, preset: t.preset)?.id ?? saveStandard()
        if let id {
            showWorkflow(id, app)
            app.workflows.setOverrides(id, t.overrides)
        }
    }

    /// Show workflow `id` (`nil`: the standard graph) for the current preset.
    func showWorkflow(_ id: UUID?, _ app: AppModel) {
        guard let preset = preset(in: app.library) else { return }
        workflowChoices[preset.id] = id
    }

    /// A deleted workflow is no one's choice any more.
    func forgetWorkflow(_ id: UUID) {
        workflowChoices = workflowChoices.filter { $0.value != id }
    }

    /// Undo one change of the shown workflow (`nil`: all of them).
    func resetOverride(_ field: PresetOverrides.Field?, _ app: AppModel) {
        guard let preset = preset(in: app.library), let workflow = shownWorkflow(app, preset: preset) else { return }
        var o = workflow.overrides
        if let field { o.reset(field) } else { o = PresetOverrides() }
        app.workflows.setOverrides(workflow.id, o)
    }

    /// Make the shown workflow's changes the preset's own. They then go from
    /// the workflow, and from the preset's other workflows where they now
    /// equal the preset.
    func saveOverridesToPreset(_ app: AppModel) {
        guard let preset = preset(in: app.library), let workflow = shownWorkflow(app, preset: preset),
            let i = app.library.presets.firstIndex(where: { $0.id == preset.id })
        else { return }
        let updated = workflow.overrides.applied(to: preset)
        app.library.presets[i] = updated
        for entry in app.workflows.entries(for: preset.id) {
            app.workflows.setOverrides(entry.id, entry.overrides.trimmed(for: updated))
        }
        app.workflows.setOverrides(workflow.id, PresetOverrides())
    }

    private static let choicesKey = "nodeWorkflowChoices"

    private static func loadChoices() -> [UUID: UUID] {
        let stored = UserDefaults.standard.dictionary(forKey: choicesKey) as? [String: String] ?? [:]
        return Dictionary(
            stored.compactMap { key, value in
                UUID(uuidString: key).flatMap { k in UUID(uuidString: value).map { (k, $0) } }
            },
            uniquingKeysWith: { a, _ in a })
    }

    private static func saveChoices(_ choices: [UUID: UUID]) {
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: choices.map { ($0.key.uuidString, $0.value.uuidString) }),
            forKey: choicesKey)
    }

    /// The chosen workflow, if it is the preset's or has no preset.
    func shownWorkflow(_ app: AppModel, preset: GenerationPreset) -> WorkflowEntry? {
        guard let entry = workflowChoices[preset.id].flatMap(app.workflows.entry) else { return nil }
        let presets = Set(app.library.presets.map(\.id))
        let fits = entry.presetID == preset.id || entry.presetID.map { !presets.contains($0) } ?? true
        return fits ? entry : nil
    }

    /// Make a small sample picture with `modifier` and keep it as the
    /// style's preview, not in the gallery. Uses the current preset if its
    /// style fits, else the first preset that does.
    public func renderPreview(of modifier: StyleModifier, _ app: AppModel) {
        guard !isRunning else { return }
        guard let client = app.client else { return fail("Not connected to ComfyUI. Check the Settings.") }
        let fits = { (p: GenerationPreset) in
            modifier.category.applies(to: p.style) && p.problem(with: app.catalog) == nil
        }
        guard
            var preset = preset(in: app.library).flatMap({ fits($0) ? $0 : nil })
                ?? app.library.presets.first(where: fits)
        else {
            let kind = modifier.category == .comic ? "an anime or illustration" : "a photo"
            return fail("A preview of “\(modifier.name)” needs \(kind) preset.")
        }
        // Small and quick: about 512 pixels on the short side.
        let scale = 512.0 / Double(min(preset.width, preset.height))
        preset.width = max(64, Int(Double(preset.width) * scale) / 8 * 8)
        preset.height = max(64, Int(Double(preset.height) * scale) / 8 * 8)
        let sample =
            preset.dialect == .tags
            ? "1girl, solo, city street, upper body, looking at viewer"
            : "A woman standing on a city street, upper body, looking at the camera"
        let input = PromptInput(
            preset: preset, prompt: sample, extraLoras: [], modifiers: [modifier], rating: app.library.rating)
        let prompt: ComposedPrompt
        do {
            prompt = try compose(input)
        } catch {
            return fail(error.description)
        }
        let request = preset.request(prompt, seed: 20_261_125)
        totalSteps = preset.steps
        renderingPreview = modifier.id
        run(request, client: client, catalog: app.catalog) { [weak app] images in
            if let first = images.first { app?.setPreview(modifier.id, image: first.data) }
        }
    }

    private func run(
        _ request: GenerationRequest, client: ComfyClient, catalog: ComfyCatalog,
        finished: @escaping ([GeneratedImage]) -> Void
    ) {
        preview = nil
        stage = ""
        step = 0
        state = .running("Sending…")
        notice = nil
        task = Task {
            do {
                for try await event in client.generate(request, catalog: catalog) {
                    handle(event, finished: finished)
                }
                if isRunning { state = .idle }
            } catch {
                fail(AppModel.describe(error))
            }
            renderingPreview = nil
            task = nil
        }
    }

    // MARK: - Prompt helper

    /// Ask the Ollama model to rewrite the prompt for the preset; the
    /// result waits in `suggestion`.
    public func enhance(_ app: AppModel) async {
        guard !enhancing else { return }
        guard let preset = preset(in: app.library) else { return fail("Create a preset first.") }
        guard let ollama = app.ollama, !app.ollamaModel.isEmpty else {
            return fail("Choose a model for the prompt helper in the Settings.")
        }
        let triggers = (preset.loras + app.library.extraLoras).filter(\.isActive).map(\.triggers)
        let system = PromptEnhancer.instructions(
            preset: preset, modifiers: activeModifiers(for: preset, in: app.library), triggers: triggers,
            direction: enhanceDirection)
        let idea = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        enhancing = true
        defer { enhancing = false }
        do {
            let answer = try await ollama.chat(
                model: app.ollamaModel, system: system,
                user: idea.isEmpty ? "No idea given: suggest one fitting picture." : idea)
            let text = PromptEnhancer.clean(answer)
            if text.isEmpty { return fail("The prompt helper gave an empty answer.") }
            suggestion = text
            if case .failed = state { state = .idle }
        } catch {
            fail(AppModel.describeOllama(error, address: ollama.baseURL))
        }
    }

    /// Put the suggestion into the prompt field. It is composed and
    /// checked like anything typed.
    public func useSuggestion() {
        guard let suggestion else { return }
        promptBeforeSuggestion = prompt
        prompt = suggestion
        self.suggestion = nil
    }

    public func undoSuggestion() {
        guard let before = promptBeforeSuggestion else { return }
        prompt = before
        promptBeforeSuggestion = nil
    }

    public func cancel() {
        task?.cancel()
        state = .idle
        preview = nil
        renderingPreview = nil
    }

    private func handle(_ event: GenerationEvent, finished: ([GeneratedImage]) -> Void) {
        switch event {
        case .uploading:
            state = .running("Uploading the guide pictures…")
        case .queued:
            state = .running("Waiting in the ComfyUI queue…")
        case .started:
            state = .running("Starting…")
        case .stage(let type):
            stage = Self.stageName(type) ?? stage
            state = .running(stage)
        case .progress(let value, let total):
            step = value
            totalSteps = total
            state = .running("\(stage.isEmpty ? "Drawing" : stage) · step \(value) of \(total)")
        case .preview(let data):
            if let image = decode(data) { preview = image }
        case .finished(let images):
            finished(images)
            preview = nil
            state = .idle
        case .cancelled:
            state = .idle
        }
    }

    static func stageName(_ classType: String) -> String? {
        switch classType {
        case "CheckpointLoaderSimple", "LoraLoader", "VAELoader", "UNETLoader", "UnetLoaderGGUF", "CLIPLoader",
            "CLIPLoaderGGUF", "DualCLIPLoader", "DualCLIPLoaderGGUF":
            "Loading the model"
        case "AIO_Preprocessor", "AIO_Aux_Preprocessor", "Canny": "Reading the guides"
        case "IPAdapterAdvanced", "ControlNetApplyAdvanced": "Applying the guides"
        case "KSampler", "SamplerCustomAdvanced": "Drawing"
        case "FaceDetailer": "Fixing faces and hands"
        default: nil
        }
    }

    /// Show a problem under the form (when nothing is running).
    public func showError(_ message: String) {
        if !isRunning { state = .failed(message) }
    }

    private func fail(_ message: String) {
        state = .failed(message)
    }

    public func dismissError() {
        if case .failed = state { state = .idle }
    }

    private func input(_ preset: GenerationPreset, _ library: Library) -> PromptInput {
        PromptInput(
            preset: preset, prompt: prompt, negative: negative, extraLoras: library.extraLoras,
            modifiers: activeModifiers(for: preset, in: library), rating: library.rating)
    }
}

import ComfyKit
import Foundation
import LightboxCore
import Observation

/// The saved node-editor workflows. Each belongs to a preset; the graph
/// view shows one brought up to date with the Generate form.
@MainActor @Observable
public final class WorkflowsModel {
    let store: WorkflowStore
    public private(set) var entries: [WorkflowEntry] = []
    /// What went wrong last, for an alert.
    public var problem: String?
    /// Read once, then kept: the graph view asks on every change of the form.
    @ObservationIgnored private var documents: [UUID: WorkflowDocument] = [:]

    init(store: WorkflowStore) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            entries = try store.list()
        } catch {
            problem = "Could not read the workflows: \(error.localizedDescription)"
        }
    }

    /// The workflows of `presetID`, by name.
    func entries(for presetID: UUID) -> [WorkflowEntry] {
        entries.filter { $0.presetID == presetID }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Workflows whose preset is gone (or that never had one).
    func withoutPreset(_ presets: [GenerationPreset]) -> [WorkflowEntry] {
        let ids = Set(presets.map(\.id))
        return entries.filter { $0.presetID.map { !ids.contains($0) } ?? true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func entry(_ id: UUID) -> WorkflowEntry? { entries.first { $0.id == id } }

    func document(_ id: UUID) -> WorkflowDocument? {
        if let doc = documents[id] { return doc }
        guard let data = try? store.load(id), let doc = try? WorkflowDocument(data: data) else { return nil }
        documents[id] = doc
        return doc
    }

    /// A new workflow of `presetID`; `nil` if it couldn't be written.
    func save(_ doc: WorkflowDocument, name: String, presetID: UUID) -> WorkflowEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let entry = try store.save(
                WorkflowEntry(name: store.uniqueName(trimmed.isEmpty ? "Workflow" : trimmed), presetID: presetID),
                data: doc.data())
            documents[entry.id] = doc
            reload()
            return entry
        } catch {
            problem = "Could not save the workflow: \(error.localizedDescription)"
            return nil
        }
    }

    func uniqueName(_ base: String) -> String { store.uniqueName(base) }

    func rename(_ id: UUID, to name: String) {
        do {
            try store.rename(id, to: name)
            reload()
        } catch {
            problem = "Could not rename the workflow: \(error.localizedDescription)"
        }
    }

    func delete(_ id: UUID) {
        do {
            try store.delete(id)
            documents[id] = nil
            reload()
        } catch {
            problem = "Could not delete the workflow: \(error.localizedDescription)"
        }
    }

    /// The preset was deleted: its workflows go too, or stay without a preset.
    func presetDeleted(_ presetID: UUID, keepWorkflows: Bool) {
        do {
            try store.presetDeleted(presetID, keepWorkflows: keepWorkflows)
            if !keepWorkflows {
                for e in entries where e.presetID == presetID { documents[e.id] = nil }
            }
            reload()
        } catch {
            problem = "Could not update the preset's workflows: \(error.localizedDescription)"
        }
    }
}

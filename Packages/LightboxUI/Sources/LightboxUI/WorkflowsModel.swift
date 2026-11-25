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
    /// Counts changes to the documents, so views that read one update.
    private var revision = 0

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
        _ = revision
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

    /// Keep `doc` as workflow `id` (nodes moved in the graph view), with an
    /// undo step called `name`.
    func change(_ id: UUID, to doc: WorkflowDocument, _ name: String, undo: UndoManager?) {
        let before = document(id)
        guard before != doc, write(id, doc) else { return }
        register(id, restoring: before, name, undo)
    }

    private func register(_ id: UUID, restoring old: WorkflowDocument?, _ name: String, _ undo: UndoManager?) {
        guard let old else { return }
        undo?.registerUndo(withTarget: self) { model in
            let current = model.document(id)
            // Gone in the meantime (deleted): nothing to undo.
            guard model.write(id, old) else { return }
            model.register(id, restoring: current, name, undo)
        }
        undo?.setActionName(name)
    }

    @discardableResult
    private func write(_ id: UUID, _ doc: WorkflowDocument) -> Bool {
        guard let entry = entry(id) else { return false }
        do {
            try store.save(entry, data: doc.data())
            documents[id] = doc
            revision += 1
            reload()
            return true
        } catch {
            problem = "Could not save the workflow: \(error.localizedDescription)"
            return false
        }
    }

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

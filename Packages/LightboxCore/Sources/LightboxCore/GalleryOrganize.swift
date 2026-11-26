// Organizing the gallery: folders inside folders, tags, and search.

import Foundation

// MARK: - Nested folders

extension GalleryIndex {
    /// The folders directly in `parentID` (`nil` = at the top): as sorted
    /// by hand, then the others by name.
    public func children(of parentID: UUID?) -> [GalleryFolder] {
        folders.filter { $0.parentID == parentID }.sorted { a, b in
            if a.order != b.order { return (a.order ?? .max) < (b.order ?? .max) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Put folder `id` next to `target`, before or after it, in the folder
    /// `target` is in. The folders there keep their order from then on.
    /// Refused into the folder itself or one inside it. Returns whether
    /// anything changed.
    @discardableResult
    public mutating func placeFolder(_ id: UUID, next target: UUID, after: Bool) -> Bool {
        guard id != target, let moving = folder(id), let next = folder(target) else { return false }
        let parent = next.parentID
        if let parent, descendants(of: id).contains(parent) { return false }
        var siblings = children(of: parent).filter { $0.id != id }
        guard let at = siblings.firstIndex(where: { $0.id == target }) else { return false }
        var placed = moving
        placed.parentID = parent
        siblings.insert(placed, at: after ? at + 1 : at)
        let before = folders
        for (n, f) in siblings.enumerated() {
            guard let i = folders.firstIndex(where: { $0.id == f.id }) else { continue }
            folders[i].parentID = parent
            folders[i].order = n
        }
        return folders != before
    }

    /// `items` by folder, in the sidebar's order: those in no folder first,
    /// then each folder (folders inside others after them). Empty groups are
    /// left out; each group keeps the order of `items`.
    public func grouped(_ items: [GalleryItem]) -> [(folder: GalleryFolder?, items: [GalleryItem])] {
        let byFolder = Dictionary(grouping: items, by: \.folderID)
        let order: [GalleryFolder?] = [nil] + folderTree.map(\.folder)
        return order.compactMap { f in
            guard let inside = byFolder[f?.id], !inside.isEmpty else { return nil }
            return (f, inside)
        }
    }

    /// The folder and all folders inside it, at any depth.
    public func descendants(of id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in folders where child.parentID == next && found.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return found
    }

    /// "Trips › Lisbon": the folder's name with the folders it is in.
    public func path(of id: UUID) -> String {
        var names: [String] = []
        var current = folder(id)
        var seen: Set<UUID> = []
        while let f = current, seen.insert(f.id).inserted {
            names.insert(f.name, at: 0)
            current = folder(f.parentID)
        }
        return names.joined(separator: " › ")
    }

    /// Every folder with its depth, as a tree read from top to bottom.
    public var folderTree: [(folder: GalleryFolder, depth: Int)] {
        var out: [(GalleryFolder, Int)] = []
        func add(_ parent: UUID?, _ depth: Int) {
            for f in children(of: parent) {
                out.append((f, depth))
                add(f.id, depth + 1)
            }
        }
        add(nil, 0)
        return out
    }

    /// Put a folder into another one (`nil` = at the top). Refused when that
    /// is the folder itself or one inside it. Returns whether it moved.
    @discardableResult
    public mutating func moveFolder(_ id: UUID, into parentID: UUID?) -> Bool {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return false }
        if let parentID {
            guard folder(parentID) != nil, !descendants(of: id).contains(parentID) else { return false }
        }
        guard folders[i].parentID != parentID else { return false }
        folders[i].parentID = parentID
        return true
    }
}

// MARK: - Tags

extension GalleryItem {
    public func has(tag: String) -> Bool {
        tagList.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
    }
}

extension GalleryIndex {
    /// All tags with how many pictures have them, by name. Tags that differ
    /// only in case are one, written as first used.
    public var allTags: [(tag: String, count: Int)] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for item in items {
            for tag in item.tagList {
                counts[tag.lowercased(), default: (tag, 0)].count += 1
            }
        }
        return counts.values.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// `tag` cleaned up: no spaces at the ends or leading "#"; written as an
    /// existing tag if one only differs in case. `nil` when empty.
    public func normalized(tag: String) -> String? {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return allTags.first { $0.tag.localizedCaseInsensitiveCompare(t) == .orderedSame }?.tag ?? t
    }

    public mutating func addTag(_ tag: String, to ids: Set<UUID>) {
        guard let t = normalized(tag: tag) else { return }
        for i in items.indices where ids.contains(items[i].id) && !items[i].has(tag: t) {
            items[i].tags = items[i].tagList + [t]
        }
    }

    public mutating func removeTag(_ tag: String, from ids: Set<UUID>? = nil) {
        for i in items.indices where ids?.contains(items[i].id) ?? true {
            let kept = items[i].tagList.filter { $0.localizedCaseInsensitiveCompare(tag) != .orderedSame }
            items[i].tags = kept.isEmpty ? nil : kept
        }
    }

    /// Rename a tag on every picture (or merge it into one with that name).
    public mutating func renameTag(_ tag: String, to name: String) {
        guard let new = normalized(tag: name), new.localizedCaseInsensitiveCompare(tag) != .orderedSame || new != tag
        else { return }
        let ids = Set(items.filter { $0.has(tag: tag) }.map(\.id))
        removeTag(tag, from: ids)
        for i in items.indices where ids.contains(items[i].id) && !items[i].has(tag: new) {
            items[i].tags = items[i].tagList + [new]
        }
    }
}

// MARK: - Search

extension GalleryItem {
    /// Whether every word of `query` is found: in the prompt (as typed and
    /// as sent), the negative, the preset, the model, the LoRAs, the seed
    /// or the tags. "#word" looks in the tags only; "quoted words" are found
    /// as they are. Case and accents don't matter.
    public func matches(_ query: String) -> Bool {
        let words = GallerySearch.words(query)
        guard !words.isEmpty else { return true }
        let r = recipe
        let text = [
            r.prompt, r.negative, r.sent.positive, r.preset.name, r.preset.checkpoint, String(r.seed),
            r.sent.loras.map(\.name).joined(separator: " "), tagList.joined(separator: " "),
        ]
        .joined(separator: "\n")
        return words.allSatisfy { word in
            if word.hasPrefix("#") {
                let tag = String(word.dropFirst())
                return tag.isEmpty || tagList.contains { GallerySearch.contains($0, tag) }
            }
            return GallerySearch.contains(text, word)
        }
    }
}

enum GallerySearch {
    /// Words, keeping "quoted parts" together.
    static func words(_ query: String) -> [String] {
        var out: [String] = []
        for (i, part) in query.components(separatedBy: "\"").enumerated() {
            if i % 2 == 1 {
                let phrase = part.trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { out.append(phrase) }
            } else {
                out += part.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        return out
    }

    static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

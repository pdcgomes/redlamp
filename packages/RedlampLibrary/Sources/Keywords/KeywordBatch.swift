import Foundation
import RedlampEngineAPI

/// How a batch changes each photo's keywords: first the keywords within each replacement's `from`
/// go to the same place within its `to`, or off the photo when it has none; then `removing` come off
/// and `adding` go on.
struct KeywordEdit: Sendable, Hashable, Codable {
    struct Replacement: Sendable, Hashable, Codable {
        var from: KeywordPath
        var to: KeywordPath?
    }

    var replacing: [Replacement] = []
    var adding: [KeywordPath] = []
    var removing: [KeywordPath] = []

    var isEmpty: Bool {
        replacing.isEmpty && adding.isEmpty && removing.isEmpty
    }

    /// `keywords` changed, each once, in their order with the added ones after.
    func applied(to keywords: [KeywordPath]) -> [KeywordPath] {
        var result: [KeywordPath] = []
        var seen = Set<KeywordPath>()
        func keep(_ path: KeywordPath) {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        let removed = Set(removing)
        for keyword in keywords {
            var moved: KeywordPath? = keyword
            if let replacement = replacing.first(where: { keyword.isWithin($0.from) }) {
                moved = replacement.to.map { keyword.replacingPrefix(replacement.from, with: $0) }
            }
            if let moved, !removed.contains(moved) {
                keep(moved)
            }
        }
        adding.forEach(keep)
        return result
    }

    /// Whether the edit can change a photo with `keywords`.
    func touches(_ keywords: [KeywordPath]) -> Bool {
        applied(to: keywords) != keywords
    }
}

/// `current` with what a change made of `before` to give `after` taken back: what it added off, and
/// what it took off on, where they aren't already. Exactly `before` when `current` holds what `after` does.
func undone(_ current: [KeywordPath], before: [KeywordPath], after: [KeywordPath]) -> [KeywordPath] {
    guard Set(current) != Set(after) else { return before }
    let added = Set(after).subtracting(before)
    var result = current.filter { !added.contains($0) }
    for keyword in before where !after.contains(keyword) && !result.contains(keyword) {
        result.append(keyword)
    }
    return result
}

/// What a batch changes in the definitions: each keyword's options before and after (nil where the
/// definitions don't keep it), and the sets and the active set where they change.
struct DefinitionsChange: Sendable, Hashable {
    var keywords: [KeywordPath: (before: KeywordOptions?, after: KeywordOptions?)] = [:]
    var sets: (before: [KeywordSet]?, after: [KeywordSet]?)?
    var activeSet: (before: String?, after: String?)?

    /// What makes `old` into `new`.
    init(from old: KeywordDefinitions, to new: KeywordDefinitions) {
        for path in Set(old.keywords.keys).union(new.keywords.keys) where old.keywords[path] != new.keywords[path] {
            keywords[path] = (old.keywords[path], new.keywords[path])
        }
        if old.sets != new.sets {
            sets = (old.sets, new.sets)
        }
        if old.activeSet != new.activeSet {
            activeSet = (old.activeSet, new.activeSet)
        }
    }

    var isEmpty: Bool {
        keywords.isEmpty && sets == nil && activeSet == nil
    }

    /// `definitions` as the change leaves them, or, `reversed`, as they were before it.
    func applied(to definitions: KeywordDefinitions, reversed: Bool = false) -> KeywordDefinitions {
        var changed = definitions
        for (path, options) in keywords {
            changed.keywords[path] = reversed ? options.before : options.after
        }
        if let sets {
            changed.sets = reversed ? sets.before : sets.after
        }
        if let activeSet {
            changed.activeSet = reversed ? activeSet.before : activeSet.after
        }
        return changed
    }

    static func == (lhs: DefinitionsChange, rhs: DefinitionsChange) -> Bool {
        lhs.json == rhs.json
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(json)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        object["keywords"] = .object(Dictionary(uniqueKeysWithValues: keywords.map { path, options in
            (path.text, .object([
                "before": options.before.map(\.json) ?? .null, "after": options.after.map(\.json) ?? .null,
            ]))
        }))
        if let sets {
            object["sets"] = .object([
                "before": sets.before.map { .array($0.map(\.json)) } ?? .null,
                "after": sets.after.map { .array($0.map(\.json)) } ?? .null,
            ])
        }
        if let activeSet {
            object["activeSet"] = .object([
                "before": activeSet.before.map(JSONValue.string) ?? .null,
                "after": activeSet.after.map(JSONValue.string) ?? .null,
            ])
        }
        return .object(object)
    }

    init(json: JSONValue) {
        guard case let .object(object) = json else { return }
        func options(_ value: JSONValue?) -> KeywordOptions? {
            guard let value, value != .null else { return nil }
            return KeywordOptions(json: value)
        }
        func sets(_ value: JSONValue?) -> [KeywordSet]? {
            guard case let .array(values)? = value else { return nil }
            return values.compactMap(KeywordSet.init(json:))
        }
        if case let .object(entries)? = object["keywords"] {
            for (text, value) in entries {
                guard let path = KeywordPath(text), case let .object(pair) = value else { continue }
                keywords[path] = (options(pair["before"]), options(pair["after"]))
            }
        }
        if case let .object(pair)? = object["sets"] {
            self.sets = (sets(pair["before"]), sets(pair["after"]))
        }
        if case let .object(pair)? = object["activeSet"] {
            activeSet = (pair["before"]?.textValue, pair["after"]?.textValue)
        }
    }
}

/// A photo's keywords as its sidecar holds them: nil when it has no `keywords`, which leaves them to
/// what's embedded in the photo and other apps' `.xmp`.
struct SidecarKeywords: Sendable, Hashable, Codable {
    var keywords: [String]?

    var paths: [KeywordPath]? {
        keywords.map(KeywordPath.paths)
    }
}

/// One change to the keywords, made as a batch with Undo: its photos, what it does to each, and
/// what it changes in the definitions.
struct KeywordBatch: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, Codable {
        case add, remove, rename, merge, delete, define, undo
    }

    /// A photo of the batch: where it is, and its keywords in the index before.
    struct Photo: Sendable, Hashable, Codable {
        var id: Int64
        var path: String
        var index: [KeywordPath]
        /// For an undo: the photo's keywords before and after the batch it undoes.
        var undo: Undo?
    }

    struct Undo: Sendable, Hashable, Codable {
        var sidecarBefore: SidecarKeywords
        var sidecarAfter: SidecarKeywords
        var indexBefore: [KeywordPath]
        var indexAfter: [KeywordPath]
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var created = Date()
    var undoes: UUID?
    var edit = KeywordEdit()
    var definitions: DefinitionsChange?
    var photos: [Photo] = []

    /// The photo's keywords in the index once the batch is done, from those it has now.
    func indexAfter(_ photo: Photo, current: [KeywordPath]) -> [KeywordPath] {
        if let undo = photo.undo {
            return undone(current, before: undo.indexBefore, after: undo.indexAfter)
        }
        return edit.applied(to: current)
    }

    /// What the photo's sidecar holds once the batch is done, from what it holds now; `fallback` is
    /// what the index has for it, when the sidecar holds none.
    func sidecarAfter(_ photo: Photo, current: SidecarKeywords, fallback: [KeywordPath]) -> SidecarKeywords {
        if let undo = photo.undo {
            if current == undo.sidecarAfter {
                return undo.sidecarBefore
            }
            let base = current.paths ?? fallback
            let before = undo.sidecarBefore.paths ?? undo.indexBefore
            let after = undo.sidecarAfter.paths ?? undo.indexAfter
            return SidecarKeywords(keywords: undone(base, before: before, after: after).map(\.text))
        }
        return SidecarKeywords(keywords: edit.applied(to: current.paths ?? fallback).map(\.text))
    }
}

/// A change worked out but not made: what it would do, for a preview or `--dry-run`.
public struct KeywordPlan: Sendable, Hashable {
    /// What a photo's keywords would be.
    public struct Photo: Sendable, Hashable {
        public let id: Int64
        public let path: String
        public let before: [KeywordPath]
        public let after: [KeywordPath]
    }

    let batch: KeywordBatch

    public var id: UUID {
        batch.id
    }

    /// `Add “Places/Portugal/Lisbon” to 1,200 photos`.
    public var title: String {
        batch.title
    }

    /// The photos whose keywords change, in ID order.
    public var photos: [Photo] {
        batch.photos.map { photo in
            Photo(
                id: photo.id,
                path: photo.path,
                before: photo.index,
                after: batch.indexAfter(photo, current: photo.index),
            )
        }
    }

    /// The keywords whose options the definitions change, add or drop.
    public var definedKeywords: [KeywordPath] {
        (batch.definitions?.keywords.keys).map { $0.sorted() } ?? []
    }

    /// Whether running it would change nothing.
    public var isEmpty: Bool {
        batch.photos.isEmpty && (batch.definitions?.isEmpty ?? true)
    }
}

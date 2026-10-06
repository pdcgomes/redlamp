import Foundation
import RedlampDocument
import RedlampEngineAPI

/// A change to the library's collections (LIB-23), made as one batch with Undo in the metadata journal.
public enum CollectionChange: Sendable, Hashable {
    /// Makes a set or a collection, and the sets above it the list lacks.
    case create(CollectionPath, CollectionKind = .collection)
    /// Makes a smart collection, or gives one another query, in the library's query language.
    case smart(CollectionPath, query: String)
    /// Renames or moves a set or collection with everything inside it: its photos' sidecars follow.
    case rename(CollectionPath, to: CollectionPath)
    /// Takes the sets and collections, and everything inside them, out of the list and off every photo.
    case delete([CollectionPath])
    /// Puts the photos in the collection, made where there's none.
    case add([Int64], to: CollectionPath)
    /// Takes the photos out of the collection, which stays in the list.
    case remove([Int64], from: CollectionPath)
    /// The collection the add-to-target key puts photos in; nil for the quick collection.
    case target(CollectionPath?)
}

/// The library's collection list (LIB-23): every collection its photos are in, from the index, and
/// every set, collection and smart collection the definitions keep, with the sets above them.
public struct CollectionList: Sendable {
    public struct Collection: Sendable, Hashable, Identifiable {
        public let path: CollectionPath
        public let kind: CollectionKind
        /// Photos in it; for a set or smart collection, none.
        public let photos: Int
        public let query: String?
        /// The definitions keep it, so it stays without photos.
        public let isDefined: Bool

        public var id: CollectionPath {
            path
        }
    }

    public let collections: [CollectionPath: Collection]
    public let target: CollectionPath?

    /// `counts` (`IndexQueries.collectionCounts`) and `kinds` from the index, and `definitions`.
    init(counts: [CollectionPath: Int], kinds: [CollectionPath: CollectionKind], definitions: CollectionDefinitions) {
        var present = Set(counts.keys).union(kinds.keys).union(definitions.collections.keys)
        for path in Array(present) {
            present.formUnion(path.ancestors)
        }
        var collections: [CollectionPath: Collection] = [:]
        for path in present {
            let defined = definitions.collections[path]
            let kind = defined?.kind ?? (counts[path] ?? 0 > 0 ? .collection : kinds[path] ?? .set)
            collections[path] = Collection(
                path: path, kind: kind, photos: counts[path] ?? 0, query: defined?.query, isDefined: defined != nil,
            )
        }
        self.collections = collections
        target = definitions.target
    }

    public subscript(path: CollectionPath) -> Collection? {
        collections[path]
    }

    /// Every place, each before what's inside it, each level in the Finder's order of names.
    public var ordered: [Collection] {
        collections.values.sorted { lhs, rhs in
            for (left, right) in zip(lhs.path.names, rhs.path.names) where left != right {
                let order = FinderOrder.compare(left, right)
                return order != 0 ? order < 0 : left < right
            }
            return lhs.path.names.count < rhs.path.names.count
        }
    }

    /// The place `text` names: one at its path; else, for a single name, the collection so named,
    /// ignoring case, the one with most photos if several are.
    public func resolve(_ text: String) -> CollectionPath? {
        guard let path = CollectionPath(text) else { return nil }
        if collections[path] != nil {
            return path
        }
        guard path.names.count == 1 else { return nil }
        return collections.values.filter { $0.path.name.caseInsensitiveCompare(path.name) == .orderedSame }
            .max { ($0.photos, $1.path) < ($1.photos, $0.path) }?.path
    }
}

/// The library's collections (LIB-23): the list from the index and the definitions
/// (`CollectionDefinitions`), and every change to them made as a batch with Undo by `LibraryMetadata`,
/// whose journal they share. A photo's sidecar names the collections it's in, so renaming or moving a
/// collection, or deleting it, rewrites its photos' sidecars, as a keyword's does.
public struct LibraryCollections: Sendable {
    public let metadata: LibraryMetadata

    public var index: LibraryIndex {
        metadata.index
    }

    /// `Collections.json` in the library's definitions.
    public var definitionsURL: URL {
        CollectionDefinitions.url(in: metadata.paths)
    }

    public func definitions() async throws -> CollectionDefinitions {
        let url = definitionsURL
        return try await LibraryIndex.offCaller { try CollectionDefinitions.load(from: url) }
    }

    /// The collection list as the index and the definitions have it now.
    public func list() async throws -> CollectionList {
        let definitions = try await definitions()
        let (counts, kinds) = try await index.read { reader in
            try (
                reader.collectionCounts(),
                reader.collections().values.reduce(into: [CollectionPath: CollectionKind]()) {
                    $0[$1.path] = $1.kind
                },
            )
        }
        return CollectionList(counts: counts, kinds: kinds, definitions: definitions)
    }

    /// The IDs of the photos in collections at or within `path`.
    public func photoIDs(in path: CollectionPath) async throws -> [Int64] {
        try await index.read { try $0.photoIDs(inCollectionsWithin: [path]) }
    }

    /// Makes `change` as one batch; see `plan` and `LibraryMetadata.run`.
    @discardableResult
    public func apply(_ change: CollectionChange) async throws -> MetadataOutcome {
        try await metadata.run(plan(change))
    }

    /// What `change` would do, worked out from the index and the definitions as they are; nothing is
    /// written.
    public func plan(_ change: CollectionChange) async throws -> MetadataPlan {
        let old = try await definitions()
        let list = try await list()
        var new = old
        var batch: MetadataBatch
        func requireNew(_ path: CollectionPath) throws {
            if list[path] != nil {
                throw MetadataError.collection(.taken(path))
            }
            if let blocked = path.ancestors.first(where: { (list[$0]?.kind ?? .set) != .set }) {
                throw MetadataError.collection(.notASet(blocked))
            }
        }
        func defineSets(above path: CollectionPath) {
            for ancestor in path.ancestors where new.collections[ancestor] == nil {
                new.collections[ancestor] = .set
            }
        }
        switch change {
        case let .create(path, kind):
            try requireNew(path)
            batch = MetadataBatch(
                kind: .collections,
                title: "New \(kind.name == "set" ? "set" : "collection") “\(path.displayName)”",
            )
            defineSets(above: path)
            new.collections[path] = CollectionOptions(kind: kind)
        case let .smart(path, query):
            if let existing = list[path], existing.kind != .smart {
                throw MetadataError.collection(.taken(path))
            } else if list[path] == nil {
                try requireNew(path)
            }
            batch = MetadataBatch(kind: .collections, title: "Smart collection “\(path.displayName)”")
            defineSets(above: path)
            new.collections[path] = .smart(query)
        case let .rename(from, to):
            guard from != to else { return MetadataPlan(batch: MetadataBatch(kind: .collections, title: "Rename")) }
            guard list[from] != nil else { throw MetadataError.collection(.noSuchCollection(from)) }
            guard !to.isWithin(from) else { throw MetadataError.collection(.insideItself(from)) }
            try requireNew(to)
            let verb = from.parent == to.parent ? "Rename" : "Move"
            batch = MetadataBatch(kind: .collections, title: "\(verb) “\(from.displayName)” to “\(to.displayName)”")
            batch.edit = ["collections": .move(from: from.text, to: to.text)]
            let ids = try await index.read { try $0.photoIDs(inCollectionsWithin: [from]) }
            batch.photos = try await metadata.photos(ids, edit: batch.edit)
            for path in list.collections.keys where path.isWithin(from) {
                let moved = path.replacingPrefix(from, with: to)
                new.collections[moved] = old.collections[path]
                    ?? CollectionOptions(kind: list[path]?.kind ?? .collection)
                new.collections[path] = nil
            }
            defineSets(above: to)
            if let target = old.target, target.isWithin(from) {
                new.target = target.replacingPrefix(from, with: to)
            }
        case let .delete(paths):
            for path in paths where list[path] == nil {
                throw MetadataError.collection(.noSuchCollection(path))
            }
            let what = paths.count == 1 ? "“\(paths[0].displayName)”" : "\(paths.count) collections"
            batch = MetadataBatch(kind: .collections, title: "Delete \(what)")
            batch.edit = ["collections": .drop(paths.map(\.text))]
            let ids = try await index.read { try $0.photoIDs(inCollectionsWithin: paths) }
            batch.photos = try await metadata.photos(ids, edit: batch.edit)
            for path in old.collections.keys where paths.contains(where: { path.isWithin($0) }) {
                new.collections[path] = nil
            }
            if let target = old.target, paths.contains(where: { target.isWithin($0) }) {
                new.target = nil
            }
        case let .add(ids, path):
            if let existing = list[path], existing.kind != .collection {
                throw MetadataError.collection(.notACollection(path))
            }
            if list[path] == nil {
                try requireNew(path)
                defineSets(above: path)
                new.collections[path] = CollectionOptions()
            }
            batch = MetadataBatch(
                kind: .collections, title: "Add \(LibraryMetadata.count(ids.count)) to “\(path.displayName)”",
            )
            batch.edit = ["collections": .add([path.text])]
            batch.photos = try await metadata.photos(ids, edit: batch.edit)
        case let .remove(ids, path):
            batch = MetadataBatch(
                kind: .collections, title: "Remove \(LibraryMetadata.count(ids.count)) from “\(path.displayName)”",
            )
            batch.edit = ["collections": .remove([path.text])]
            batch.photos = try await metadata.photos(ids, edit: batch.edit)
            if old.collections[path] == nil, list[path] != nil {
                new.collections[path] = CollectionOptions()
            }
        case let .target(path):
            if let path, let existing = list[path], existing.kind != .collection {
                throw MetadataError.collection(.notACollection(path))
            }
            batch = MetadataBatch(
                kind: .collections,
                title: path.map { "Make “\($0.displayName)” the target" } ?? "Target the quick collection",
            )
            new.target = path
        }
        let definitions = CollectionsChange(from: old, to: new)
        batch.definitions = definitions.isEmpty ? nil : definitions
        return MetadataPlan(batch: batch)
    }

    /// Loads the definitions, changes them with `change` and saves them, off the caller.
    func updateDefinitions(
        _ change: @escaping @Sendable (CollectionDefinitions) -> CollectionDefinitions,
    ) async throws {
        let url = definitionsURL
        try await LibraryIndex.offCaller {
            let current = try CollectionDefinitions.load(from: url)
            let changed = change(current)
            if changed != current {
                try changed.save(to: url)
            }
        }
    }
}

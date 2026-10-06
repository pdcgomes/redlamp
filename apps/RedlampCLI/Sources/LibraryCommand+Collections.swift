import Foundation
import RedlampLibrary

/// `redlamp library collections`: the collection list (LIB-23), collections and sets made, renamed,
/// moved and deleted, smart collections' queries, the target collection, and the photos a query finds
/// put in a collection and taken out, each change a batch in the metadata journal, with Undo
/// (`redlamp library metadata undo`). Every change first finishes one a forced quit left.
extension LibraryCommand {
    static let collectionsUsage = """
    usage: redlamp library collections --index <path> [--tree] [--json]
           redlamp library collections new <path> [--set] --index <path> [--dry-run]
           redlamp library collections smart <path> <query> --index <path> [--dry-run]
           redlamp library collections add|remove <collection> --index <path> <query> [--dry-run] [--json]
           redlamp library collections rename <collection> <path> --index <path> [--dry-run] [--json]
           redlamp library collections delete <collection>… --index <path> [--dry-run] [--json]
           redlamp library collections target <collection>|none --index <path>
    """

    static func collections(_ arguments: [String]) async throws {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "new": try await newCollection(rest)
        case "smart": try await smartCollection(rest)
        case "add": try await changeMembers(rest, adding: true)
        case "remove": try await changeMembers(rest, adding: false)
        case "rename": try await renameCollection(rest)
        case "delete": try await deleteCollections(rest)
        case "target": try await targetCollection(rest)
        default: try await listCollections(arguments)
        }
    }

    /// Every set, collection and smart collection, with how many photos each collection holds; with
    /// `--tree`, indented under the sets holding them.
    private static func listCollections(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "collections needs --index\n\n\(collectionsUsage)")
        }
        let list = try await withMetadata(path, recovering: false) { try await $0.collections.list() }
        if options.has("--json") {
            let objects = list.ordered.map { collection -> [String: Any] in
                var object: [String: Any] = [
                    "path": collection.path.text, "names": collection.path.names, "kind": collection.kind.name,
                    "photos": collection.photos, "defined": collection.isDefined,
                    "target": collection.path == list.target,
                ]
                object["query"] = collection.query
                return object
            }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for collection in list.ordered {
            var notes: [String] = []
            switch collection.kind {
            case .set: notes.append("set")
            case .collection: notes
                .append("\(metadataCount(collection.photos)) photo\(collection.photos == 1 ? "" : "s")")
            case .smart: notes.append("smart: \(collection.query ?? "")")
            }
            if collection.path == list.target {
                notes.append("the target")
            }
            if options.has("--tree") {
                print(String(repeating: "  ", count: collection.path.depth) + collection.path.name
                    + " (" + notes.joined(separator: ", ") + ")")
            } else {
                print(collection.path.text + "\t" + notes.joined(separator: ", "))
            }
        }
        print("\(metadataCount(list.collections.count)) collections and sets")
    }

    private static func newCollection(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.count == 1, let path = options.value("--index") else {
            throw CLIError(description: "collections new needs a path and --index\n\n\(collectionsUsage)")
        }
        let collection = try collectionPath(options.positional[0])
        try await withMetadata(path) { metadata in
            let kind: CollectionKind = options.has("--set") ? .set : .collection
            try await planned(
                metadata.collections.plan(.create(collection, kind)),
                metadata: metadata,
                options: options,
            )
        }
    }

    private static func smartCollection(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.count >= 2, let path = options.value("--index") else {
            throw CLIError(description: "collections smart needs a path, a query and --index\n\n\(collectionsUsage)")
        }
        let collection = try collectionPath(options.positional[0])
        let text = options.positional.dropFirst().joined(separator: " ")
        _ = try metadataQuery(text)
        try await withMetadata(path) { metadata in
            try await planned(
                metadata.collections.plan(.smart(collection, query: text)), metadata: metadata, options: options,
            )
        }
    }

    private static func changeMembers(_ arguments: [String], adding: Bool) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        let verb = adding ? "add" : "remove"
        guard let text = options.positional.first, let path = options.value("--index") else {
            throw CLIError(description: "collections \(verb) needs a collection and --index\n\n\(collectionsUsage)")
        }
        let query = try metadataQuery(options.positional.dropFirst().joined(separator: " "))
        try await withMetadata(path) { metadata in
            let collection = try await resolvedCollection(text, in: metadata.collections.list(), existing: !adding)
            let ids = try await queriedPhotoIDs(query, in: metadata.index)
            let change: CollectionChange = adding ? .add(ids, to: collection) : .remove(ids, from: collection)
            try await planned(metadata.collections.plan(change), metadata: metadata, options: options)
        }
    }

    /// Renames a collection or set, given a name, or moves it, given a path.
    private static func renameCollection(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.count == 2, let path = options.value("--index") else {
            throw CLIError(description: "collections rename needs a collection, its new path and --index\n\n"
                + collectionsUsage)
        }
        try await withMetadata(path) { metadata in
            let collection = try await resolvedCollection(
                options.positional[0], in: metadata.collections.list(), existing: true,
            )
            let target = try collectionPath(options.positional[1])
            let destination = target.names.count == 1 ? collection.parent?.appending(target.name) ?? target : target
            try await planned(
                metadata.collections.plan(.rename(collection, to: destination)), metadata: metadata, options: options,
            )
        }
    }

    private static func deleteCollections(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard !options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "collections delete needs collections and --index\n\n\(collectionsUsage)")
        }
        try await withMetadata(path) { metadata in
            let list = try await metadata.collections.list()
            let doomed = try options.positional.map { try resolvedCollection($0, in: list, existing: true) }
            try await planned(metadata.collections.plan(.delete(doomed)), metadata: metadata, options: options)
        }
    }

    private static func targetCollection(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.count == 1, let path = options.value("--index") else {
            throw CLIError(description: "collections target needs a collection or none, and --index\n\n"
                + collectionsUsage)
        }
        try await withMetadata(path) { metadata in
            let target = options.positional[0] == "none" ? nil
                : try await resolvedCollection(options.positional[0], in: metadata.collections.list(), existing: true)
            try await planned(metadata.collections.plan(.target(target)), metadata: metadata, options: options)
        }
    }

    // MARK: - Helpers

    private static func collectionPath(_ text: String) throws -> CollectionPath {
        guard let path = CollectionPath(text) else { throw CLIError(description: "“\(text)” has no collection in it") }
        return path
    }

    /// The collection `text` names: a path, or one the list has by its name; a new one at that path
    /// unless it must be in the list.
    private static func resolvedCollection(
        _ text: String, in list: CollectionList, existing: Bool,
    ) throws -> CollectionPath {
        if let found = list.resolve(text) {
            return found
        }
        let path = try collectionPath(text)
        guard !existing else { throw CLIError(description: "there's no collection \(path.text) in the list") }
        return path
    }
}

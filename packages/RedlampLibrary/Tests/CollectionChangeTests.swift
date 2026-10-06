import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Collections and sets (LIB-23): made, renamed, moved and deleted, and photos put in and taken out, each
/// a batch with Undo; a photo's sidecar names its collections, and `Collections.json` keeps the rest.
struct CollectionChangeTests {
    func path(_ text: String) -> CollectionPath {
        CollectionPath(text)!
    }

    /// The collections each photo's sidecar names, by its path in the sandbox.
    func sidecars(_ sandbox: KeywordSandbox, _ paths: [String]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: paths.map { ($0, sandbox.sidecar($0)?.metadata?.collections ?? []) })
    }

    /// The collections each photo is in, by the index.
    func indexed(_ sandbox: KeywordSandbox, _ paths: [String]) async throws -> [String: [String]] {
        var found: [String: [String]] = [:]
        for path in paths {
            let id = try await sandbox.id(path)
            found[path] = try await sandbox.index.read { try $0.collections(ofPhoto: id).map(\.text) }
        }
        return found
    }

    @Test func `photos put in a collection carry it, and a rename and a move reach every one of them`() async throws {
        let (sandbox, paths, ids) = try await MetadataChangeTests.library()
        defer { sandbox.remove() }
        let collections = LibraryMetadata(index: sandbox.index, paths: sandbox.paths).collections
        try await collections.apply(.create(path("Clients"), .set))
        let added = try await collections.apply(.add(Array(ids.prefix(30)), to: path("Clients/Acme/Selects")))
        #expect(added.title == "Add 30 photos to “Clients › Acme › Selects”" && added.written == 30)
        try await collections.apply(.add(Array(ids.suffix(15)), to: path("Best%2FWorst")))
        let both = Set(paths.prefix(30)).intersection(paths.suffix(15))
        for (photo, held) in sidecars(sandbox, paths) {
            var expected = paths.prefix(30).contains(photo) ? ["Clients/Acme/Selects"] : []
            if paths.suffix(15).contains(photo) {
                expected.append("Best%2FWorst")
            }
            #expect(held == expected, "\(photo)")
        }
        #expect(try await indexed(sandbox, paths) == sidecars(sandbox, paths).mapValues { $0.sorted() })
        var list = try await collections.list()
        #expect(list[path("Clients/Acme/Selects")]?.photos == 30 && list[path("Best%2FWorst")]?.photos == 15)
        #expect(list[path("Clients")]?.kind == .set && list[path("Clients/Acme")]?.kind == .set)
        let definitions = try await collections.definitions()
        #expect(definitions.collections[path("Clients/Acme")]?.kind == .set)
        #expect(definitions.collections[path("Clients/Acme/Selects")]?.kind == .collection)

        // Renamed, then moved: every photo's sidecar follows, and each Undo brings it back.
        let renamed = try await collections.apply(.rename(path("Clients/Acme"), to: path("Clients/Acme Corp")))
        #expect(renamed.title == "Rename “Clients › Acme” to “Clients › Acme Corp”" && renamed.written == 30)
        let moved = try await collections.apply(.rename(path("Clients/Acme Corp"), to: path("Archive/2026/Acme")))
        #expect(moved.title.hasPrefix("Move ") && moved.written == 30)
        for photo in paths.prefix(30) {
            #expect(sandbox.sidecar(photo)?.metadata?.collections.first == "Archive/2026/Acme/Selects", "\(photo)")
        }
        #expect(try await indexed(sandbox, paths) == sidecars(sandbox, paths).mapValues { $0.sorted() })
        list = try await collections.list()
        #expect(list[path("Archive/2026/Acme/Selects")]?.photos == 30 && list[path("Clients/Acme")] == nil)
        #expect(list[path("Clients")]?.kind == .set)
        let index = try await sandbox.index.read { try $0.collections().values.map(\.path.text).sorted() }
        #expect(index == ["Archive", "Archive/2026", "Archive/2026/Acme", "Archive/2026/Acme/Selects", "Best%2FWorst"])

        try await collections.metadata.undo()
        try await collections.metadata.undo()
        for photo in paths.prefix(30) {
            #expect(sandbox.sidecar(photo)?.metadata?.collections.first == "Clients/Acme/Selects", "\(photo)")
        }
        #expect(try await collections.list()[path("Clients/Acme/Selects")]?.photos == 30)
        #expect(try await collections.definitions().collections[path("Archive/2026/Acme")] == nil)
        #expect(both.count == 5)
    }

    @Test func `deleting a set takes its collections off every photo, and Undo puts them back`() async throws {
        let (sandbox, paths, ids) = try await MetadataChangeTests.library()
        defer { sandbox.remove() }
        let collections = LibraryMetadata(index: sandbox.index, paths: sandbox.paths).collections
        try await collections.apply(.add(Array(ids.prefix(10)), to: path("Trips/Lisbon")))
        try await collections.apply(.add(Array(ids.prefix(5)), to: path("Trips/Porto")))
        try await collections.apply(.add(Array(ids.prefix(3)), to: path("Portfolio")))
        try await collections.apply(.smart(path("Trips/Five stars"), query: "rating=5"))
        try await collections.apply(.target(path("Trips/Lisbon")))
        let before = sidecars(sandbox, paths)

        let deleted = try await collections.apply(.delete([path("Trips")]))
        #expect(deleted.title == "Delete “Trips”" && deleted.written == 10)
        #expect(sidecars(sandbox, Array(paths.prefix(3))).values.allSatisfy { $0 == ["Portfolio"] })
        #expect(sandbox.sidecar(paths[4])?.metadata?.collections == [])
        let definitions = try await collections.definitions()
        #expect(definitions.collections.keys.map(\.text).sorted() == ["Portfolio"] && definitions.target == nil)
        #expect(try await indexed(sandbox, paths) == sidecars(sandbox, paths).mapValues { $0.sorted() })

        try await collections.metadata.undo()
        #expect(sidecars(sandbox, paths) == before)
        let restored = try await collections.definitions()
        #expect(restored.collections[path("Trips/Five stars")] == .smart("rating=5"))
        #expect(restored.target == path("Trips/Lisbon"))

        // Photos taken out of a collection leave it in the list, empty.
        try await collections.apply(.remove(Array(ids.prefix(10)), from: path("Trips/Lisbon")))
        let list = try await collections.list()
        #expect(list[path("Trips/Lisbon")]?.photos == 0 && list[path("Trips/Lisbon")]?.isDefined == true)
        #expect(sandbox.sidecar(paths[7]) == nil && sandbox.sidecar(paths[6])?.metadata?.collections == [])
        await #expect(throws: MetadataError.collection(.notACollection(path("Trips")))) {
            try await collections.plan(.add([ids[0]], to: path("Trips")))
        }
        await #expect(throws: MetadataError.collection(.taken(path("Portfolio")))) {
            try await collections.plan(.rename(path("Trips/Porto"), to: path("Portfolio")))
        }
    }

    @Test func `the definitions keep what a newer Redlamp wrote`() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: CollectionDefinitions.fileName)
        let text = """
        {"format": "app.redlamp.collections", "version": 1, "sort": "custom",
         "collections": {"Clients": {"kind": "set", "colour": "blue"}, "Clients/Acme": {}, "Albums/One": {"kind": "album"},
          "Five stars": {"kind": "smart", "query": "rating=5"}},
         "target": "Clients/Acme"}
        """
        try Data(text.utf8).write(to: url)
        var definitions = try CollectionDefinitions.load(from: url)
        #expect(definitions.collections[path("Clients")]?.kind == .set)
        #expect(definitions.collections[path("Five stars")] == .smart("rating=5"))
        #expect(definitions.collections[path("Albums/One")]?.kind == .collection)
        #expect(definitions.target == path("Clients/Acme"))
        definitions.collections[path("Clients/Other")] = CollectionOptions()
        try definitions.save(to: url)
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        #expect(saved.objectValue?["sort"] == .string("custom"))
        let entries = saved.objectValue?["collections"]?.objectValue
        #expect(entries?["Clients"] == .object(["kind": .string("set"), "colour": .string("blue")]))
        #expect(entries?["Albums/One"] == .object(["kind": .string("album")]))
        #expect(entries?["Clients/Other"] == .object([:]))
    }
}

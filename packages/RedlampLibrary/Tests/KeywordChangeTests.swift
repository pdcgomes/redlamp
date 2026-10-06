import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Each keyword change as one batch with Undo: added and removed on photos, renamed, moved, merged and
/// deleted, with the sidecars, the index, the definitions and the open lists following; and a batch a
/// forced quit stopped, finished or rolled back.
struct KeywordChangeTests {
    private func sandbox() async throws -> KeywordSandbox {
        let sandbox = try await KeywordSandbox.make()
        try sandbox.photo("A.JPG", keywords: ["Places/Portugal/Lisbon"])
        try sandbox.photo("B.JPG", keywords: ["Places/Portugal/Porto", "tram"])
        try sandbox.photo("C.JPG")
        try sandbox.write("C.xmp", OtherApps.lightroom(rating: 0, keywords: ["Theirs/Gulls"]))
        try await sandbox.indexAll()
        return sandbox
    }

    @Test func `keywords added to a selection are written to each sidecar, and Undo takes them back`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        let ids = try await sandbox.ids(["A.JPG", "B.JPG", "C.JPG"])
        let outcome = try await keywords.apply(.add([kw("Birds/Gulls"), kw("tram")], to: ids))
        #expect(outcome.state == .finished && outcome.photos == 3 && outcome.written == 3)
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon", "Birds/Gulls", "tram"])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Places/Portugal/Porto", "tram", "Birds/Gulls"])
        // A photo whose keywords came from another app's .xmp keeps them in the sidecar it gets.
        #expect(sandbox.sidecarKeywords("C.JPG") == ["Theirs/Gulls", "Birds/Gulls", "tram"])
        #expect(try await sandbox.indexed("C.JPG") == ["Birds/Gulls", "Theirs/Gulls", "tram"])
        #expect(sandbox.sidecar("A.JPG")?.unknownFields["fromTheFuture"] == .string("kept"))
        #expect(sandbox.sidecar("A.JPG")?.recipe[.exposure] == 0.35)
        #expect(try await keywords.sets().first?.keywords.prefix(2) == [kw("Birds/Gulls"), kw("tram")])

        let undone = try await keywords.undo()
        #expect(undone.state == .finished && undone.written == 3)
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon"])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Places/Portugal/Porto", "tram"])
        #expect(sandbox.sidecar("C.JPG") == nil, "the sidecar the change made goes with it")
        #expect(try await sandbox.indexed("C.JPG") == ["Theirs/Gulls"])
        #expect(try await sandbox.indexed("A.JPG") == ["Places/Portugal/Lisbon"])
        #expect(try await keywords.list()[kw("Birds/Gulls")] == nil)
        #expect(try await keywords.lastUndoable() == nil)
    }

    @Test func `keywords removed from a selection come off their sidecars, and stay in the list`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        let ids = try await sandbox.ids(["A.JPG", "B.JPG"])
        let outcome = try await keywords.apply(.remove([kw("tram"), kw("Places/Portugal/Lisbon")], from: ids))
        #expect(outcome.photos == 2 && outcome.written == 2)
        #expect(sandbox.sidecarKeywords("A.JPG") == [], "an empty list, so nothing else gives the photo keywords")
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Places/Portugal/Porto"])
        let list = try await keywords.list()
        #expect(list[kw("tram")]?.count == 0 && list[kw("tram")]?.isDefined == true)
        #expect(list[kw("Places/Portugal/Lisbon")]?.count == 0)

        try await keywords.undo()
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon"])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Places/Portugal/Porto", "tram"])
        #expect(try await keywords.definitions().keywords.isEmpty)
        #expect(try await keywords.list()[kw("tram")]?.count == 1)
    }

    @Test func `a keyword renamed or moved takes its photos, the keywords inside it, its options and sets along`(
    ) async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        try await keywords.apply(.define(kw("Places/Portugal/Lisbon"), KeywordOptions(synonyms: ["Lisboa"])))
        try await keywords.apply(.sets(
            [KeywordSet(name: "Trip", keywords: [kw("Places/Portugal/Porto")])],
            active: nil,
        ))
        let renamed = try await keywords.apply(.rename(kw("Places/Portugal"), to: kw("Places/Portuguese Republic")))
        #expect(renamed.photos == 2 && renamed.title == "Rename “Places › Portugal” to “Places › Portuguese Republic”")
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portuguese Republic/Lisbon"])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Places/Portuguese Republic/Porto", "tram"])
        var list = try await keywords.list()
        #expect(list[kw("Places/Portugal")] == nil)
        #expect(list[kw("Places/Portuguese Republic/Lisbon")]?.options.synonyms == ["Lisboa"])
        #expect(try await keywords.sets().last?.keywords.first == kw("Places/Portuguese Republic/Porto"))
        #expect(try await sandbox.search("kw:Lisboa") == ["A.JPG"])

        let moved = try await keywords.apply(.rename(kw("Places/Portuguese Republic/Lisbon"), to: kw("Cities/Lisbon")))
        #expect(moved.title.hasPrefix("Move"))
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Cities/Lisbon"])
        list = try await keywords.list()
        #expect(list.roots == [kw("Cities"), kw("Places"), kw("Theirs"), kw("tram")])

        try await keywords.undo()
        try await keywords.undo()
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon"])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Places/Portugal/Porto", "tram"])
        list = try await keywords.list()
        #expect(list[kw("Places/Portugal/Lisbon")]?.options.synonyms == ["Lisboa"] && list[kw("Cities")] == nil)
        #expect(try await keywords.sets().last?.keywords.first == kw("Places/Portugal/Porto"))
        await #expect(throws: KeywordError.insideItself(kw("Places"))) {
            try await keywords.apply(.rename(kw("Places"), to: kw("Places/Old")))
        }
        await #expect(throws: KeywordError.noSuchKeyword(kw("Nowhere"))) {
            try await keywords.apply(.rename(kw("Nowhere"), to: kw("Somewhere")))
        }
    }

    @Test func `keywords merged in one step give their photos the one kept, with their synonyms and children`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("A.JPG", keywords: ["lisbon", "tram"])
        try sandbox.photo("B.JPG", keywords: ["Lisboa/Alfama"])
        try sandbox.photo("C.JPG", keywords: ["Places/Lisbon", "lisbon"])
        try await sandbox.indexAll()
        let keywords = sandbox.keywords()
        try await keywords.apply(.define(kw("lisbon"), KeywordOptions(synonyms: ["Olisipo"])))
        let merged = try await keywords.apply(.merge([kw("lisbon"), kw("Lisboa")], into: kw("Places/Lisbon")))
        #expect(merged.photos == 3)
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Lisbon", "tram"])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Places/Lisbon/Alfama"])
        #expect(sandbox.sidecarKeywords("C.JPG") == ["Places/Lisbon"])
        let list = try await keywords.list()
        #expect(list.roots == [kw("Places"), kw("tram")])
        #expect(list[kw("Places/Lisbon")]?.count == 3 && list[kw("Places/Lisbon")]?.options.synonyms == ["Olisipo"])

        try await keywords.undo()
        #expect(sandbox.sidecarKeywords("A.JPG") == ["lisbon", "tram"])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["Lisboa/Alfama"])
        #expect(sandbox.sidecarKeywords("C.JPG") == ["Places/Lisbon", "lisbon"])
        #expect(try await keywords.list()[kw("lisbon")]?.options.synonyms == ["Olisipo"])
    }

    @Test func `a deleted keyword leaves every photo and the list, with what's inside it, until Undo`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        try await keywords.apply(.define(kw("Places/Portugal/Faro"), KeywordOptions()))
        let deleted = try await keywords.apply(.delete([kw("Places/Portugal")]))
        #expect(deleted.photos == 2)
        #expect(sandbox.sidecarKeywords("A.JPG") == [])
        #expect(sandbox.sidecarKeywords("B.JPG") == ["tram"])
        let list = try await keywords.list()
        #expect(list.roots == [kw("Theirs"), kw("tram")])
        #expect(try await sandbox.search("kw:Portugal").isEmpty)

        try await keywords.undo()
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon"])
        #expect(try await keywords.list()[kw("Places/Portugal/Faro")]?.isDefined == true)
        #expect(try await sandbox.search("kw:Portugal") == ["A.JPG", "B.JPG"])
    }

    @Test func `Undo keeps what changed in a photo since, and the batches go back one at a time`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        let a = try await sandbox.id("A.JPG")
        try await keywords.apply(.add([kw("first")], to: [a]))
        try await keywords.apply(.add([kw("second")], to: [a]))
        // Another app, or a hand, changes the sidecar after both.
        var metadata = try #require(sandbox.sidecar("A.JPG")?.metadata)
        metadata.keywords = (metadata.keywords ?? []) + ["by hand"]
        try sandbox.sidecar("A.JPG", metadata)
        try await keywords.undo()
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon", "first", "by hand"])
        try await keywords.undo()
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon", "by hand"])
        #expect(try await keywords.lastUndoable() == nil)
        await #expect(throws: KeywordError.nothingToUndo) { try await keywords.undo() }
    }

    @Test func `open lists hear of each change`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(10)))
        let updates = try live.open(.query(LibraryQuery(parsing: "kw:Gulls")))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?.list.ids.count == 1)
        let keywords = sandbox.keywords(live: live)
        try await keywords.apply(.add([kw("Gulls")], to: sandbox.ids(["A.JPG", "B.JPG"])))
        await live.settle()
        #expect(await iterator.next()?.list.ids.count == 3)
        updates.close()
    }

    @Test func `a sidecar this build can't write is left as it is, and its photo keeps its keywords`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let store = SidecarStore()
        let newer = #"{"format":"app.redlamp.edit","recipe":{"version":99,"processVersion":1},"#
            + #""metadata":{"rating":1,"keywords":["Old"]}}"#
        try FileManager.default.removeItem(at: store.url(for: sandbox.url("B.JPG")))
        try Data(newer.utf8).write(to: store.url(for: sandbox.url("B.JPG")))
        try await sandbox.indexAll()
        let outcome = try await sandbox.keywords().apply(.add([kw("New")], to: sandbox.ids(["A.JPG", "B.JPG"])))
        #expect(outcome.written == 1 && outcome.skipped == [sandbox.url("B.JPG").path])
        #expect(try Data(contentsOf: store.url(for: sandbox.url("B.JPG"))) == Data(newer.utf8))
        #expect(try await sandbox.indexed("B.JPG") == ["Old"])
        #expect(try await sandbox.indexed("A.JPG") == ["New", "Places/Portugal/Lisbon"])
    }

    @Test func `a batch a forced quit stopped is finished at the next launch, or rolled back`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let names = (0 ..< 40).map { String(format: "P%02d.JPG", $0) }
        for name in names {
            try sandbox.photo(name, keywords: ["Shoot"])
        }
        try await sandbox.indexAll()
        let ids = try await sandbox.ids(names)

        for choice in [FileRecovery.finish, .rollBack] {
            let killed = sandbox.keywords()
            killed.interruption.withLock { $0 = 15 }
            await #expect(throws: LibraryKeywords.ForcedQuit.self) {
                try await killed.apply(.add([kw("Picked")], to: ids))
            }
            let written = names.filter { sandbox.sidecarKeywords($0)?.contains("Picked") == true }.count
            #expect((15 ..< 40).contains(written))

            let launch = sandbox.keywords()
            #expect(try await launch.unfinishedEntries().count == 1)
            await #expect(throws: KeywordError.self) { try await launch.apply(.add([kw("Other")], to: ids)) }
            let outcomes = try await launch.recover(choice)
            #expect(outcomes.map(\.state) == [choice == .finish ? .finished : .rolledBack])
            let expected = choice == .finish ? ["Shoot", "Picked"] : ["Shoot"]
            #expect(names.allSatisfy { sandbox.sidecarKeywords($0) == expected })
            for name in names {
                #expect(try await sandbox.indexed(name) == expected.sorted())
            }
            #expect(try await launch.unfinishedEntries().isEmpty)
            if choice == .finish {
                try await launch.undo()
                #expect(names.allSatisfy { sandbox.sidecarKeywords($0) == ["Shoot"] })
            }
        }
    }

    @Test func `the plan says what a change would do, and writes nothing`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        let plan = try await keywords.plan(.add([kw("tram")], to: sandbox.ids(["A.JPG", "B.JPG", "C.JPG"])))
        #expect(plan.title == "Add “tram” to 3 photos")
        #expect(plan.photos.map { ($0.path as NSString).lastPathComponent }.sorted() == ["A.JPG", "C.JPG"])
        let a = try await sandbox.id("A.JPG")
        #expect(plan.photos.first { $0.id == a }?.after == [kw("Places/Portugal/Lisbon"), kw("tram")])
        #expect(sandbox.sidecarKeywords("A.JPG") == ["Places/Portugal/Lisbon"])
        #expect(try await keywords.entries().isEmpty)
    }
}

import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// What a selection's photos hold, as the Library's keyword and metadata panels read it (LIB-21, LIB-22):
/// each keyword's count among them from the query engine's keywords, and what they share of IPTC Core's
/// fields from its column store.
struct SelectionReadsTests {
    @Test func `a selection counts each keyword its photos have, and not the keywords containing them`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("a.ARW", keywords: ["Places/Portugal/Lisbon", "Family"])
        try sandbox.photo("b.ARW", keywords: ["Places/Portugal/Lisbon"])
        try sandbox.photo("c.ARW", keywords: ["Places/Portugal"])
        try sandbox.photo("d.ARW")
        try await sandbox.indexAll()
        let ids = try await sandbox.ids(["a.ARW", "b.ARW", "c.ARW", "d.ARW"])
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()

        let counts = try await engine.keywordCounts(ofPhotos: ids)
        #expect(try counts == [
            #require(KeywordPath("Places/Portugal/Lisbon")): 2, #require(KeywordPath("Family")): 1,
            #require(KeywordPath("Places/Portugal")): 1,
        ])
        #expect(try await engine
            .keywordCounts(ofPhotos: [ids[1], ids[3]]) == [#require(KeywordPath("Places/Portugal/Lisbon")): 1])
        #expect(try await engine.keywordCounts(ofPhotos: []).isEmpty)

        // A keyword added since, the engine told of its photos, as LibraryLive tells it.
        let keywords = sandbox.keywords()
        try await keywords.apply(.add([#require(KeywordPath("Trips/2007"))], to: [ids[1], ids[3]]))
        try await engine.update(photos: [ids[1], ids[3]])
        let after = try await engine.keywordCounts(ofPhotos: ids)
        #expect(try after[#require(KeywordPath("Trips/2007"))] == 2 &&
            after[#require(KeywordPath("Places/Portugal/Lisbon"))] ==
            2)
    }

    @Test func `a selection's fields are shared, mixed or none, read from the store and the index`() async throws {
        let (sandbox, _, ids) = try await MetadataChangeTests.library()
        defer { sandbox.remove() }
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        try await metadata.apply(.set([.creator("Ana Sousa"), .city("Lisbon"), .title("Tram 28")], on: ids))
        try await metadata.apply(.set([.sublocation("Alfama")], on: Array(ids.prefix(10))))
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let store = try #require(engine.store)

        let all = try await metadata.fields(ofPhotos: ids, in: store)
        #expect(all.photos == 40)
        #expect(all[.creator] == .same("Ana Sousa") && all[.city] == .same("Lisbon") && all[.title] == .same("Tram 28"))
        #expect(all[.sublocation] == .mixed, "ten of the forty are in Alfama")
        #expect(all[.caption] == .mixed, "every other photo has a caption")
        #expect(all[.copyright] == SharedValue.none && all[.country] == SharedValue.none)
        #expect(all.captured == nil && all.undated == 40)

        let alfama = try await metadata.fields(ofPhotos: ids.prefix(10), in: store)
        #expect(alfama[.sublocation] == .same("Alfama"))
        let captioned = try await metadata.fields(ofPhotos: [ids[0], ids[2]], in: store)
        #expect(captioned[.caption] == .mixed, "their captions differ")
        let one = try await metadata.fields(ofPhotos: [ids[2]], in: store)
        #expect(one[.caption] == .same("Before 2"))
        #expect(try await metadata.fields(ofPhotos: [], in: store).photos == 0)
    }
}

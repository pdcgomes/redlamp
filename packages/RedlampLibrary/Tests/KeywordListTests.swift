import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The keyword list: the hierarchy built from the photos' keywords in the index and from the
/// definitions, with counts; the index filled from sidecars; and definitions that outlive the index.
struct KeywordListTests {
    @Test func `the list is a hierarchy of every photo's keywords, each counting its photos once`() async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("A.JPG", keywords: ["Places/Portugal/Lisbon", "Places/Portugal/Porto", "tram"])
        try sandbox.photo("B.JPG", keywords: ["Places/Portugal/Lisbon"])
        try sandbox.photo("C.JPG", keywords: ["Places/Portugal", "Birds/Gulls"])
        try sandbox.photo("D.JPG", keywords: ["birds"])
        try sandbox.photo("E.JPG")
        try await sandbox.indexAll()

        let list = try await sandbox.keywords().list()
        #expect(list.roots == [kw("birds"), kw("Birds"), kw("Places"), kw("tram")])
        let counts = list.ordered.map { "\($0.path.text) \($0.photos) \($0.count)" }
        #expect(counts == [
            "birds 1 1", "Birds 0 1", "Birds/Gulls 1 1", "Places 0 3", "Places/Portugal 1 3",
            "Places/Portugal/Lisbon 2 2", "Places/Portugal/Porto 1 1", "tram 1 1",
        ])
        #expect(list.children(of: kw("Places/Portugal")).map(\.name) == ["Lisbon", "Porto"])
        #expect(list.resolve("places/portugal/lisbon") == kw("Places/Portugal/Lisbon"))
        #expect(list.resolve("Porto") == kw("Places/Portugal/Porto"))
        #expect(list.resolve("Madrid") == nil)
        #expect(list.named("BIRDS").count == 2)
    }

    @Test func `the list's levels are in the Finder's order, numbers by value`() {
        let names = ["Day 10", "day 2", "Älvsjö", "Alpha", "Day 1"]
        let counts = Dictionary(uniqueKeysWithValues: names.map { (kw($0), KeywordCount(photos: 1, count: 1)) })
        let list = KeywordList(counts: counts, definitions: KeywordDefinitions())
        #expect(list.roots.map(\.text) == ["Alpha", "Älvsjö", "Day 1", "day 2", "Day 10"])
    }

    @Test func `a sidecar's keywords are the photo's in the index; without them, its own and its xmp's are`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("A.JPG", keywords: ["Mine/Lisbon", "Music/AC%2FDC"])
        try sandbox.write("A.xmp", OtherApps.lightroom(rating: 0, keywords: ["Theirs/Porto"]))
        try sandbox.photo("B.JPG", rating: 3)
        try sandbox.write("B.xmp", OtherApps.lightroom(rating: 0, keywords: ["Theirs/Porto"]))
        try sandbox.photo("C.JPG", keywords: [])
        try sandbox.write("C.xmp", OtherApps.lightroom(rating: 0, keywords: ["Theirs/Porto"]))
        try await sandbox.indexAll()
        #expect(try await sandbox.indexed("A.JPG") == ["Mine/Lisbon", "Music/AC%2FDC"])
        #expect(try await sandbox.indexed("B.JPG") == ["Theirs/Porto"])
        #expect(try await sandbox.indexed("C.JPG") == [])
        let list = try await sandbox.keywords().list()
        #expect(list[kw("Music/AC%2FDC")]?.name == "AC/DC")

        // A sidecar changed on its own is read again, and its keywords replace the photo's.
        try sandbox.sidecar("B.JPG", PhotoMetadata(rating: 3, keywords: ["Mine/Faro"]))
        try await sandbox.indexAll()
        #expect(try await sandbox.indexed("B.JPG") == ["Mine/Faro"])
    }

    @Test func `the definitions keep keywords without photos, their synonyms and options, through a rebuilt index`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        try sandbox.photo("A.JPG", keywords: ["Places/Portugal/Lisbon"])
        try await sandbox.indexAll()
        let keywords = sandbox.keywords()
        try await keywords.apply(.define(kw("Places/Portugal/Lisbon"), KeywordOptions(synonyms: ["Lisboa"])))
        try await keywords.apply(.define(kw("People/Ana"), KeywordOptions(isPerson: true)))
        try await keywords.apply(.define(kw("Places"), KeywordOptions(isCategory: true)))
        try await keywords.apply(.define(
            kw("Clients"), KeywordOptions(includeOnExport: false, exportContainingKeywords: false, isPrivate: true),
        ))
        try await keywords.apply(.sets(
            [KeywordSet(name: "Trip", keywords: [kw("Places/Portugal/Lisbon")])],
            active: "Trip",
        ))
        let before = try await keywords.list()

        let file = try String(contentsOf: keywords.definitionsURL, encoding: .utf8)
        #expect(file.contains(#""Places/Portugal/Lisbon" : {"#) && file.contains(#""person" : true"#))
        #expect(file.contains(#""format" : "app.redlamp.keywords""#))

        // The index goes, and is built again from the photos and their sidecars.
        sandbox.remove()
        for name in try FileManager.default.contentsOfDirectory(atPath: sandbox.library.url.path)
            where name.hasPrefix("Index.sqlite") {
            try FileManager.default.removeItem(at: sandbox.library.url.appending(path: name))
        }
        let rebuilt = try await LibraryIndex.open(at: sandbox.library.url.appending(path: "Index.sqlite"), readers: 2)
        defer { rebuilt.closeAndWait() }
        let run = await IndexerRun
            .collect(LibraryIndexer(index: rebuilt, configuration: .testing()).index([sandbox.root]))
        #expect(run.failures.isEmpty)
        let again = LibraryKeywords(index: rebuilt)
        let after = try await again.list()
        #expect(after.ordered.map(\.path) == before.ordered.map(\.path))
        #expect(after.ordered.map(\.count) == before.ordered.map(\.count))
        #expect(after[kw("Places/Portugal/Lisbon")]?.options.synonyms == ["Lisboa"])
        #expect(after[kw("People/Ana")]?.options.isPerson == true && after[kw("People/Ana")]?.count == 0)
        #expect(after[kw("Places")]?.options.isCategory == true)
        #expect(after[kw("Clients")]?.options.isPrivate == true)
        #expect(try await again.activeSet().keywords.first == kw("Places/Portugal/Lisbon"))
    }

    @Test func `the definitions file keeps what a newer Redlamp wrote, and isn't written over by an older one`() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Keywords.json")
        let json = #"""
        {"format": "app.redlamp.keywords", "version": 1, "colours": ["red"],
         "keywords": {"People/Ana": {"person": true, "thumbnail": "ab12"}, "Unused": {}}}
        """#
        try Data(json.utf8).write(to: url)
        var definitions = try KeywordDefinitions.load(from: url)
        #expect(definitions.keywords.keys.sorted() == [kw("People/Ana"), kw("Unused")])
        definitions.keywords[kw("Unused")] = KeywordOptions(synonyms: ["Spare"])
        try definitions.save(to: url)
        let saved = try KeywordDefinitions.load(from: url)
        #expect(saved.unknownFields["colours"] == .array([.string("red")]))
        #expect(saved.keywords[kw("People/Ana")]?.unknownFields["thumbnail"] == .string("ab12"))
        #expect(saved.keywords[kw("Unused")]?.synonyms == ["Spare"])

        try Data(json.replacingOccurrences(of: #""version": 1"#, with: #""version": 7"#).utf8).write(to: url)
        let newer = try KeywordDefinitions.load(from: url)
        #expect(!newer.isWritable)
        #expect(throws: KeywordError.newerDefinitions(url)) { try newer.save(to: url) }
    }
}

extension KeywordSandbox {
    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: url(path))
    }
}

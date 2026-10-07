import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The query language's keyword token by path, by a part of one and by synonym, and free text by
/// synonym; the column store and SQL alone answering alike.
struct KeywordQueryTests {
    private func sandbox() async throws -> KeywordSandbox {
        let sandbox = try await KeywordSandbox.make()
        try sandbox.photo("A.JPG", keywords: ["Places/Portugal/Lisbon", "tram"])
        try sandbox.photo("B.JPG", keywords: ["Places/Portugal/Porto"])
        try sandbox.photo("C.JPG", keywords: ["Places/Spain/Madrid"])
        try sandbox.photo("D.JPG", keywords: ["Music/AC%2FDC", "Places/Lisbon Port"])
        try sandbox.photo("E.JPG", keywords: ["AC/DC"])
        try sandbox.photo("F.JPG")
        try await sandbox.indexAll()
        return sandbox
    }

    @Test func `kw finds a keyword by its path, a parent its children, and any run of levels`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        #expect(try await sandbox.search(#"kw:"Places/Portugal/Lisbon""#) == ["A.JPG"])
        #expect(try await sandbox.search("kw:Places") == ["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        #expect(try await sandbox.search("kw:portugal") == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.search(#"kw:"Portugal/Porto""#) == ["B.JPG"])
        #expect(try await sandbox.search("kw:Lisbon") == ["A.JPG"])
        #expect(try await sandbox.search(#"kw:"Lisbon Port""#) == ["D.JPG"])
        #expect(try await sandbox.search("kw:Lisb") == [])
        #expect(try await sandbox.search("-kw:Places") == ["E.JPG", "F.JPG"])
        #expect(try await sandbox.search("has:keywords") == ["A.JPG", "B.JPG", "C.JPG", "D.JPG", "E.JPG"])
    }

    @Test func `a value with a slash names a keyword whose name holds one, as well as a path`() async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        #expect(try await sandbox.search(#"kw:"AC/DC""#) == ["D.JPG", "E.JPG"])
        #expect(try await sandbox.search(#"kw:"Music/AC%2FDC""#) == ["D.JPG"])
        #expect(try await sandbox.search(#"kw:"Music/AC/DC""#) == [], "three levels, as paths are written")
        #expect(try await sandbox.search(#"kw:"music/ac%2fdc""#) == ["D.JPG"])
    }

    @Test func `a synonym finds what its keyword finds, and free text finds the keywords whose synonyms hold it`(
    ) async throws {
        let sandbox = try await sandbox()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        try await keywords.apply(.define(
            kw("Places/Portugal/Lisbon"),
            KeywordOptions(synonyms: ["Lisboa", "Lisbonne"]),
        ))
        try await keywords.apply(.define(kw("Places/Portugal"), KeywordOptions(synonyms: ["Portuguese Republic"])))
        try await keywords.apply(.define(kw("Nowhere"), KeywordOptions(synonyms: ["Lisboa"])))
        try await keywords.apply(.define(kw("Places/Portugal/Porto"), KeywordOptions(synonyms: ["Pôrto Antigo"])))
        #expect(try await sandbox.search(#"kw:"porto antigo""#) == ["B.JPG"], "a synonym without its accent")
        #expect(try await sandbox.search("ntígo") == ["B.JPG"], "free text with an accent the synonym hasn't")
        #expect(try await sandbox.search("kw:lisboa") == ["A.JPG"])
        #expect(try await sandbox.search("kw:Lisbonne") == ["A.JPG"])
        #expect(try await sandbox.search(#"kw:"Portuguese Republic""#) == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.search("kw:Lisbo") == [])
        #expect(try await sandbox.search("lisbonn") == ["A.JPG"])
        #expect(try await sandbox.search("republic") == ["A.JPG", "B.JPG"])
        #expect(try await sandbox.search("kw:lisboa OR kw:Madrid") == ["A.JPG", "C.JPG"])
    }

    @Test func `the keyword functions match as the SQL registered with them does`() {
        #expect(KeywordQuery.matches(path: "Places/Portugal/Lisbon", value: "portugal/LISBON"))
        #expect(!KeywordQuery.matches(path: "Places/Portugal/Lisbon", value: "Places/Lisbon"))
        #expect(KeywordQuery.matches(path: "Music/AC%2FDC", value: "AC/DC"))
        #expect(KeywordQuery.matches(path: "AC/DC", value: "AC/DC"))
        #expect(!KeywordQuery.matches(path: "Music/AC%2FDC", value: "AC"))
        #expect(KeywordQuery.isWithin(path: "Places/Lisbon", owner: "Places"))
        #expect(!KeywordQuery.isWithin(path: "Places Old", owner: "Places"))
        let matcher = KeywordMatcher(
            keywords: [1: "Places", 2: "Places/Lisbon", 3: "Places Old", 4: "Places0", 5: "Places/Lisbon/Alfama"],
            synonyms: ["Places/Lisbon": ["Lisboa"]],
        )
        #expect(matcher.ids(matching: "Lisboa") == [2, 5])
        #expect(matcher.ids(matching: "places") == [1, 2, 5])
        #expect(matcher.ids(withSynonymContaining: "sbo") == [2, 5])
    }
}

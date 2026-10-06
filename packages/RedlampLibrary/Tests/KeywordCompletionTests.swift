import Foundation
import Testing
@testable import RedlampLibrary

/// Completion by prefix and by any word of a keyword or its synonyms, best first; entry as the
/// keywording field takes it; and keyword sets.
struct KeywordCompletionTests {
    private static let entries = [
        KeywordCompletion.Entry(path: kw("Animals/Birds/Black-tailed Godwit"), count: 4),
        KeywordCompletion.Entry(path: kw("Animals/Birds/Gull"), synonyms: ["Seagull", "Larus"], count: 40),
        KeywordCompletion.Entry(path: kw("Places/Portugal/Lisbon"), synonyms: ["Lisboa"], count: 120),
        KeywordCompletion.Entry(path: kw("Places/Lisbon Port"), count: 3),
        KeywordCompletion.Entry(path: kw("People/Lis Ferreira"), count: 120),
        KeywordCompletion.Entry(path: kw("Events/Gala"), count: 9),
        KeywordCompletion.Entry(path: kw("Événements/Été"), count: 1),
        KeywordCompletion.Entry(path: kw("gull"), count: 2),
    ]

    private func names(_ matches: [KeywordCompletion.Match]) -> [String] {
        matches.map(\.path.text)
    }

    @Test func `a name that starts with what's typed comes first, the most used first, then a word, then a synonym`() {
        let completion = KeywordCompletion(Self.entries)
        let gull = completion.matches("gul")
        #expect(names(gull) == ["Animals/Birds/Gull", "gull"])
        #expect(gull.map(\.kind) == [.nameStart, .nameStart])
        // Exactly the name comes before a longer one, however used.
        #expect(names(completion.matches("gull")) == ["Animals/Birds/Gull", "gull"])
        #expect(completion.matches("gull").map(\.kind) == [.name, .name])
        #expect(names(completion.matches("lis")) == [
            "People/Lis Ferreira", "Places/Portugal/Lisbon", "Places/Lisbon Port",
        ])
        #expect(names(completion.matches("tail")) == ["Animals/Birds/Black-tailed Godwit"])
        #expect(completion.matches("tail").first?.kind == .word)
        #expect(names(completion.matches("god")) == ["Animals/Birds/Black-tailed Godwit"])
        let seagull = completion.matches("seag")
        #expect(names(seagull) == ["Animals/Birds/Gull"] && seagull.first?.synonym == "Seagull")
        #expect(completion.matches("seag").first?.kind == .synonym)
        #expect(names(completion.matches("lisboa")) == ["Places/Portugal/Lisbon"])
        #expect(completion.matches("lisboa").first?.kind == .synonym)
        #expect(names(completion.matches("lis", limit: 1)) == ["People/Lis Ferreira"])
        #expect(completion.matches("").isEmpty && completion.matches("zzz").isEmpty)
    }

    @Test func `case, accents and width don't count, and a path narrows what completes`() {
        let completion = KeywordCompletion(Self.entries)
        #expect(names(completion.matches("ETE")) == ["Événements/Été"])
        #expect(names(completion.matches("ｇａｌａ")) == ["Events/Gala"])
        #expect(names(completion.matches("portugal > lis")) == ["Places/Portugal/Lisbon"])
        #expect(names(completion.matches("Places|Lis")) == ["Places/Portugal/Lisbon", "Places/Lisbon Port"])
        #expect(names(completion.matches("animals > birds > g")) == [
            "Animals/Birds/Gull",
            "Animals/Birds/Black-tailed Godwit",
        ])
    }

    @Test func `the list's categories aren't offered`() {
        let counts: [KeywordPath: KeywordCount] = [
            kw("Places"): KeywordCount(count: 5), kw("Places/Lisbon"): KeywordCount(photos: 5, count: 5),
        ]
        let list = KeywordList(
            counts: counts, definitions: KeywordDefinitions(keywords: [kw("Places"): KeywordOptions(isCategory: true)]),
        )
        #expect(KeywordCompletion(list).matches("pla").isEmpty)
        #expect(KeywordCompletion(list).matches("lis").map(\.path) == [kw("Places/Lisbon")])
    }

    @Test func `entry takes keywords as Lightroom's field does, the list's own where it has them`() throws {
        let counts: [KeywordPath: KeywordCount] = [
            kw("Places/Portugal/Lisbon"): KeywordCount(photos: 3, count: 3),
            kw("Animals/Gull"): KeywordCount(photos: 1, count: 1),
        ]
        let definitions = KeywordDefinitions(keywords: [kw("Animals/Gull"): KeywordOptions(synonyms: ["Seagull"])])
        let list = KeywordList(counts: counts, definitions: definitions)
        #expect(list.entered("lisbon, Seagull, Ferry") == [
            kw("Places/Portugal/Lisbon"),
            kw("Animals/Gull"),
            kw("Ferry"),
        ])
        #expect(list.entered("Places > Spain > Madrid") == [kw("Places/Spain/Madrid")])
        #expect(list.entered("Madrid < Spain < Places") == [kw("Places/Spain/Madrid")])
        #expect(list.entered("Animal | Dog") == [kw("Animal/Dog")])
        #expect(try list.entered("AC/DC") == [#require(KeywordPath(names: ["AC/DC"]))])
        #expect(list.entered(" , ,lisbon,lisbon ") == [kw("Places/Portugal/Lisbon")])
    }

    @Test func `keyword sets hold nine places, start as Lightroom's, and keep the user's in the definitions`(
    ) async throws {
        #expect(KeywordSet.builtIn.map(\.name) == [
            "Outdoor Photography",
            "Portrait Photography",
            "Wedding Photography",
        ])
        #expect(KeywordSet.builtIn.allSatisfy { $0.keywords.count == 9 && $0.keywords.allSatisfy { $0 != nil } })
        let set = KeywordSet(name: "Trip", keywords: [kw("Lisbon"), nil, kw("Porto")])
        #expect(set.keywords.count == 9 && set.keyword(forShortcut: 3) == kw("Porto"))
        #expect(set.keyword(forShortcut: 2) == nil && set.keyword(forShortcut: 10) == nil)

        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let keywords = sandbox.keywords()
        #expect(try await keywords.sets().map(\.name) == [
            KeywordSet.recentName, "Outdoor Photography", "Portrait Photography", "Wedding Photography",
        ])
        #expect(try await keywords.activeSet().name == KeywordSet.recentName)
        try await keywords.apply(.sets([set], active: "Trip"))
        #expect(try await keywords.sets().map(\.name) == [KeywordSet.recentName, "Trip"])
        #expect(try await keywords.activeSet() == set)
        let file = try String(contentsOf: keywords.definitionsURL, encoding: .utf8)
        #expect(file.contains(#""keywords" : ["#) && file.contains("null"))
        try await keywords.undo()
        #expect(try await keywords.sets().count == 4)
    }
}

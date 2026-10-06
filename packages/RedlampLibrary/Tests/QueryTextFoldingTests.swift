import Foundation
import Testing
@testable import RedlampLibrary

/// Text matched byte by byte once folded (LIB-06): what it finds is what Foundation finds ignoring
/// case, in the column engine and the SQL it compiles to alike, and typing over thousands of
/// folders with accents in their names stays within a keystroke's budget.
struct QueryTextFoldingTests {
    static let texts = [
        "Café", "Cafe\u{301}", "CAFÉ", "cafe", "Été à Montréal 2014", "E\u{301}te\u{301} a\u{300} Montre\u{301}al",
        "Straße", "STRASSE", "strasse", "ß", "ss", "s", "Maße", "MASSE",
        "İstanbul", "istanbul", "ISTANBUL", "ıstanbul", "Diyarbakır", "DİYARBAKIR", "i", "I", "ı", "İ", "i\u{307}",
        "ΟΔΟΣ", "οδος", "οδοσ", "Σίσυφος", "ΣΊΣΥΦΟΣ", "ς", "σ", "Σ",
        "旅行/日本 2019", "東京-0001.JPG", "日本", "東京", "京",
        "👍", "👍🏽", "Party 🎉 2020", "🎉", "👨‍👩‍👧", "👩", "🇵🇹 Lisboa", "🇵", "🇹",
        "Ærøskøbing", "ÆRØ", "ærø", "ﬁle", "FILE", "Ǆ", "ǆ", "ǅ", "Å", "A\u{30A}", "Å",
        "naïve", "NAI\u{308}VE", "e", "\u{301}", "é", "É", "e\u{301}",
    ]

    /// The texts, the fixture's folders, and parts of each: its first and last characters, a run
    /// from its middle, and each in capitals and small letters.
    static func needles(_ texts: [String]) -> [String] {
        var needles = Set(texts)
        for text in texts {
            let characters = Array(text)
            for length in [1, 2, 3] where characters.count >= length {
                needles.insert(String(characters.prefix(length)))
                needles.insert(String(characters.suffix(length)))
                let start = (characters.count - length) / 2
                needles.insert(String(characters[start ..< start + length]))
            }
            needles.insert(text.uppercased())
            needles.insert(text.lowercased())
            needles.insert(text.decomposedStringWithCanonicalMapping)
        }
        return needles.sorted()
    }

    static func fixtureFolders() -> [String] {
        LibraryFixture(spec: .init(photos: 20000)).folders.map { "/Volumes/Photos/" + $0.path }
    }

    /// Whether Foundation finds `needle` in `haystack` ignoring case. A needle with a letter whose case
    /// folding is longer (ß as ss, ﬁ as fi) is looked for folded: Foundation compares only the first
    /// letter of the longer form, finding ß in "sx" and in "istanbul".
    static func foundationFinds(_ needle: String, in haystack: String) -> Bool {
        let expands = needle.contains { character in
            character.unicodeScalars.count == 1
                && String(character).folding(options: .caseInsensitive, locale: nil).count > 1
        }
        let sought = expands ? needle.folding(options: .caseInsensitive, locale: nil) : needle
        return haystack.range(of: sought, options: .caseInsensitive) != nil
    }

    @Test func `a letter whose folding is longer is found only where all of it is`() {
        #expect(!Self.foundationFinds("ß", in: "sx") && Self.foundationFinds("ß", in: "Strasse"))
        #expect(!QueryText.contains("sx", "ß") && QueryText.contains("Strasse", "ß"))
    }

    @Test func `text is found where Foundation finds it ignoring case`() {
        let haystacks = Self.texts + Self.fixtureFolders()
        let needles = Self.needles(Self.texts + Self.fixtureFolders().prefix(40))
        var disagreements: [String] = []
        var found = 0
        for haystack in haystacks {
            let folded = FoldedText(haystack)
            for needle in needles {
                let expected = Self.foundationFinds(needle, in: haystack)
                let matched = QueryText.contains(haystack, needle)
                if matched != expected || folded.contains(FoldedText(needle)) != expected {
                    disagreements.append("\(needle.debugDescription) in \(haystack.debugDescription): \(expected)")
                }
                found += expected ? 1 : 0
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.count): \(disagreements.prefix(30))")
        #expect(found > 1000)
    }

    @Test func `the SQL the column engine compiles to matches text alike`() async throws {
        let folder = try TemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let index = try await LibraryIndex.open(at: folder.url.appending(path: "Index.sqlite"))
        let needles = Self.needles(Self.texts)
        let disagreements = try await index.read { reader in
            try QueryFunctions.register(on: reader.database)
            let statement = try reader.database.prepare("SELECT redlamp_contains(?, ?)")
            var disagreements: [String] = []
            for haystack in Self.texts {
                let folded = FoldedText(haystack)
                for needle in needles {
                    try statement.bind(haystack, at: 1)
                    try statement.bind(needle, at: 2)
                    let sql = try statement.first { $0.int(at: 0) == 1 } ?? false
                    if sql != folded.contains(FoldedText(needle)) {
                        disagreements.append("\(needle.debugDescription) in \(haystack.debugDescription)")
                    }
                }
            }
            return disagreements
        }
        await index.close()
        #expect(disagreements.isEmpty, "\(disagreements.prefix(30))")
    }

    /// `count` folders' paths with accents in most of their names, a share of them decomposed.
    static func accentedFolders(_ count: Int) -> [Int64: String] {
        let places = [
            "Été à Montréal", "Zürich", "Kraków", "São Paulo", "Ærøskøbing", "İzmir", "Δελφοί", "Straße",
            "Málaga", "Nîmes", "Reykjavík", "Ørsted", "Brontë", "Côte d’Azur", "Pécs", "Hội An",
        ]
        var random = SeededRandom(seed: 9)
        var folders: [Int64: String] = [:]
        for id in 1 ... count {
            let place = random.pick(places)
            var path = "/Volumes/Photos/\(2000 + id % 26)/\(2000 + id % 26)-0\(1 + id % 9)-1\(id % 10) \(place) \(id)"
            if id.isMultiple(of: 4) {
                path = path.decomposedStringWithCanonicalMapping
            }
            folders[Int64(id)] = path
        }
        return folders
    }

    /// p95 of a keystroke's folder lookup, typing each of `queries` a character at a time over
    /// `folders`, and the same with Foundation's matching as the lookup did before.
    static func keystrokes(
        over folders: [Int64: String],
        queries: [String],
    ) -> (folded: Duration, foundation: Duration) {
        let clock = ContinuousClock()
        let paths = Array(folders.values)
        var (folded, foundation): ([Duration], [Duration]) = ([], [])
        for _ in 0 ..< 3 {
            let vocabulary = QueryVocabulary(QueryNames(folders: folders))
            for query in queries {
                for length in 1 ... query.count {
                    let typed = String(query.prefix(length))
                    var started = clock.now
                    let ids = vocabulary.ids(in: .folders, matching: typed)
                    folded.append(clock.now - started)
                    started = clock.now
                    let before = paths.count { $0.range(of: typed, options: .caseInsensitive) != nil }
                    foundation.append(clock.now - started)
                    #expect(ids.count == before, "\(typed)")
                }
            }
        }
        func p95(_ timings: [Duration]) -> Duration {
            timings.sorted()[timings.count * 95 / 100]
        }
        return (p95(folded), p95(foundation))
    }

    static let queries = [
        "montréal",
        "MONTRE\u{301}AL",
        "zurich",
        "zürich",
        "straße",
        "strasse",
        "été",
        "kraków 12",
        "hội",
    ]

    @Test func `typing over folders with accents stays within a keystroke`() {
        let folders = Self.accentedFolders(5604)
        let (folded, foundation) = Self.keystrokes(over: folders, queries: Self.queries)
        let fixture = Dictionary(uniqueKeysWithValues: Self.fixtureFolders().enumerated().map { (Int64($0 + 1), $1) })
        let (fixtureFolded, fixtureFoundation) = Self.keystrokes(
            over: fixture, queries: ["montréal", "旅行", "日本 2019", "voyages/été", "clients", "2019"],
        )
        print(
            "QUERY-TEXT p95 a keystroke over 5,604 accented folders: \(folded) folded, \(foundation) Foundation;"
                +
                " over the fixture's \(fixture.count) folders: \(fixtureFolded) folded, \(fixtureFoundation) Foundation",
        )
    }
}

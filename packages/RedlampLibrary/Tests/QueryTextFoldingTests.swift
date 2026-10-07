import Foundation
import Testing
@testable import RedlampLibrary

/// Text matched byte by byte once folded (LIB-06, DEC-45): what it finds is what Foundation finds
/// ignoring case, accents and width, in whole characters, in the column engine and the SQL it
/// compiles to alike, and typing over thousands of folders with accents in their names stays within
/// a keystroke's budget.
struct QueryTextFoldingTests {
    static let texts = [
        "Café", "Cafe\u{301}", "CAFÉ", "cafe", "Été à Montréal 2014", "E\u{301}te\u{301} a\u{300} Montre\u{301}al",
        "São Paulo", "SAO PAULO", "Zürich", "Zu\u{308}rich", "zurich", "Hội An", "hoi an", "Ακρόπολη", "ακροπολη",
        "Straße", "STRASSE", "strasse", "ß", "ss", "s", "Maße", "MASSE",
        "İstanbul", "istanbul", "ISTANBUL", "ıstanbul", "Diyarbakır", "DİYARBAKIR", "i", "I", "ı", "İ", "i\u{307}",
        "ΟΔΟΣ", "οδος", "οδοσ", "Σίσυφος", "ΣΊΣΥΦΟΣ", "ς", "σ", "Σ",
        "旅行/日本 2019", "東京-0001.JPG", "日本", "東京", "京",
        "ガイド", "カ\u{3099}イト\u{3099}", "カイト", "ｶﾀｶﾅ", "カタカナ", "한국", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}",
        "ＦＵＬＬ ＷＩＤＴＨ", "Full Width", "ＩＭＧ＿００１", "img_001",
        "👍", "👍🏽", "Party 🎉 2020", "🎉", "👨‍👩‍👧", "👩", "🇵🇹 Lisboa", "🇵", "🇹",
        "Ærøskøbing", "ÆRØ", "ærø", "ﬁle", "FILE", "Ǆ", "ǆ", "ǅ", "Å", "A\u{30A}", "Å",
        "naïve", "NAI\u{308}VE", "e", "é", "É", "e\u{301}",
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

    static let ignoring: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Whether Foundation finds `needle` in `haystack` ignoring case, accents and width, starting and
    /// ending where the haystack's characters do, both composed (Foundation drops a mark it keeps in
    /// a composed ガ from a decomposed one). A needle with a letter whose folding is longer (ß as ss,
    /// ﬁ as fi) is looked for folded: Foundation compares only the first letter of the longer form,
    /// finding ß in "sx" and in "istanbul". Skin tones count, as Foundation's folding keeps them,
    /// though its search drops them as it drops accents.
    static func foundationFinds(_ needle: String, in haystack: String) -> Bool {
        let expands = needle.contains { character in
            character.unicodeScalars.count == 1 && QueryText.folded(String(character)).count > 1
        }
        let sought = (expands ? QueryText.folded(needle) : needle).precomposedStringWithCanonicalMapping
        let text = haystack.precomposedStringWithCanonicalMapping
        let toned = (sought + text).unicodeScalars.contains { (0x1F3FB ... 0x1F3FF).contains($0.value) }
        let options = toned ? ignoring.subtracting(.diacriticInsensitive) : ignoring
        var from = text.startIndex
        while from < text.endIndex, let found = text.range(
            of: sought,
            options: options,
            range: from ..< text.endIndex,
        ) {
            if found.lowerBound.samePosition(in: text) != nil, found.upperBound.samePosition(in: text) != nil {
                return true
            }
            from = text.index(after: found.lowerBound)
        }
        return false
    }

    @Test func `a letter whose folding is longer is found only where all of it is`() {
        #expect(!Self.foundationFinds("ß", in: "sx") && Self.foundationFinds("ß", in: "Strasse"))
        #expect(!QueryText.contains("sx", "ß") && QueryText.contains("Strasse", "ß"))
        #expect(!QueryText.contains("Straße", "stras") && QueryText.contains("Straße", "strass"))
    }

    @Test func `accents and width don't count, as completion folds them`() {
        #expect(QueryText.contains("São Paulo", "sao") && QueryText.contains("Zürich", "ZURICH"))
        #expect(QueryText.contains("Café", "cafe") && QueryText.contains("Cafe\u{301}", "café"))
        #expect(QueryText.contains("cafe", "Café"), "an accent typed finds a name without it")
        #expect(QueryText.contains("Ακρόπολη", "ακροπολη") && QueryText.contains("Hội An", "hoi"))
        #expect(QueryText.contains("ＦＵＬＬ ＷＩＤＴＨ", "full w") && QueryText.contains("Full Width", "ＦＵＬＬ"))
        #expect(QueryText.contains("ｶﾀｶﾅ", "カタカナ") && QueryText.contains("カタカナ", "ｶﾀｶﾅ"))
        #expect(QueryText.isSame("Héro", "HERO") && QueryText.isSame("ＨＥＲＯ", "hero") && !QueryText.isSame(
            "Hero",
            "Her",
        ))
        for (text, typed) in [("São Paulo", "sao paulo"), ("Zürich", "zurich"), ("ＦＵＬＬ", "full"), ("Ärzte", "arzte")] {
            #expect(QueryText.folded(text) == QueryText.folded(typed), "\(text) as completion folds it")
        }
    }

    @Test func `a match never starts or ends inside a character`() {
        #expect(!QueryText.contains("👍🏽", "👍") && QueryText.contains("Party 👍🏽", "👍🏽"))
        #expect(!QueryText.contains("🇵🇹 Lisboa", "🇵") && QueryText.contains("🇵🇹 Lisboa", "🇵🇹"))
        #expect(!QueryText.contains("ﬁle", "f") && QueryText.contains("ﬁle", "fi"))
        #expect(!QueryText.contains("한국", "\u{1112}"), "a letter of a syllable")
        #expect(!QueryText.contains("ガイド", "カ") && !QueryText.contains("カ\u{3099}イト\u{3099}", "カイト"))
        #expect(QueryText.contains("ガイド", "カ\u{3099}イ") && QueryText.contains("カ\u{3099}イト\u{3099}", "ガイド"))
        #expect(
            QueryText.contains("Été", "e") && QueryText.contains("E\u{301}te\u{301}", "ete"),
            "an accent folds away",
        )
    }

    @Test func `text is found where Foundation finds it ignoring case, accents and width, in whole characters`() {
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
    /// `folders`, and the same with Foundation's matching ignoring case, accents and width, as the
    /// lookup once matched text beyond ASCII.
    static func keystrokes(
        over folders: [Int64: String],
        queries: [String],
    ) -> (folded: Duration, foundation: Duration) {
        let clock = ContinuousClock()
        let paths = Array(folders.values)
        var (folded, foundation): ([Duration], [Duration]) = ([], [])
        for round in 0 ..< 3 {
            let vocabulary = QueryVocabulary(QueryNames(folders: folders))
            for query in queries {
                for length in 1 ... query.count {
                    let typed = String(query.prefix(length))
                    var started = clock.now
                    let ids = vocabulary.ids(in: .folders, matching: typed)
                    folded.append(clock.now - started)
                    started = clock.now
                    _ = paths.count { $0.range(of: typed, options: ignoring) != nil }
                    foundation.append(clock.now - started)
                    if round == 0 {
                        #expect(ids.count == paths.count { foundationFinds(typed, in: $0) }, "\(typed)")
                    }
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
        "montreal",
        "zurich",
        "zürich",
        "straße",
        "strasse",
        "été",
        "kraków 12",
        "hội",
        "sao paulo",
        "ＺＵＲＩＣＨ",
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

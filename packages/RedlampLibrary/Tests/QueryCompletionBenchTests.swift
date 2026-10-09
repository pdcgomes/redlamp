import Foundation
import Testing
@testable import RedlampLibrary

/// Completion's keystrokes over a large library's names (LIB-18, LIB-19): small enough for every run,
/// and at 100,000 names with `REDLAMP_COMPLETION_BENCH=1` (which xcodebuild hands to the tests from
/// `TEST_RUNNER_REDLAMP_COMPLETION_BENCH=1`), `REDLAMP_COMPLETION_BENCH_NAMES` names. Its budget, p95
/// under 2 ms a keystroke, is a Release build's.
struct QueryCompletionBenchTests {
    static let cameras = [
        "X-T5", "X-T4", "X-H2S", "X100V", "ILCE-7M4", "ILCE-7RM5", "ILCE-6400", "DSC-RX100M7", "Canon EOS R5",
        "Canon EOS R6 Mark II", "Canon EOS 5D Mark IV", "Canon EOS 90D", "NIKON Z 8", "NIKON Z 6_2", "NIKON D850",
        "DC-GH6", "iPhone 15 Pro", "iPhone 13", "Pixel 8 Pro", "Galaxy S23 Ultra", "FC3582", "FUJIFILM GFX100S",
        "LEICA Q3", "OM-1", "Hasselblad X2D 100C",
    ]
    static let lenses = [
        "FE 24-70mm F2.8 GM II", "FE 70-200mm F2.8 GM OSS II", "FE 35mm F1.4 GM", "FE 85mm F1.4 GM",
        "FE 16-35mm F2.8 GM", "RF24-70mm F2.8 L IS USM", "RF70-200mm F2.8 L IS USM", "RF50mm F1.2 L USM",
        "RF15-35mm F2.8 L IS USM", "NIKKOR Z 24-70mm f/2.8 S", "NIKKOR Z 70-200mm f/2.8 VR S", "NIKKOR Z 50mm f/1.8 S",
        "XF16-55mmF2.8 R LM WR", "XF56mmF1.2 R WR", "XF23mmF1.4 R LM WR", "XF100-400mmF4.5-5.6 R LM OIS WR",
        "M.Zuiko 12-40mm F2.8 PRO", "Sigma 35mm F1.4 DG DN Art", "Tamron 28-75mm F/2.8 Di III VXD G2",
        "Leica Summilux 28 f/1.7 ASPH.",
    ]
    static let cities = [
        "Lisbon", "Porto", "Tokyo", "Kyoto", "New York", "San Francisco", "London", "Paris", "Reykjavík", "Cape Town",
        "Sydney", "Buenos Aires", "Montréal", "Marrakesh", "Hanoi", "São Paulo", "Zürich", "Kraków", "Guimarães",
        "東京",
    ]
    static let countries = ["Portugal", "Japan", "Iceland", "Morocco", "Vietnam", "Brazil", "Switzerland", "Poland"]
    static let events = [
        "Wedding", "Lookbook", "Birthday", "Trip", "Portraits", "Concert", "Family", "Holiday", "Garden", "Studio",
        "Match", "Graduation", "Street", "Market", "Festival",
    ]
    static let clients = ["Acme Corp", "Northwind", "Contoso", "Globex", "Initech", "Umbrella", "Hooli", "Vandelay"]

    /// About `count` names as a large library has them: lib-1m's 5,604 folders by year and by client,
    /// 25 cameras, 20 lenses, 28 places, and for the rest synthetic keywords three levels deep, a
    /// tenth with a synonym (`KeywordScenario.keywords`); the places as the store's names.
    static func library(_ count: Int) -> (vocabulary: QueryVocabulary, places: NameTable) {
        var random = SeededRandom(seed: 2026)
        let root = "/Volumes/Photos/lib-1m.noindex"
        var folders: Set<String> = [root, root + "/Clients", root + "/Japan/東京駅", root + "/Voyages/São João"]
        for client in clients {
            folders.insert("\(root)/Clients/\(client)")
        }
        for year in 2000 ... 2025 {
            folders.insert("\(root)/\(year)")
        }
        let folderCount = min(5604, count / 4)
        while folders.count < folderCount {
            let year = random.int(in: 2000 ... 2025)
            let day = String(format: "%04d-%02d-%02d", year, random.int(in: 1 ... 12), random.int(in: 1 ... 28))
            let event = random.pick(events)
            folders.insert(random.chance(0.2) ? "\(root)/Clients/\(random.pick(clients))/\(day) \(event)"
                : "\(root)/\(year)/\(day) \(event)")
        }
        let subjects = [
            "Subjects/Landscapes",
            "Subjects/landscape/black and white",
            "Places/Portugal/Lisbon",
            "Places/Japan/Tokyo",
            "Events/Weddings",
        ]
        let fixed = cameras.count + lenses.count + folders.count + subjects.count
        let keywords = KeywordScenario.keywords(max(count - fixed, 0))
        var names = QueryNames()
        for (number, folder) in folders.sorted().enumerated() {
            names.folders[Int64(number + 1)] = folder
        }
        for (number, camera) in cameras.enumerated() {
            names.cameras[Int64(number + 1)] = camera
        }
        for (number, lens) in lenses.enumerated() {
            names.lenses[Int64(number + 1)] = lens
        }
        for (number, path) in (subjects + keywords.map(\.path.text)).enumerated() {
            names.keywords[Int64(number + 1)] = path
        }
        for keyword in keywords where !keyword.synonyms.isEmpty {
            names.keywordSynonyms[keyword.path.text] = keyword.synonyms
        }
        let places = NameTable(cities.map { RankedName(.city, $0) } + countries.map { RankedName(.country, $0) })
        return (QueryVocabulary(names), places)
    }

    /// The study's names, its typos and letters in order among them, then `keywords` keywords' names,
    /// each typed a character at a time.
    static func typing(_ vocabulary: QueryVocabulary, keywords: Int) -> [String] {
        var texts = [
            "nz8", "z8", "r5", "xt5", "2470gm", "eosr6", "東京", "lisbom", "fujiflim", "wedidng", "landscpae",
            "portgual", "nikkon", "sao", "zurich", "wedding", "acme", "2019-03",
        ]
        var random = SeededRandom(seed: 22)
        let paths = Array(vocabulary.names.keywords.values).sorted()
        for _ in 0 ..< keywords {
            texts.append(String((KeywordPath(random.pick(paths))?.name ?? "").prefix(10)))
        }
        return texts.filter { !$0.isEmpty }.flatMap { text in (1 ... text.count).map { String(text.prefix($0)) } }
    }

    @Test func `completion over a few thousand names finds what's typed, typos and letters in order among it`() {
        let (vocabulary, places) = Self.library(4000)
        func first(_ text: String) -> QueryCompletion? {
            vocabulary.completions(text, fields: QueryCompletion.fields, limit: 8, storeNames: places).first
        }
        #expect(first("nz8")?.value == "NIKON Z 8")
        #expect(first("xt5")?.value == "X-T5")
        #expect(first("2470gm")?.value == "FE 24-70mm F2.8 GM II")
        #expect(first("eosr6")?.value == "Canon EOS R6 Mark II")
        #expect(first("lisbom").map { [$0.value, String($0.typos)] } == ["Lisbon", "1"])
        #expect(first("portgual")?.value == "Portugal")
        #expect(first("fujiflim")?.value == "FUJIFILM GFX100S")
        #expect(first("nikkon")?.value.hasPrefix("NIKON") == true)
        #expect(first("wedidng")?.value == "Events/Weddings")
        let landscapes = vocabulary.completions(
            "landscpae",
            fields: QueryCompletion.fields,
            limit: 8,
            storeNames: places,
        )
        #expect(landscapes.prefix(2).map(\.value) == ["landscape", "Subjects/Landscapes"])
        #expect(landscapes.first?.field == .orientation, "the shortest name a typo from it")
        #expect(first("sao")?.value == "São Paulo")
        #expect(first("東京")?.value == "東京")
        for text in Self.typing(vocabulary, keywords: 10) {
            _ = vocabulary.completions(text, fields: QueryCompletion.fields, limit: 8, storeNames: places)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_COMPLETION_BENCH"] == "1"), .measuresSpeed)
    func `completion over 100,000 names, a keystroke at a time`() {
        let count = ProcessInfo.processInfo.environment["REDLAMP_COMPLETION_BENCH_NAMES"].flatMap { Int($0) } ?? 100_000
        let clock = ContinuousClock()
        let (vocabulary, places) = Self.library(count)
        var started = clock.now
        let table = vocabulary.rankedNames()
        let building = clock.now - started
        let texts = Self.typing(vocabulary, keywords: 60)
        var durations: [Duration] = []
        var found = 0
        for _ in 0 ..< 3 {
            for text in texts {
                started = clock.now
                let completions = vocabulary.completions(
                    text, fields: QueryCompletion.fields, limit: 8, storeNames: places,
                )
                durations.append(clock.now - started)
                found += completions.isEmpty ? 0 : 1
            }
        }
        let sorted = durations.sorted()
        func milliseconds(_ fraction: Double) -> String {
            String(
                format: "%.3f",
                sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] / .milliseconds(1),
            )
        }
        print("COMPLETION-BENCH names \(table.count + places.count) (entries, synonyms included), table made in "
            + String(format: "%.1f", building / .milliseconds(1)) + " ms")
        print("COMPLETION-BENCH \(durations.count) keystrokes: p50 \(milliseconds(0.5)) ms, p95 \(milliseconds(0.95)) "
            + "ms, p99 \(milliseconds(0.99)) ms, max \(milliseconds(1)) ms; \(found) found something")
        #expect(sorted[Int(Double(sorted.count) * 0.95)] < .milliseconds(2), "p95 within 2 ms")
    }
}

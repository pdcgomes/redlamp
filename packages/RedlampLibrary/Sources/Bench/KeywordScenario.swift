import Foundation
import RedlampDocument
import RedlampEngineAPI

public extension BenchScenarios {
    /// Adds the keywords scenario (LIB-21) after the others.
    static func registerKeywords(
        keywords: Int = KeywordScenario.defaultKeywords,
        photos: Int = KeywordScenario.defaultPhotos,
    ) {
        register(KeywordScenario(keywords: keywords, photos: photos))
    }
}

/// Keywords at a professional's scale (LIB-21). Completion over `keywords` synthetic keywords, in a
/// hierarchy with synonyms on a tenth, each of `queries` names typed a character at a time (the
/// budget: p95 under 2 ms a keystroke). Then a keyword added to `photos` photos and undone, in a
/// temporary folder on the Mac's own disk, half of them with a sidecar holding an edit and the rest
/// getting one: the journal, the index and its lists, and the sidecars timed apart, beside what one
/// sidecar's save costs on its own, and every sidecar checked after each. Nothing is read from the
/// fixture, and the folder is removed at the end.
public struct KeywordScenario: BenchScenario {
    public static let defaultKeywords = 100_000
    public static let defaultPhotos = 10000
    static let budget = 2.0
    static let folderSize = 500

    public let name = "keywords"
    public let keywords: Int
    public let photos: Int
    public let queries: Int

    public init(
        keywords: Int = KeywordScenario.defaultKeywords,
        photos: Int = KeywordScenario.defaultPhotos,
        queries: Int = 200,
    ) {
        self.keywords = max(keywords, 10)
        self.photos = max(photos, 2)
        self.queries = max(queries, 1)
    }

    public func run(_: BenchContext) async throws -> [BenchResult] {
        try await measure()
    }

    public func measure(in parent: URL = FileManager.default.temporaryDirectory) async throws -> [BenchResult] {
        try await completion() + adding(in: parent)
    }

    // MARK: - Completion

    /// `count` keywords three levels deep, named from syllables, a tenth with a synonym, used as
    /// libraries are: a few very often, most rarely.
    static func keywords(_ count: Int, seed: UInt64 = 21) -> [KeywordCompletion.Entry] {
        var random = SeededRandom(seed: seed)
        let syllables = [
            "ka", "lo", "mi", "ne", "ru", "sa", "to", "vi", "be", "da", "fe", "go", "hu", "ji", "la", "mo", "pa",
            "qui", "re", "su", "ta", "ul", "ve", "xo", "ya", "ze", "bra", "cre", "dro", "fla", "glo", "pri", "tra",
        ]
        func word(_ random: inout SeededRandom) -> String {
            let word = (0 ..< random.int(in: 2 ... 4)).map { _ in random.pick(syllables) }.joined()
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        func name(_ random: inout SeededRandom) -> String {
            (0 ..< random.int(in: 1 ... 3)).map { _ in word(&random) }.joined(separator: " ")
        }
        let tops = (0 ..< 40).map { _ in name(&random) }
        let middles = (0 ..< 2000).map { number in KeywordPath(names: [tops[number % tops.count], name(&random)])! }
        var entries: [KeywordCompletion.Entry] = []
        var seen = Set<KeywordPath>()
        while entries.count < count {
            let parent = random.pick(middles)
            guard let path = parent.appending(name(&random)), seen.insert(path).inserted else { continue }
            let synonyms = random.chance(0.1) ? [name(&random)] : []
            let count = Int(pow(10, random.unit() * random.unit() * 4))
            entries.append(KeywordCompletion.Entry(path: path, synonyms: synonyms, count: count))
        }
        return entries
    }

    private func completion() throws -> [BenchResult] {
        let entries = Self.keywords(keywords)
        let clock = ContinuousClock()
        var started = clock.now
        let completion = KeywordCompletion(entries)
        let building = clock.now - started
        var random = SeededRandom(seed: 22)
        var durations: [Duration] = []
        var found = 0
        for _ in 0 ..< queries {
            let typed = Array(random.pick(entries).path.name.prefix(10))
            for length in 1 ... typed.count {
                let text = String(typed.prefix(length))
                started = clock.now
                let matches = completion.matches(text, limit: 10)
                durations.append(clock.now - started)
                found += matches.isEmpty ? 0 : 1
            }
        }
        let label = BenchResult.grouped(keywords)
        return [
            BenchResult(
                scenario: name, id: "library-keywords-completion-build",
                name: "Completion over \(label) keywords made", value: building.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-completion",
                name: "\(label) keywords completed as \(queries) names are typed, \(durations.count) keystrokes, p95",
                value: QueryScenario.percentile(durations, 0.95), unit: "ms", budget: .below(Self.budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-keywords-completion-p50", name: "The same, p50",
                value: QueryScenario.percentile(durations, 0.5), unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-completion-found", name: "Keystrokes that completed a keyword",
                value: Double(found), unit: "keystrokes", budget: .exactly(Double(durations.count), "keystrokes"),
            ),
        ]
    }

    // MARK: - A keyword on many photos

    private func adding(in parent: URL) async throws -> [BenchResult] {
        let folder = parent.appending(path: "redlamp-keywords-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appending(path: "Photos", directoryHint: .isDirectory)
        let paths = LibraryPaths(root: folder.appending(path: "Library", directoryHint: .isDirectory))
        let (index, ids, names) = try await Self.write(photos, root: root, paths: paths)
        defer { index.closeAndWait() }
        let single = try await LibraryIndex.offCaller { try Self.saveCost(in: folder) }
        let keywords = LibraryKeywords(index: index, paths: paths)
        let clock = ContinuousClock()
        var started = clock.now
        let plan = try await keywords.plan(.add([KeywordPath(names: ["Clients", "Acme", "Picked"])!], to: ids))
        let planning = clock.now - started
        started = clock.now
        let added = try await keywords.run(plan)
        let adding = clock.now - started
        let afterAdding = Self.check(names, root: root, holding: true)
        started = clock.now
        let undone = try await keywords.undo()
        let undoing = clock.now - started
        let afterUndo = Self.check(names, root: root, holding: false)

        let label = BenchResult.grouped(photos)
        let perPhoto = added.sidecarTime.seconds * 1000 / Double(max(added.written, 1))
        return [
            BenchResult(
                scenario: name, id: "library-keywords-add-plan",
                name: "A keyword for \(label) photos: the batch planned",
                value: planning.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-add",
                name: "A keyword added to \(label) photos, sidecars and all",
                value: adding.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-add-journal", name: "Of it, the journal written and synced",
                value: added.journalTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-add-index", name: "Of it, the index and its lists",
                value: added.indexTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-add-sidecars",
                name: "Of it, \(BenchResult.grouped(added.written)) sidecars written",
                value: added.sidecarTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-add-per-sidecar", name: "A sidecar's share of that",
                value: perPhoto, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-save-cost",
                name: "One sidecar saved on this disk on its own (SidecarStore, mean of 200)", value: single * 1000,
                unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-undo", name: "The keyword taken off again with Undo",
                value: undoing.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-undo-index", name: "Of it, the index and its lists",
                value: undone.indexTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-undo-sidecars",
                name: "Of it, \(BenchResult.grouped(undone.written)) sidecars written back",
                value: undone.sidecarTime.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-keywords-wrong", name: "Sidecars not as each step leaves them",
                value: Double(afterAdding + afterUndo), unit: "photos", budget: .exactly(0, "photos"),
            ),
        ]
    }

    /// Writes an index of `count` photos in folders of 500, every other one with a sidecar holding an
    /// edit; the photos' files themselves aren't needed. Returns the index, the photos' IDs, and their
    /// paths below `root`.
    static func write(_ count: Int, root: URL, paths: LibraryPaths) async throws -> (LibraryIndex, [Int64], [String]) {
        let names = (0 ..< count).map { String(format: "Day %03d/IMG_%05d.JPG", $0 / folderSize + 1, $0) }
        let sidecar = try sidecarJSON()
        try await LibraryIndex.offCaller {
            for number in stride(from: 0, to: count, by: folderSize) {
                try FileManager.default.createDirectory(
                    at: root.appending(path: (names[number] as NSString).deletingLastPathComponent),
                    withIntermediateDirectories: true,
                )
            }
            DispatchQueue.concurrentPerform(iterations: count / 2 + count % 2) { half in
                let package = root.appending(path: names[half * 2] + ".redlamp")
                try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
                try? sidecar.write(to: package.appending(path: SidecarStore.editFile))
            }
        }
        let index = try await LibraryIndex.open(at: paths.index)
        let rootPath = LibraryIndexer.path(root)
        let ids = try await index.write { writer -> [Int64] in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "BENCH-VOLUME", name: "Bench", kind: .ssd))
            _ = try writer.upsertRoot(RootRecord(volume: volume, path: rootPath))
            var records: [PhotoRecord] = []
            for (number, name) in names.enumerated() {
                let folder = (name as NSString).deletingLastPathComponent
                guard let folderID = try writer.folderID(forPath: rootPath + "/" + folder) else { continue }
                records.append(PhotoRecord(
                    folder: folderID, name: (name as NSString).lastPathComponent, size: 1000,
                    captured: Date(timeIntervalSince1970: 1_709_294_400 + Double(number)), edited: number % 2 == 0,
                    indexed: 1,
                ))
            }
            return try writer.upsertPhotos(records)
        }
        return (index, ids, names)
    }

    /// A sidecar with an edit and a rating, as `SidecarStore` writes it.
    private static func sidecarJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var recipe = EditRecipe()
        recipe[.exposure] = 0.35
        recipe[.contrast] = 12
        return try encoder.encode(Sidecar(
            recipe: recipe, metadata: PhotoMetadata(rating: 3), modified: Date(timeIntervalSince1970: 1_790_000_000),
        ))
    }

    /// What one sidecar's save costs on its own: 200 new ones saved, one after another; in seconds.
    static func saveCost(in folder: URL) throws -> Double {
        let place = folder.appending(path: "Save cost", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let store = SidecarStore()
        let clock = ContinuousClock()
        let started = clock.now
        for number in 0 ..< 200 {
            let sidecar = Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(keywords: ["Clients/Acme/Picked"]))
            try store.save(sidecar, for: place.appending(path: "IMG_\(number).JPG"))
        }
        return (clock.now - started).seconds / 200
    }

    /// How many of the photos' sidecars don't hold the keyword as they should, and of those that had a
    /// sidecar before, how many lost their edit.
    static func check(_ names: [String], root: URL, holding: Bool) -> Int {
        let store = SidecarStore()
        return names.enumerated().count { number, name in
            let sidecar = store.load(for: root.appending(path: name))
            let holds = sidecar?.metadata?.keywords?.contains("Clients/Acme/Picked") == true
            let edited = number % 2 == 0
            let keptEdit = !edited || sidecar?.recipe[.exposure] == 0.35
            let gone = holding || edited || sidecar == nil
            return holds != holding || !keptEdit || !gone
        }
    }
}

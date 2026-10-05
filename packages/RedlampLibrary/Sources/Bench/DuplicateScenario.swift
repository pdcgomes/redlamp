import Foundation

public extension BenchScenarios {
    /// Adds the exact duplicates' scenario (LIB-39) after the others, grouping `photos` synthetic photos.
    static func registerDuplicates(photos: Int = DuplicateScenario.defaultPhotos) {
        register(DuplicateScenario(photos: photos))
    }
}

/// Finds exact duplicates (LIB-39). First the candidates of a million synthetic photos, 1% of them
/// copies of others, are grouped in memory as the index's one pass hands them over (the design's
/// budget: under a second, off the main thread), with what grouping takes in memory. Then the
/// fixture is indexed (once, kept for the next runs as search's index is), its candidates grouped,
/// and confirmed through the fixture's simulated volume with no hashes recorded: megabytes read a
/// second, and, for a fixture made with duplicates, that the copies confirmed are the manifest's.
/// Confirming again reads nothing.
public struct DuplicateScenario: BenchScenario {
    public static let defaultPhotos = 1_000_000
    /// The synthetic photos that are copies of others.
    public static let copyShare = 0.01
    static let budget = 1000.0

    public let name = "duplicates"
    /// The synthetic library's photos.
    public let photos: Int
    let indexFolder: URL?

    public init(photos: Int = DuplicateScenario.defaultPhotos) {
        self.init(photos: photos, indexFolder: nil)
    }

    /// Keeps the fixture's index in `indexFolder` rather than in the temporary folder.
    init(photos: Int, indexFolder: URL?) {
        self.photos = max(photos, 1)
        self.indexFolder = indexFolder
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        try await Self.grouping(photos: photos, share: Self.copyShare, seed: context.manifest.spec.seed)
            + confirming(context)
    }

    /// Groups `photos` synthetic photos, `share` of them copies of others.
    static func grouping(photos: Int, share: Double, seed: UInt64) -> [BenchResult] {
        let library = SyntheticDuplicates(photos: photos, share: share, seed: seed)
        let grouper = library.grouper()
        let clock = ContinuousClock()
        let started = clock.now
        let candidates = grouper.candidates()
        let elapsed = clock.now - started
        let name = "duplicates"
        let size = BenchResult.grouped(photos)
        return [
            BenchResult(
                scenario: name, id: "library-duplicates-group",
                name: "Candidates of \(size) photos grouped, \(Int(share * 100))% of them copies",
                value: elapsed.seconds * 1000, unit: "ms", budget: .below(budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-group-memory", name: "Grouping's memory, a photo",
                value: Double(candidates.memoryFootprint) / Double(max(photos, 1)), unit: "bytes",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-group-total", name: "Grouping's memory, all \(size)",
                value: Double(candidates.memoryFootprint) / 1_000_000, unit: "MB",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-group-copies", name: "Copies among them found",
                value: Double(candidates.copyCount), unit: "photos",
                budget: .exactly(Double(library.copies), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-group-groups", name: "Groups found",
                value: Double(candidates.groups.count), unit: "groups",
                budget: .exactly(Double(library.originals), "groups"),
            ),
        ]
    }

    private func confirming(_ context: BenchContext) async throws -> [BenchResult] {
        let url = (indexFolder ?? QueryScenario.indexFolder(for: context)).appending(path: "Index.sqlite")
        let index = try await LibraryIndex.open(at: url)
        if try await index.read({ try $0.photoCount() }) != context.manifest.totals.photos {
            for await _ in LibraryIndexer(index: index).index([context.fixture]) {}
        }
        try await index.write { try $0.removePhotoHashes() }
        let finder = DuplicateFinder(index: index, fileSystem: context.fileSystem())
        let clock = ContinuousClock()
        let grouping = clock.now
        let candidates = try await finder.candidates()
        let grouped = clock.now - grouping
        let confirming = clock.now
        let confirmation = try await finder.confirm(candidates)
        let confirmed = clock.now - confirming
        let again = try await finder.confirm(candidates)
        await index.close()

        let seconds = max(confirmed.seconds, 1e-9)
        let copies = confirmation.duplicates.reduce(0) { $0 + $1.photos.count - 1 }
        return [
            BenchResult(
                scenario: name, id: "library-duplicates-fixture-group",
                name: "Candidates of the fixture's \(BenchResult.grouped(candidates.photosGrouped)) photos grouped",
                value: grouped.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-candidates", name: "Candidates",
                value: Double(candidates.photoCount),
                unit: "photos",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-copies", name: "Copies confirmed", value: Double(copies),
                unit: "photos", budget: context.manifest.totals.duplicates.map { .exactly(Double($0), "photos") },
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-confirm", name: "Candidates confirmed",
                value: confirmed.seconds, unit: "s",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-confirm-rate",
                name: "Read and hashed through the \(context.profile.name) volume, a second",
                value: Double(confirmation.bytesRead) / 1_000_000 / seconds, unit: "MB/s",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-confirm-files", name: "Files hashed, a second",
                value: Double(confirmation.hashed) / seconds, unit: "files/s",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-different", name: "Candidates that turned out different",
                value: Double(confirmation.different.count), unit: "photos",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-unconfirmed", name: "Candidates left unconfirmed",
                value: Double(confirmation.unconfirmed.count), unit: "photos",
            ),
            BenchResult(
                scenario: name, id: "library-duplicates-reread", name: "Files read again when confirming again",
                value: Double(again.hashed), unit: "files", budget: .exactly(0, "files"),
            ),
        ]
    }
}

/// A library's content keys and sizes, from a seed: each photo after the first a copy of an earlier
/// one with a chance of `share`, of the photo that one is a copy of if it's one too.
struct SyntheticDuplicates {
    let photos: Int
    let share: Double
    let seed: UInt64

    /// The photo whose file photo `index` is a copy of; nil for a photo that isn't one.
    func original(of index: Int) -> Int? {
        var random = SeededRandom(seed: seed, stream: UInt64(index))
        guard index > 0, random.chance(share) else { return nil }
        var original = random.int(below: index)
        while let earlier = self.original(of: original) {
            original = earlier
        }
        return original
    }

    /// Photos that are copies, and photos copied.
    var copies: Int {
        (0 ..< photos).count { original(of: $0) != nil }
    }

    var originals: Int {
        Set((0 ..< photos).compactMap(original(of:))).count
    }

    /// Photo `index`'s file: its content key's bytes 0 to 7 and 8 to 15, and its size.
    func content(of index: Int) -> (high: UInt64, low: UInt64, size: Int64) {
        var content = SeededRandom(seed: ~seed, stream: UInt64(original(of: index) ?? index))
        let high = content.next()
        return (high, content.next(), 1_000_000 + Int64(high % 60_000_000))
    }

    /// Every photo, by ID from 1, with its file's content key and size.
    func grouper() -> DuplicateGrouper {
        var grouper = DuplicateGrouper(capacity: photos)
        for index in 0 ..< photos {
            let (high, low, size) = content(of: index)
            grouper.add(photo: Int64(index + 1), high: high, low: low, size: size)
        }
        return grouper
    }
}

import Foundation
import RedlampDocument
import Synchronization

public extension BenchScenarios {
    /// Adds the import scenario (LIB-27) after the others: `photos` photos from a simulated card, with
    /// a raw of each kind in `rawFolder` among them when it's given.
    static func registerImport(photos: Int = ImportScenario.defaultPhotos, rawFolder: URL? = nil) {
        register(ImportScenario(photos: photos, rawFolder: rawFolder))
    }
}

/// Imports a simulated card (LIB-27): `photos` photos in `DCIM/100CANON` of a temporary folder, read
/// through a card reader's profile (about 90 MB a second, one request at a time), to a destination and
/// a backup on the Mac's own disk, with an index. The photos are camera JPEGs of about 300 KB, taken a
/// second apart over two days, a raw of each kind cloned from `rawFolder` among them beside its JPEG.
/// It measures how soon the first 100 previews are in the store while nothing is copied, and the last;
/// then the megabytes a second read from the card, copied to both destinations and verified, the card
/// doing nothing else; and a second run of the same card, every photo of which must be recognised as
/// imported and skipped. Nothing is read from the fixture, so its volume doesn't matter, and the folder
/// is removed at the end.
public struct ImportScenario: BenchScenario {
    public static let defaultPhotos = 2000
    /// Previews browsing makes before the card counts as browsable.
    static let firstPreviews = 100

    public let name = "import"
    public let photos: Int
    public let rawFolder: URL?

    public init(photos: Int = ImportScenario.defaultPhotos, rawFolder: URL? = nil) {
        self.photos = max(photos, 1)
        self.rawFolder = rawFolder
    }

    public func run(_: BenchContext) async throws -> [BenchResult] {
        try await measure()
    }

    public func measure(in parent: URL? = nil) async throws -> [BenchResult] {
        let place = parent ?? rawFolder.flatMap { raws in
            try? FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: raws, create: true,
            )
        } ?? FileManager.default.temporaryDirectory
        let folder = place.appending(path: "redlamp-import-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let card = folder.appending(path: "EOS_DIGITAL", directoryHint: .isDirectory)
        let shots = SimulatedCard.shots(photos, raws: rawFolder.map(SimulatedCard.raws(in:)) ?? [])
        try await LibraryIndex.offCaller { try SimulatedCard.write(shots, to: card) }
        let paths = LibraryPaths(root: folder.appending(path: "Library", directoryHint: .isDirectory))
        let index = try await LibraryIndex.open(at: paths.index)
        defer { index.closeAndWait() }
        let store = PhotoStore(root: paths.store)
        defer { store.close() }
        let indexer = LibraryIndexer(index: index, thumbnails: StoreThumbnailMaker(store: store).thumbnails)
        // Copied without the indexer, which is timed on its own after.
        let library = ImportLibrary(paths: paths, index: index, store: store)
        let settings = ImportSettings(
            destination: folder.appending(path: "Pictures", directoryHint: .isDirectory),
            backup: folder.appending(path: "Backup", directoryHint: .isDirectory),
        )

        // First run: browse, timing the first previews and the last, then plan and copy, the card idle.
        let simulated = SimulatedFileSystem(profile: .cardReader)
        simulated.mount(card, uuid: "BENCH-CARD", name: "EOS_DIGITAL")
        let source = try ImportSource.at(card, fileSystem: simulated, medium: .card(at: card))
        let session = ImportSession(sources: [source], library: library, fileSystem: simulated)
        let clock = ContinuousClock()
        let started = clock.now
        let first = Moment()
        let wanted = min(Self.firstPreviews, shots.count)
        let events = session.browse()
        let browsing = Task {
            var made = 0
            for await event in events {
                if case let .previewed(ids) = event {
                    made += ids.count
                    if made >= wanted {
                        first.reach(clock.now - started)
                    }
                }
            }
            first.reach(clock.now - started)
            return made
        }
        let previewed = await browsing.value
        let browsed = clock.now - started
        let firstPreviews = first.time
        let planning = clock.now
        let plan = try await session.plan(settings)
        let planned = clock.now - planning
        let copying = clock.now
        let outcome = try await session.importer().run(plan)
        let copied = clock.now - copying
        let indexing = clock.now
        var indexed = 0
        for await event in indexer.index([settings.destination]) {
            if case let .photosInserted(ids) = event {
                indexed += ids.count
            }
        }
        let indexTime = clock.now - indexing

        // Second run: a new session on the same card finds every photo in the library.
        let again = SimulatedFileSystem(profile: .cardReader)
        again.mount(card, uuid: "BENCH-CARD", name: "EOS_DIGITAL")
        let second = try ImportSession(
            sources: [ImportSource.at(card, fileSystem: again, medium: .card(at: card))], library: library,
            fileSystem: again,
        )
        let recognising = clock.now
        for await _ in second.browse() {}
        let replan = try await second.plan(settings)
        let recognised = clock.now - recognising
        let skipped = replan.left(.imported) + replan.left(.atDestination)

        let seconds = max(copied.seconds, 1e-9)
        let files = shots.count
        let label = BenchResult.grouped(plan.items.count)
        return [
            BenchResult(
                scenario: name, id: "library-import-first-previews",
                name: "The first \(Self.firstPreviews) previews in the store, from the card's listing on",
                value: (firstPreviews ?? .zero).seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-import-browse",
                name: "Every photo read and previewed, \(BenchResult.grouped(previewed)) previews made",
                value: browsed.seconds, unit: "s",
            ),
            BenchResult(
                scenario: name, id: "library-import-previews", name: "Photos previewed while browsing",
                value: Double(previewed), unit: "photos", budget: .exactly(Double(plan.items.count), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-import-plan",
                name: "\(label) photos planned: folders, names and both destinations listed",
                value: planned.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-import-copy",
                name: "\(label) photos, \(BenchResult.grouped(plan.files)) files, copied to the destination and the "
                    + "backup and verified",
                value: copied.seconds, unit: "s",
            ),
            BenchResult(
                scenario: name, id: "library-import-rate",
                name: "Read from the card, copied twice and verified, a second",
                value: Double(outcome.bytes) / 1_000_000 / seconds, unit: "MB/s",
            ),
            BenchResult(
                scenario: name, id: "library-import-verified", name: "Photos verified at both destinations",
                value: Double(outcome.verified), unit: "photos", budget: .exactly(Double(plan.items.count), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-import-safe", name: "The card safe to erase",
                value: outcome.isSafeToErase ? 1 : 0, unit: "cards", budget: .exactly(1, "cards"),
            ),
            BenchResult(
                scenario: name, id: "library-import-index", name: "The destination indexed after",
                value: indexTime.seconds, unit: "s",
            ),
            BenchResult(
                scenario: name, id: "library-import-indexed", name: "Photos the index added",
                value: Double(indexed), unit: "photos", budget: .exactly(
                    Double(plan.files { $0.role == .photo }),
                    "photos",
                ),
            ),
            BenchResult(
                scenario: name, id: "library-import-again",
                name: "The same card again: every photo recognised as imported", value: recognised.seconds * 1000,
                unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-import-again-skipped", name: "Photo files skipped on the second run",
                value: Double(skipped), unit: "files", budget: .exactly(Double(files), "files"),
            ),
            BenchResult(
                scenario: name, id: "library-import-again-copied", name: "Photos left to copy on the second run",
                value: Double(replan.items.count), unit: "photos", budget: .exactly(0, "photos"),
            ),
        ]
    }
}

/// When something first happened, from any task.
private final class Moment: Sendable {
    private let value = Mutex<Duration?>(nil)

    var time: Duration? {
        value.withLock { $0 }
    }

    func reach(_ time: Duration) {
        value.withLock { $0 = $0 ?? time }
    }
}

extension ImportPlan {
    /// The files the plan copies that `include` takes.
    func files(_ include: (Copy) -> Bool) -> Int {
        items.reduce(0) { $0 + $1.copies.count(where: include) }
    }
}

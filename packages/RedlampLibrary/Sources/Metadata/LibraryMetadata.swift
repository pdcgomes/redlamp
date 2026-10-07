import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

/// Changes to many photos' metadata at once, each a batch with Undo (LIB-15, LIB-22, LIB-23, LIB-28):
/// ratings, flags, labels, custom labels and marks for culling; IPTC Core's fields, set or from presets;
/// collections; and manual stacks. Keywords have their own (`LibraryKeywords`), kept the same way.
///
/// - **Each photo's fields are in its sidecar.** A change writes the definitions first
///   (`Collections.json`), then the index and open lists (`live` hears of each write), then the
///   sidecars, in batches off the caller (`SidecarStore.change`), so the photos show their change
///   before their files are written.
/// - **The journal** (`MetadataJournal`) holds each batch, written and synced before anything changes,
///   and logs each sidecar as it's written: a forced quit leaves a batch `recover` finishes or rolls
///   back at the next launch, and Undo takes back what was written, keeping what changed since.
/// - **Sidecars this build can't write** (a newer Redlamp's, or one it can't read) are left as they
///   are, and their photos keep their fields in the index as they were.
///
/// One batch runs at a time.
public final class LibraryMetadata: Sendable {
    public let index: LibraryIndex
    public let paths: LibraryPaths
    public let live: LibraryLive?
    public let journal: MetadataJournal
    /// Photos a transaction of the index changes.
    static let photosPerWrite = 1000
    private let serial = Mutex<Task<Void, Never>?>(nil)
    /// Sidecars written before the run stops as a killed process would, for the tests and the benchmark.
    let interruption = Mutex<Int?>(nil)

    /// `paths` defaults to the library whose index is `index`, at `LibraryPaths.index` in its folder.
    public init(index: LibraryIndex, paths: LibraryPaths? = nil, live: LibraryLive? = nil) {
        self.index = index
        self.paths = paths ?? LibraryPaths(root: index.url.deletingLastPathComponent())
        self.live = live
        journal = MetadataJournal(paths: self.paths)
    }

    struct ForcedQuit: Error {}

    /// The collections of the same library, whose changes go in this journal.
    public var collections: LibraryCollections {
        LibraryCollections(metadata: self)
    }

    // MARK: - Running

    /// Makes `change` as one batch; see `plan` and `run`.
    @discardableResult
    public func apply(_ change: MetadataChange) async throws -> MetadataOutcome {
        try await run(plan(change))
    }

    /// Writes `plan`'s batch to the journal and runs it: the definitions, then the index, then the
    /// sidecars, `progress` hearing how many of those are done. A batch that fails partway is rolled
    /// back before the error is thrown. Throws `MetadataError.unfinished` while a batch a forced quit
    /// interrupted waits for `recover`.
    @discardableResult
    public func run(
        _ plan: MetadataPlan, progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil,
    ) async throws -> MetadataOutcome {
        try await serially { [self] in
            if let unfinished = try await unfinishedEntries().first {
                throw MetadataError.unfinished(unfinished.id)
            }
            let batch = plan.batch
            guard !plan.isEmpty else {
                return MetadataOutcome(batch: batch.id, title: batch.title, state: .finished)
            }
            let clock = ContinuousClock()
            let started = clock.now
            let journal = journal
            try await LibraryIndex.offCaller {
                journal.prune()
                try journal.write(batch)
            }
            var outcome = MetadataOutcome(batch: batch.id, title: batch.title, state: .running)
            outcome.journalTime = clock.now - started
            do {
                return try await forward(
                    batch,
                    progress: MetadataJournal.Progress(),
                    outcome: outcome,
                    report: progress,
                )
            } catch is ForcedQuit {
                throw ForcedQuit()
            } catch {
                let logged = try await LibraryIndex.offCaller { try journal.load(batch.id).progress }
                try await rollBack(batch, logged: logged)
                throw error
            }
        }
    }

    /// Runs `batch` on from what `logged` says is done: the definitions and the index (again, which
    /// changes nothing they hold already), then the sidecars not yet written.
    func forward(
        _ batch: MetadataBatch, progress logged: MetadataJournal.Progress, outcome: MetadataOutcome,
        report: (@Sendable (Int, Int) -> Void)?,
    ) async throws -> MetadataOutcome {
        var outcome = outcome
        let clock = ContinuousClock()
        let log = try journal.log(batch.id)
        var started = clock.now
        if let change = batch.definitions {
            try await collections.updateDefinitions { change.applied(to: $0) }
        }
        let changed = try await writeIndex(batch)
        outcome.photos = changed.count
        outcome.indexTime = clock.now - started
        try await LibraryIndex.offCaller { try log.state(.running) }

        started = clock.now
        let pending = batch.photos.indices.filter { logged.written[$0] == nil && logged.skipped[$0] == nil }
        let written = try await writeSidecars(batch, pending, log: log, report: report)
        outcome.written = written.written
        outcome.skipped = written.skipped.keys.sorted()
        outcome.reasons = written.skipped
        outcome.sidecarTime = clock.now - started
        try await LibraryIndex.offCaller { try log.state(.finished) }
        if let original = batch.undoes {
            try await LibraryIndex.offCaller { [journal] in try journal.log(original).state(.undone) }
        }
        outcome.state = .finished
        return outcome
    }

    /// Gives each photo of `batch` its fields in the index, a transaction at a time, and tells `live`;
    /// returns the photos whose fields changed.
    private func writeIndex(_ batch: MetadataBatch) async throws -> [Int64] {
        var changed: [Int64] = []
        let photos = batch.photos
        for start in stride(from: 0, to: photos.count, by: Self.photosPerWrite) {
            let chunk = Array(photos[start ..< min(start + Self.photosPerWrite, photos.count)])
            let ids = try await index.write { writer -> [Int64] in
                let current = try writer.metadataValues(
                    ofPhotos: chunk.map(\.id),
                    keys: chunk.reduce(into: Set<String>()) { $0.formUnion(batch.keys(of: $1)) },
                )
                var ids: [Int64] = []
                for photo in chunk {
                    guard let shown = current[photo.id] else { continue }
                    let now = shown.values.filter { batch.keys(of: photo).contains($0.key) }
                    let after = batch.indexAfter(photo, current: PhotoMetadata.canonical(now))
                    if after != PhotoMetadata.canonical(now) || !shown.others.isDisjoint(with: Self.fields(after)) {
                        try writer.setMetadata(after, forPhoto: photo.id, others: batch.others(photo, after: after))
                        ids.append(photo.id)
                    }
                }
                return ids
            }
            changed += ids
            live?.photosChanged(ids)
        }
        var left = Set<String>()
        for photo in photos where batch.keys(of: photo).contains("collections") {
            left.formUnion(photo.index["collections"]?.items ?? [])
            left.formUnion(photo.undo?.indexAfter["collections"]?.items ?? [])
        }
        if !left.isEmpty {
            let within = left.compactMap(CollectionPath.init)
            try await index.write { try $0.removeUnusedCollections(within: within) }
        }
        return changed
    }

    /// The fields other apps share among `values`' keys.
    static func fields(_ values: MetadataValues) -> Set<XMPField> {
        Set(values.keys.compactMap(PhotoMetadata.xmpField))
    }

    /// Writes the sidecars of photos `pending` (places in `batch`) in batches off the caller, logging
    /// each; then records their dates in the index, so the indexer doesn't read them again, and puts
    /// back the index's fields of photos whose sidecars couldn't be written. Returns how many it wrote,
    /// and why it couldn't write the others, by path.
    private func writeSidecars(
        _ batch: MetadataBatch, _ pending: [Int], log: MetadataJournal.Log, report: (@Sendable (Int, Int) -> Void)?,
    ) async throws -> (written: Int, skipped: [String: String]) {
        guard !pending.isEmpty else { return (0, [:]) }
        let store = try await SidecarStore(locator: LibrarySidecars(index: index, paths: paths).locator())
        let stop = interruption.withLock { $0 }
        let done = SidecarCounter()
        var written = 0
        var skipped: [String: String] = [:]
        for start in stride(from: 0, to: pending.count, by: Self.photosPerWrite) {
            let places = Array(pending[start ..< min(start + Self.photosPerWrite, pending.count)])
            let ids = places.map { batch.photos[$0].id }
            let found = try await index.read { try $0.photoPaths(ids) }
            let results = try await LibraryIndex.offCaller {
                try Self.write(places, of: batch, store: store, paths: found, log: log, stop: stop, done: done) {
                    report?($0, pending.count)
                }
            }
            var dates: [(Int64, Date?)] = []
            var restored: [(Int64, MetadataValues, Set<XMPField>)] = []
            for result in results {
                switch result.outcome {
                case let .written(date):
                    written += 1
                    dates.append((result.photo, date))
                case .kept:
                    written += 1
                case let .skipped(path, reason, values, others):
                    skipped[path] = reason
                    restored.append((result.photo, values, others))
                case .gone:
                    break
                }
            }
            let (stamped, putBack) = (dates, restored)
            try await index.write { writer in
                for (photo, date) in stamped {
                    try writer.setSidecarModified(date, forPhoto: photo)
                }
                for (photo, values, others) in putBack {
                    try writer.setMetadata(values, forPhoto: photo, others: others)
                }
            }
            live?.photosChanged(putBack.map(\.0))
            if let stop, done.value >= stop {
                throw ForcedQuit()
            }
        }
        return (written, skipped)
    }

    struct SidecarResult: Sendable {
        enum Outcome: Sendable {
            /// Written, and the sidecar's date.
            case written(Date?)
            /// Already as the batch leaves it, so nothing was written and the date the index has for it
            /// stands.
            case kept
            /// This build can't write it: the photo's path, why, and the fields the index shows then, with
            /// those of them that are other apps'.
            case skipped(String, String, MetadataValues, Set<XMPField>)
            /// The photo isn't in the library any more.
            case gone
        }

        let photo: Int64
        let outcome: Outcome
    }

    /// Writes the sidecars of `places` as a batch (`SidecarStore.change`), each logged once it's
    /// written; a sidecar this build can't write is left as it is. Throws only when the log can't be
    /// written, once the sidecars under way are done.
    private static func write(
        _ places: [Int], of batch: MetadataBatch, store: SidecarStore, paths: [Int64: String],
        log: MetadataJournal.Log, stop: Int?, done: SidecarCounter, report: @Sendable (Int) -> Void,
    ) throws -> [SidecarResult] {
        let gone = places.filter { paths[batch.photos[$0].id] == nil }
        let results = Mutex(gone.map { SidecarResult(photo: batch.photos[$0].id, outcome: .gone) })
        let failure = Mutex<(any Error)?>(nil)
        let present = places.compactMap { place in paths[batch.photos[place].id].map { (place: place, path: $0) } }
        store.change(present.map { URL(fileURLWithPath: $0.path) }, until: {
            failure.withLock { $0 != nil } || stop.map { done.value >= $0 } ?? false
        }) { number, sidecar in
            let photo = batch.photos[present[number].place]
            var sidecar = sidecar ?? Sidecar(recipe: EditRecipe())
            let metadata = sidecar.metadata ?? PhotoMetadata()
            let keys = batch.keys(of: photo)
            let before = PhotoMetadata.canonical(metadata.values(keys))
            let after = batch.sidecarAfter(photo, current: before, fallback: photo.index)
            guard after != before, let changed = metadata.setting(after) else { return .keep }
            sidecar.metadata = changed.isEmpty ? nil : changed
            sidecar.modified = Date()
            return .saveOrRemove(sidecar)
        } done: { result in
            let (place, path) = present[result.index]
            let photo = batch.photos[place]
            do {
                let outcome = try logged(result, photo, place: place, of: batch, at: path, store: store, log: log)
                results.withLock { $0.append(SidecarResult(photo: photo.id, outcome: outcome)) }
                report(done.add())
            } catch {
                failure.withLock { $0 = $0 ?? error }
            }
        }
        if let error = failure.withLock({ $0 }) {
            throw error
        }
        return results.withLock { $0 }
    }

    /// Logs what the batch did with one photo's sidecar: written as the batch leaves it, keeping
    /// everything else in it, or left as it is.
    private static func logged(
        _ result: SidecarBatchResult, _ photo: MetadataBatch.Photo, place: Int, of batch: MetadataBatch,
        at path: String, store: SidecarStore, log: MetadataJournal.Log,
    ) throws -> SidecarResult.Outcome {
        let keys = batch.keys(of: photo)
        let before = PhotoMetadata.canonical((result.sidecar?.metadata ?? PhotoMetadata()).values(keys))
        let after = batch.sidecarAfter(photo, current: before, fallback: photo.index)
        switch result.outcome {
        case .kept:
            try log.written(place, before: before, after: after)
            return .kept
        case .saved:
            try log.written(place, before: before, after: after)
            let date = try? LocalFileSystem().attributes(of: store.locator.readURL(for: result.image)).modified
            return .written(date)
        case let .failed(error):
            let reason = LibraryKeywords.describe(error)
            try log.skipped(place, reason)
            return .skipped(path, reason, photo.index, photo.others)
        }
    }

    // MARK: - Planning

    /// The photos of `ids` whose fields in the index `edit` changes, or which show other apps' values of
    /// fields it sets, with what the index shows of them.
    func photos(_ ids: [Int64], edit: [String: FieldEdit]) async throws -> [MetadataBatch.Photo] {
        try await photos(ids, edits: [:], edit: edit, keepingUnchanged: false)
    }

    /// `photos(_:edit:)`, a photo of `edits` getting its own edit in place of `edit`; with `keepingUnchanged`,
    /// those whose rows already show what they're given too.
    func photos(
        _ ids: [Int64], edits: [Int64: [String: FieldEdit]], edit: [String: FieldEdit], keepingUnchanged: Bool,
    ) async throws -> [MetadataBatch.Photo] {
        let ids = Array(Set(ids)).sorted()
        let keys = edits.values.reduce(edit.touched) { $0.union($1.touched) }
        return try await index.read { reader in
            let shown = try reader.metadataValues(ofPhotos: ids, keys: keys)
            let paths = try reader.photoPaths(ids)
            return ids.compactMap { id -> MetadataBatch.Photo? in
                guard let shown = shown[id], let path = paths[id] else { return nil }
                let own = edits[id]
                let touched = (own ?? edit).touched
                let current = PhotoMetadata.canonical(shown.values.filter { touched.contains($0.key) })
                let after = PhotoMetadata.canonical((own ?? edit).applied(to: current, fallback: current))
                let others = shown.others.intersection(Self.fields(after))
                guard after != current || !others.isEmpty || keepingUnchanged else { return nil }
                return MetadataBatch.Photo(id: id, path: path, index: current, others: others, edits: own)
            }
        }
    }

    // MARK: - Custom labels

    /// The custom labels the library's photos have, each with how many photos have it, by name: for the
    /// menus, the palette and completion.
    public func customLabels() async throws -> [CustomLabelCount] {
        try await index.read { try $0.customLabelCounts() }
    }

    // MARK: - Helpers

    /// Runs `body` after the batches asked for before it.
    func serially<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = serial.withLock { last -> Task<T, any Error> in
            let previous = last
            let task = Task {
                await previous?.value
                return try await body()
            }
            last = Task { _ = try? await task.value }
            return task
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// `12 photos`, `a photo`.
    static func count(_ photos: Int) -> String {
        photos == 1 ? "a photo" : "\(photos.formatted(.number.locale(Locale(identifier: "en_US")))) photos"
    }
}

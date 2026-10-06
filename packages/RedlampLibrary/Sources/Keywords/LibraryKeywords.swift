import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

/// A change to the library's keywords (LIB-21), each made as one batch with Undo.
public enum KeywordChange: Sendable, Hashable {
    /// Puts the keywords on the photos that lack them.
    case add([KeywordPath], to: [Int64])
    /// Takes the keywords, not those inside them, off the photos. A keyword no photo has any more stays
    /// in the list, as Lightroom keeps it.
    case remove([KeywordPath], from: [Int64])
    /// Renames or moves a keyword with everything inside it: its photos, its options and its places in
    /// the keyword sets follow. Onto a keyword that's there already, it merges with it.
    case rename(KeywordPath, to: KeywordPath)
    /// Merges keywords into one in a step: their photos get `into` instead, the keywords inside them go
    /// inside it, and their synonyms join its.
    case merge([KeywordPath], into: KeywordPath)
    /// Takes the keywords and everything inside them off every photo and out of the list.
    case delete([KeywordPath])
    /// Keeps the keyword in the list with these options, photos or none; nil leaves it to its photos.
    case define(KeywordPath, KeywordOptions?)
    /// The keyword sets the user keeps (nil for Redlamp's), and the one ⌥1 to ⌥9 apply.
    case sets([KeywordSet]?, active: String?)
    /// Keywords read from a keyword-list file: each kept in the list, with the file's synonyms
    /// added to its own and the file's say on whether it's exported.
    case importList([LightroomKeywordFile.Keyword])
    /// Drops the keywords no photo has, nor any keyword inside them, from the list.
    case purgeUnused
}

/// What running a batch did.
public struct KeywordOutcome: Sendable, Hashable {
    public var batch: UUID
    public var title: String
    public var state: KeywordJournal.State
    /// Photos whose keywords changed in the index.
    public var photos = 0
    /// Sidecars written.
    public var written = 0
    /// Photos whose sidecars this build can't write, left as they were, by path.
    public var skipped: [String] = []
    /// How long the journal, the definitions and index, and the sidecars took.
    public var journalTime = Duration.zero
    public var indexTime = Duration.zero
    public var sidecarTime = Duration.zero
    /// For a batch a forced quit interrupted: how many of its sidecars were written before it.
    public var recoveredFrom: Int?
}

/// The library's keywords (LIB-21): the keyword list from the index and the definitions
/// (`KeywordDefinitions`), and every change to them made as a batch with Undo.
///
/// - **Each photo's keywords are in its sidecar** as full paths. A change writes the definitions
///   first, then the index and open lists (`live` hears of each write), then the sidecars, in
///   batches off the caller (`SidecarStore.change`), so the photos show their keywords before their
///   files are written.
/// - **The journal** (`KeywordJournal`) holds each batch, written and synced before anything changes,
///   and logs each sidecar as it's written: a forced quit leaves a batch `recover` finishes or rolls
///   back at the next launch, and Undo takes back what was written, keeping what changed since.
/// - **Sidecars this build can't write** (a newer Redlamp's, or one it can't read) are left as they
///   are, and their photos keep their keywords in the index as well.
///
/// One batch runs at a time.
public final class LibraryKeywords: Sendable {
    public let index: LibraryIndex
    public let paths: LibraryPaths
    public let live: LibraryLive?
    public let journal: KeywordJournal
    /// The index setting holding Recent Keywords.
    static let recentKey = "keywords.recent"
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
        journal = KeywordJournal(paths: self.paths)
    }

    struct ForcedQuit: Error {}

    // MARK: - Reading

    /// `Keywords.json` in the library's definitions.
    public var definitionsURL: URL {
        KeywordDefinitions.url(in: paths)
    }

    public func definitions() async throws -> KeywordDefinitions {
        let url = definitionsURL
        return try await LibraryIndex.offCaller { try KeywordDefinitions.load(from: url) }
    }

    /// The keyword list as the index and the definitions have it now.
    public func list() async throws -> KeywordList {
        let definitions = try await definitions()
        let counts = try await index.read { try $0.keywordCounts() }
        return KeywordList(counts: counts, definitions: definitions)
    }

    /// The photo's keywords, as the index has them.
    public func keywords(ofPhoto id: Int64) async throws -> [KeywordPath] {
        try await index.read { try $0.keywords(forPhoto: id).compactMap(KeywordPath.init) }
    }

    /// The keyword sets: Recent Keywords, then the user's (or Redlamp's, until there are any).
    public func sets() async throws -> [KeywordSet] {
        let recent = try await index.read { try $0.recentKeywords() }
        return try await [KeywordSet.recent(recent)] + definitions().keywordSets
    }

    /// The set ⌥1 to ⌥9 apply now.
    public func activeSet() async throws -> KeywordSet {
        let sets = try await sets()
        let active = try await definitions().activeSet
        return sets.first { $0.name == active } ?? sets[0]
    }

    /// Completion over the keyword list as it is now.
    public func completion() async throws -> KeywordCompletion {
        try await KeywordCompletion(list())
    }

    // MARK: - Changes

    /// Makes `change` as one batch; see `plan` and `run`.
    @discardableResult
    public func apply(_ change: KeywordChange) async throws -> KeywordOutcome {
        try await run(plan(change))
    }

    /// What `change` would do, worked out from the index and the definitions as they are; nothing is
    /// written.
    public func plan(_ change: KeywordChange) async throws -> KeywordPlan {
        let old = try await definitions()
        var new = old
        var batch: KeywordBatch
        switch change {
        case let .add(keywords, ids):
            let keywords = KeywordPath.paths(keywords.map(\.text))
            batch = KeywordBatch(kind: .add, title: Self.title("Add", keywords, ids.count))
            batch.edit.adding = keywords
            batch.photos = try await photos(ids, touchedBy: batch.edit)
        case let .remove(keywords, ids):
            batch = KeywordBatch(kind: .remove, title: Self.title("Remove", keywords, ids.count, from: true))
            batch.edit.removing = keywords
            batch.photos = try await photos(ids, touchedBy: batch.edit)
            try await keepInList(keywords, losing: batch, in: &new)
        case let .rename(from, to):
            guard from != to else { return KeywordPlan(batch: KeywordBatch(kind: .rename, title: "Rename")) }
            guard !to.isWithin(from) else { throw KeywordError.insideItself(from) }
            let verb = from.parent == to.parent ? "Rename" : "Move"
            batch = KeywordBatch(kind: .rename, title: "\(verb) “\(from.displayName)” to “\(to.displayName)”")
            batch.edit.replacing = [.init(from: from, to: to)]
            batch.photos = try await photos(within: [from], touchedBy: batch.edit)
            new.move([from], to: to)
            try await requireKeywords([from], found: !batch.photos.isEmpty, in: old)
        case let .merge(sources, target):
            let sources = sources.filter { $0 != target }
            if let outer = sources.first(where: { target.isWithin($0) }) {
                throw KeywordError.insideItself(outer)
            }
            batch = KeywordBatch(
                kind: .merge,
                title: "Merge \(sources.count == 1 ? "“\(sources[0].displayName)”" : "\(sources.count) keywords") into “\(target.displayName)”",
            )
            batch.edit.replacing = sources.map { .init(from: $0, to: target) }
            batch.photos = try await photos(within: sources, touchedBy: batch.edit)
            new.move(sources, to: target)
            try await requireKeywords(sources, found: !batch.photos.isEmpty, in: old)
        case let .delete(keywords):
            batch = KeywordBatch(kind: .delete, title: Self.title("Delete", keywords, nil))
            batch.edit.replacing = keywords.map { .init(from: $0, to: nil) }
            batch.photos = try await photos(within: keywords, touchedBy: batch.edit)
            new.remove(keywords)
        case let .define(keyword, options):
            batch = KeywordBatch(
                kind: .define,
                title: options == nil ? "Forget “\(keyword.displayName)”" : "Edit “\(keyword.displayName)”",
            )
            new.keywords[keyword] = options
        case let .sets(sets, active):
            batch = KeywordBatch(kind: .define, title: "Edit Keyword Sets")
            new.sets = sets
            new.activeSet = active
        case let .importList(keywords):
            batch = KeywordBatch(kind: .define, title: "Import \(keywords.count) keywords")
            for keyword in keywords {
                var options = new.keywords[keyword.path] ?? KeywordOptions()
                options.synonyms = KeywordOptions.tidied(options.synonyms + keyword.synonyms)
                options.includeOnExport = keyword.includeOnExport
                new.keywords[keyword.path] = options
            }
        case .purgeUnused:
            batch = KeywordBatch(kind: .define, title: "Purge Unused Keywords")
            let list = try await list()
            for path in old.keywords.keys where (list[path]?.count ?? 0) == 0 {
                new.keywords[path] = nil
            }
        }
        let definitions = DefinitionsChange(from: old, to: new)
        batch.definitions = definitions.isEmpty ? nil : definitions
        return KeywordPlan(batch: batch)
    }

    /// Writes `plan`'s batch to the journal and runs it: the definitions, then the index, then the
    /// sidecars, `progress` hearing how many of those are done. A batch that fails partway is rolled
    /// back before the error is thrown. Throws `KeywordError.unfinished` while a batch a forced quit
    /// interrupted waits for `recover`.
    @discardableResult
    public func run(
        _ plan: KeywordPlan, progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil,
    ) async throws -> KeywordOutcome {
        try await serially { [self] in
            if let unfinished = try await unfinishedEntries().first {
                throw KeywordError.unfinished(unfinished.id)
            }
            let batch = plan.batch
            guard !plan.isEmpty else {
                return KeywordOutcome(batch: batch.id, title: batch.title, state: .finished)
            }
            let clock = ContinuousClock()
            let started = clock.now
            let journal = journal
            try await LibraryIndex.offCaller {
                journal.prune()
                try journal.write(batch)
            }
            var outcome = KeywordOutcome(batch: batch.id, title: batch.title, state: .running)
            outcome.journalTime = clock.now - started
            do {
                return try await forward(batch, progress: KeywordJournal.Progress(), outcome: outcome, report: progress)
            } catch is ForcedQuit {
                throw ForcedQuit()
            } catch {
                let logged = try await LibraryIndex.offCaller { try journal.load(batch.id).progress }
                try await rollBack(batch, logged: logged)
                throw error
            }
        }
    }

    // MARK: - Running

    /// Runs `batch` on from what `logged` says is done: the definitions and the index (again, which
    /// changes nothing they hold already), then the sidecars not yet written.
    func forward(
        _ batch: KeywordBatch, progress logged: KeywordJournal.Progress, outcome: KeywordOutcome,
        report: (@Sendable (Int, Int) -> Void)?,
    ) async throws -> KeywordOutcome {
        var outcome = outcome
        let clock = ContinuousClock()
        let log = try journal.log(batch.id)
        var started = clock.now
        if let change = batch.definitions {
            try await updateDefinitions { change.applied(to: $0) }
        }
        let changed = try await writeIndex(batch)
        outcome.photos = changed.count
        outcome.indexTime = clock.now - started
        try await LibraryIndex.offCaller { try log.state(.running) }

        started = clock.now
        let pending = batch.photos.indices.filter { logged.written[$0] == nil && logged.skipped[$0] == nil }
        let written = try await writeSidecars(batch, pending, log: log, report: report)
        outcome.written = written.written
        outcome.skipped = written.skipped
        outcome.sidecarTime = clock.now - started
        try await LibraryIndex.offCaller { try log.state(.finished) }
        if let original = batch.undoes {
            try await LibraryIndex.offCaller { [journal] in try journal.log(original).state(.undone) }
        }
        outcome.state = .finished
        return outcome
    }

    /// Gives each photo of `batch` its keywords in the index, a transaction at a time, and tells `live`;
    /// returns the photos whose keywords changed.
    private func writeIndex(_ batch: KeywordBatch) async throws -> [Int64] {
        var changed: [Int64] = []
        let photos = batch.photos
        var first = true
        for start in stride(from: 0, to: max(photos.count, 1), by: Self.photosPerWrite) {
            let chunk = Array(photos[start ..< min(start + Self.photosPerWrite, photos.count)])
            let recent = first && batch.kind == .add ? batch.edit.adding : []
            first = false
            let ids = try await index.write { writer -> [Int64] in
                var ids: [Int64] = []
                for photo in chunk {
                    guard try writer.photo(id: photo.id) != nil else { continue }
                    let current = try writer.keywords(forPhoto: photo.id).compactMap(KeywordPath.init)
                    let after = batch.indexAfter(photo, current: current)
                    if Set(after) != Set(current) {
                        try writer.setKeywords(after.map(\.text), forPhoto: photo.id)
                        ids.append(photo.id)
                    }
                }
                try writer.recordRecent(recent)
                return ids
            }
            changed += ids
            live?.photosChanged(ids)
        }
        let cleared = batch.edit.replacing.map(\.from) + batch.edit.removing
            + batch.photos.compactMap(\.undo).flatMap { Array(Set($0.indexAfter).subtracting($0.indexBefore)) }
        if !cleared.isEmpty {
            try await index.write { try $0.removeUnusedKeywords(within: cleared) }
        }
        return changed
    }

    /// Writes the sidecars of photos `pending` (places in `batch`) in batches off the caller, logging
    /// each; then records their dates in the index, so the indexer doesn't read them again, and puts
    /// back the index's keywords of photos whose sidecars held others or couldn't be written.
    private func writeSidecars(
        _ batch: KeywordBatch, _ pending: [Int], log: KeywordJournal.Log, report: (@Sendable (Int, Int) -> Void)?,
    ) async throws -> (written: Int, skipped: [String]) {
        guard !pending.isEmpty else { return (0, []) }
        let store = try await SidecarStore(locator: LibrarySidecars(index: index, paths: paths).locator())
        let stop = interruption.withLock { $0 }
        let done = SidecarCounter()
        var written = 0
        var skipped: [String] = []
        for start in stride(from: 0, to: pending.count, by: Self.photosPerWrite) {
            let places = Array(pending[start ..< min(start + Self.photosPerWrite, pending.count)])
            let ids = places.map { batch.photos[$0].id }
            let found = try await index.read { reader in
                try (reader.photoPaths(ids), reader.keywordPaths(ofPhotos: ids))
            }
            let results = try await LibraryIndex.offCaller {
                try Self.write(places, of: batch, store: store, paths: found.0, log: log, stop: stop, done: done) {
                    report?($0, pending.count)
                }
            }
            var corrections: [Int64: [KeywordPath]] = [:]
            var dates: [(Int64, Date?)] = []
            for result in results {
                switch result.outcome {
                case let .written(keywords, date):
                    written += 1
                    dates.append((result.photo, date))
                    if let keywords, found.1[result.photo].map({ Set($0) != Set(keywords) }) ?? false {
                        corrections[result.photo] = keywords
                    }
                case let .kept(keywords):
                    written += 1
                    if let keywords, found.1[result.photo].map({ Set($0) != Set(keywords) }) ?? false {
                        corrections[result.photo] = keywords
                    }
                case let .skipped(path, keywords):
                    skipped.append(path)
                    if found.1[result.photo].map({ Set($0) != Set(keywords) }) ?? false {
                        corrections[result.photo] = keywords
                    }
                case .gone:
                    break
                }
            }
            let (stamped, corrected) = (dates, corrections)
            try await index.write { writer in
                for (photo, date) in stamped {
                    try writer.setSidecarModified(date, forPhoto: photo)
                }
                try writer.setKeywords(corrected)
            }
            live?.photosChanged(Array(corrected.keys))
            if let stop, done.value >= stop {
                throw ForcedQuit()
            }
        }
        return (written, skipped.sorted())
    }

    struct SidecarResult: Sendable {
        enum Outcome: Sendable {
            /// Written: the keywords it holds now (nil when it holds none) and the sidecar's date.
            case written([KeywordPath]?, Date?)
            /// Already as the batch leaves it, so nothing was written and the date the index has for it
            /// stands: the keywords it holds.
            case kept([KeywordPath]?)
            /// This build can't write it: the photo's path, and the keywords the index gives it then.
            case skipped(String, [KeywordPath])
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
        _ places: [Int], of batch: KeywordBatch, store: SidecarStore, paths: [Int64: String],
        log: KeywordJournal.Log, stop: Int?, done: SidecarCounter, report: @Sendable (Int) -> Void,
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
            var metadata = sidecar.metadata ?? PhotoMetadata()
            let before = SidecarKeywords(keywords: metadata.keywords)
            let after = batch.sidecarAfter(photo, current: before, fallback: photo.index)
            guard after != before else { return .keep }
            metadata.keywords = after.keywords
            sidecar.metadata = metadata.isEmpty ? nil : metadata
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
        _ result: SidecarBatchResult, _ photo: KeywordBatch.Photo, place: Int, of batch: KeywordBatch,
        at path: String, store: SidecarStore, log: KeywordJournal.Log,
    ) throws -> SidecarResult.Outcome {
        let before = SidecarKeywords(keywords: result.sidecar?.metadata?.keywords)
        let after = batch.sidecarAfter(photo, current: before, fallback: photo.index)
        switch result.outcome {
        case .kept:
            try log.written(place, before: before, after: after)
            return .kept(after.paths)
        case .saved:
            try log.written(place, before: before, after: after)
            let date = try? LocalFileSystem().attributes(of: store.locator.readURL(for: result.image)).modified
            return .written(after.paths, date)
        case let .failed(error):
            try log.skipped(place, Self.describe(error))
            return .skipped(path, before.paths ?? photo.undo?.indexBefore ?? photo.index)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case SidecarStoreError.writtenByNewerVersion: "a newer Redlamp wrote its sidecar"
        case SidecarStoreError.unreadable: "its sidecar can't be read"
        case SidecarStoreError.lossy: "saving its sidecar would lose what's in it"
        default: error.localizedDescription
        }
    }

    // MARK: - Planning

    /// The photos of `ids` whose keywords in the index `edit` changes, with them.
    private func photos(_ ids: [Int64], touchedBy edit: KeywordEdit) async throws -> [KeywordBatch.Photo] {
        let ids = Array(Set(ids)).sorted()
        return try await index.read { reader in
            let keywords = try reader.keywordPaths(ofPhotos: ids)
            let touched = ids.filter { keywords[$0].map(edit.touches) ?? false }
            let paths = try reader.photoPaths(touched)
            return touched.compactMap { id in
                paths[id].map { KeywordBatch.Photo(id: id, path: $0, index: keywords[id] ?? []) }
            }
        }
    }

    /// The photos with keywords within `keywords` that `edit` changes.
    private func photos(within keywords: [KeywordPath], touchedBy edit: KeywordEdit) async throws
        -> [KeywordBatch.Photo] {
        let ids = try await index.read { try $0.photoIDs(withKeywordsWithin: keywords) }
        return try await photos(ids, touchedBy: edit)
    }

    /// Keeps in the list, in `definitions`, each of `keywords` that `batch` leaves without photos.
    private func keepInList(
        _ keywords: [KeywordPath], losing batch: KeywordBatch, in definitions: inout KeywordDefinitions,
    ) async throws {
        let after = Dictionary(uniqueKeysWithValues: batch.photos.map {
            ($0.id, batch.indexAfter($0, current: $0.index))
        })
        for keyword in keywords where definitions.keywords[keyword] == nil {
            let holders = try await index.read { try $0.photoIDs(withKeywordsWithin: [keyword]) }
            let left = holders.contains { id in
                after[id].map { $0.contains { $0.isWithin(keyword) } } ?? true
            }
            if !left {
                definitions.keywords[keyword] = KeywordOptions()
            }
        }
    }

    /// Throws `noSuchKeyword` for the first of `keywords` that neither a photo nor the definitions has.
    private func requireKeywords(_ keywords: [KeywordPath], found: Bool, in definitions: KeywordDefinitions)
        async throws {
        guard !found else { return }
        let indexed = try await index.read { reader in
            try keywords.filter { try !reader.photoIDs(withKeywordsWithin: [$0]).isEmpty }
        }
        for keyword in keywords where !indexed.contains(keyword)
            && !definitions.keywords.keys.contains(where: { $0.isWithin(keyword) }) {
            throw KeywordError.noSuchKeyword(keyword)
        }
    }

    /// `Add “Animals › Birds” to 12 photos`, `Remove 3 keywords from a photo`, `Delete “Old”`.
    static func title(_ verb: String, _ keywords: [KeywordPath], _ photos: Int?, from: Bool = false) -> String {
        let what = keywords.count == 1 ? "“\(keywords[0].displayName)”" : "\(keywords.count) keywords"
        guard let photos else { return "\(verb) \(what)" }
        let count = photos == 1 ? "a photo" : "\(photos.formatted(.number.locale(Locale(identifier: "en_US")))) photos"
        return "\(verb) \(what) \(from ? "from" : "to") \(count)"
    }

    // MARK: - Helpers

    /// Loads the definitions, changes them with `change` and saves them, off the caller.
    func updateDefinitions(_ change: @escaping @Sendable (KeywordDefinitions) -> KeywordDefinitions) async throws {
        let url = definitionsURL
        try await LibraryIndex.offCaller {
            let current = try KeywordDefinitions.load(from: url)
            let changed = change(current)
            if changed != current {
                try changed.save(to: url)
            }
        }
    }

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
}

/// A count kept from several threads.
final class SidecarCounter: Sendable {
    private let count = Atomic(0)

    var value: Int {
        count.load(ordering: .relaxed)
    }

    /// Adds one; returns the count then.
    func add() -> Int {
        count.add(1, ordering: .relaxed).newValue
    }
}

extension KeywordDefinitions {
    /// Moves the keywords within each of `sources` to the same place within `target`, as renaming,
    /// moving and merging do: a source's own options join the target's (its synonyms added to its),
    /// and so do those of a keyword inside it that lands on one that's there; places in the keyword
    /// sets follow.
    mutating func move(_ sources: [KeywordPath], to target: KeywordPath) {
        for source in sources {
            let moving = keywords.filter { $0.key.isWithin(source) }
            for (path, _) in moving {
                keywords[path] = nil
            }
            for (path, options) in moving.sorted(by: { $0.key < $1.key }) {
                let destination = path.replacingPrefix(source, with: target)
                keywords[destination] = keywords[destination].map { $0.adding(synonymsOf: options) } ?? options
            }
        }
        sets = sets.map { sets in
            sets.map { set in
                KeywordSet(name: set.name, keywords: set.keywords.map { place in
                    place.map { keyword in
                        sources.first { keyword.isWithin($0) }
                            .map { keyword.replacingPrefix($0, with: target) } ?? keyword
                    }
                })
            }
        }
    }

    /// Takes the keywords within `removed` out, and out of the keyword sets.
    mutating func remove(_ removed: [KeywordPath]) {
        keywords = keywords.filter { entry in !removed.contains { entry.key.isWithin($0) } }
        sets = sets.map { sets in
            sets.map { set in
                KeywordSet(name: set.name, keywords: set.keywords.map { place in
                    place.flatMap { keyword in removed.contains { keyword.isWithin($0) } ? nil : keyword }
                })
            }
        }
    }
}

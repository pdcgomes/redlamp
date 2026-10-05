import Foundation
import RedlampDocument

public extension FileOperations {
    /// The photos `query` finds named by `template`, as Rename shows them before it runs: each with
    /// its raw or JPEG pair, the tokens that came out empty, and the names that would collide numbered
    /// in the order the photos were taken. A photo's original name comes from its sidecar when the
    /// template uses it.
    func renamePreview(
        _ template: NamingTemplate, query: LibraryQuery = .all, options: NamingOptions = NamingOptions(),
        context: NamingContext = NamingContext(), counters: NamingCounters = NamingCounters(),
    ) async throws -> NamingPreview {
        let engine = QueryEngine(index: index, timeZone: context.timeZone)
        try await engine.load()
        var found = QueryResult(ids: [], count: 0, isComplete: true)
        for try await result in engine.search(query) {
            found = result
        }
        return try await renamePreview(
            template, photos: Array(found.ids), query: query, options: options, context: context, counters: counters,
        )
    }

    /// Photos `ids`, with their pairs, named by `template`.
    func renamePreview(
        _ template: NamingTemplate, photos ids: [Int64], query: LibraryQuery = .all,
        options: NamingOptions = NamingOptions(), context: NamingContext = NamingContext(),
        counters: NamingCounters = NamingCounters(),
    ) async throws -> NamingPreview {
        let ids = try await withPairs(ids)
        let tokens = template.tokens
        let usesKeywords = tokens.contains { $0.field == .keywords }
        var found = try await index.read { reader in
            try NamingFields.read(ids, from: reader, keywords: usesKeywords)
        }
        let locator = try await locator()
        let fileSystem = fileSystem
        let usesOriginal = tokens.contains { $0.field == .original || $0.field == .number }
        let folders = Set(found.map(\.fields.folder))
        let (listed, originals) = try await LibraryIndex.offCaller { [found] () -> ([String: Set<String>], [String?]) in
            var listed: [String: Set<String>] = [:]
            for folder in folders {
                let entries = try? fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: folder, isDirectory: true))
                listed[folder] = Set((entries ?? []).map(\.name))
            }
            let store = SidecarStore(locator: locator)
            let originals = usesOriginal ? found.map { photo in
                store.summary(for: URL(fileURLWithPath: photo.fields.folder + "/" + photo.fields.name))?.metadata
                    .originalName
            } : []
            return (listed, originals)
        }
        for (index, original) in originals.enumerated() {
            found[index].fields.originalName = original
        }
        let job = NamingJob(found.map { NamingPhoto($0.fields) }, existing: listed)
        let clock = ContinuousClock()
        let started = clock.now
        let batch = job.names(template, options: options, context: context, counters: counters)
        let elapsed = clock.now - started
        let entries = zip(found, batch.results).map { photo, result in
            NamingPreview.Entry(id: photo.id, path: photo.fields.folder + "/" + photo.fields.name, result: result)
        }
        return NamingPreview(template: template, query: query, entries: entries, batch: batch, elapsed: elapsed)
    }

    /// The batch that gives each photo of `preview` its new name, with its sidecars and other apps',
    /// and records the name it had in its sidecar the first time it's renamed.
    func planRename(_ preview: NamingPreview) async throws -> FileBatch {
        let moves = preview.entries.filter { !$0.result.isUnchanged }.map { entry in
            PhotoMove(
                id: entry.id,
                from: entry.path,
                to: FilePlanner.split(entry.path).folder + "/" + entry.result.name,
            )
        }
        let steps = try await moveSteps(moves)
        let count = Set(moves.map(\.id)).count
        return FileBatch(
            kind: .rename, title: "Rename \(count) photo\(count == 1 ? "" : "s")",
            steps: Self.recordingOriginalNames(steps, moves: moves),
        )
    }

    /// `ids` with the photos that share a folder and a name but for the extension with one of them, each
    /// after the first of its pair.
    func withPairs(_ ids: [Int64]) async throws -> [Int64] {
        try await index.read { reader in
            var byFolder: [Int64: [String: [Int64]]] = [:]
            var result: [Int64] = []
            var seen = Set<Int64>()
            for id in ids {
                guard let photo = try reader.photo(id: id), seen.insert(id).inserted else { continue }
                result.append(id)
                if byFolder[photo.folder] == nil {
                    var stems: [String: [Int64]] = [:]
                    for sibling in try reader.photos(inFolder: photo.folder) {
                        stems[NamingJob.fold(NamingJob.split(sibling.name).base), default: []].append(sibling.id)
                    }
                    byFolder[photo.folder] = stems
                }
                for partner in byFolder[photo.folder]?[NamingJob.fold(NamingJob.split(photo.name).base)] ?? []
                    where seen.insert(partner).inserted {
                    result.append(partner)
                }
            }
            return result
        }
    }

    /// The steps that make `moves`, planned from the files as they are now.
    internal func moveSteps(_ moves: [PhotoMove]) async throws -> [FileStep] {
        let locator = try await locator()
        let fileSystem = fileSystem
        return try await LibraryIndex.offCaller {
            FilePlanner(fileSystem: fileSystem, locator: locator).moveSteps(moves)
        }
    }

    /// `steps` with each photo's original name recorded after the steps that rename it: at the first
    /// safe step after every `namesPerStep` photos renamed, and after the last.
    internal static func recordingOriginalNames(_ steps: [FileStep], moves: [PhotoMove]) -> [FileStep] {
        let originals = Dictionary(moves.map { ($0.id, $0.from) }) { first, _ in first }
        var result: [FileStep] = []
        var renamed: [Int64: String] = [:]
        var order: [Int64] = []
        for (index, step) in steps.enumerated() {
            var step = step
            for photo in step.photos where originals[photo.id] != nil {
                if renamed.updateValue(photo.to, forKey: photo.id) == nil {
                    order.append(photo.id)
                }
            }
            guard step.isSafe, !order.isEmpty, order.count >= namesPerStep || index == steps.count - 1 else {
                step.isSafe = step.isSafe && order.isEmpty
                result.append(step)
                continue
            }
            step.isSafe = false
            result.append(step)
            result.append(FileStep(kind: .recordOriginalNames, photos: order.compactMap { id in
                guard let original = originals[id], let now = renamed[id],
                      FilePlanner.split(original).name != FilePlanner.split(now).name
                else { return nil }
                return PhotoMove(id: id, from: original, to: now)
            }))
            renamed = [:]
            order = []
        }
        return result
    }

    /// Photos whose original names one step records.
    internal static let namesPerStep = 256
}

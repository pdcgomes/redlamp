import Foundation
import Synchronization

/// Puts new photos where an import's settings say, one at a time as they arrive (LIB-27): what a
/// tethered capture session (TET-01) does with each frame its camera sends, through the path an
/// import's photos take, with its templates, defaults and checks.
///
/// Each photo is read once, planned as a one-photo import (its folders and name from the settings'
/// templates, numbered to tell it from what's already in its folder at the destination and the backup,
/// those ingested before included) and run by the importer: copied with the sidecars named after it,
/// verified at every target, journaled, its `.redlamp` given the choices and the metadata preset, and
/// its folder indexed. Sequences and named counters carry on from one photo to the next.
public final class ImportIngest: Sendable {
    public let library: ImportLibrary
    public let importer: Importer
    private let state: Mutex<State>
    private let serial = Mutex<Task<Void, Never>?>(nil)

    private struct State {
        var settings: ImportSettings
        var sequence: Int
    }

    /// A photo once it's in place.
    public struct Placed: Sendable, Hashable {
        /// Its files at the destination, the photo first, then the sidecars that came with it.
        public var files: [URL]
        /// The same at the backup.
        public var backups: [URL]
        public var contentKey: ContentKey?
        /// The number its name was given to tell it from another's.
        public var numbered: Int?
        public var outcome: ImportOutcome

        public var photo: URL? {
            files.first
        }
    }

    public init(
        settings: ImportSettings, library: ImportLibrary, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        destinationFileSystem: any LibraryFileSystem = LocalFileSystem(),
    ) {
        self.library = library
        importer = Importer(library: library, fileSystem: fileSystem, destinationFileSystem: destinationFileSystem)
        state = Mutex(State(settings: settings, sequence: settings.naming.sequenceStart))
    }

    /// The settings the next photo is ingested with: the counters moved on by those before it.
    public var settings: ImportSettings {
        state.withLock { $0.settings }
    }

    /// Ingests the photo at `url`, with the sidecars named after it beside it, and `choices` for its
    /// `.redlamp`. Throws when it isn't a photo, couldn't be read, or wasn't verified at every target.
    public func ingest(_ url: URL, choices: ImportChoices = ImportChoices()) async throws -> Placed {
        try await serially { [self] in try await ingestNow(url, choices: choices) }
    }

    private func ingestNow(_ url: URL, choices: ImportChoices) async throws -> Placed {
        let file = URL(fileURLWithPath: LibraryIndexer.path(url), isDirectory: false)
        let folder = file.deletingLastPathComponent()
        let fileSystem = importer.fileSystem
        let source = try await LibraryIndex.offCaller { try ImportSource.at(folder, fileSystem: fileSystem) }
        let name = file.lastPathComponent
        let entries = try await importer.volumes.io(for: source.volume, probe: source.url)
            .contentsOfDirectory(at: source.url)
            .filter { entry in
                let folded = NamingJob.fold(entry.name)
                let base = NamingJob.split(folded).base
                return entry.name == name || base == NamingJob.fold(name)
                    || base == NamingJob.fold(NamingJob.split(name).base)
                    && NamingJob.sidecarExtensions.contains(NamingJob.split(folded).ext)
            }
        guard entries.contains(where: { $0.name == name && FolderWalk.isPhoto($0) }) else {
            throw ImportCopyError(path: file.path, message: "it isn't a photo Redlamp reads")
        }
        let session = ImportSession(
            sources: [source], library: library, fileSystem: fileSystem, volumes: importer.volumes,
            makesPreviews: false,
        )
        let found = ImportPhoto.group(entries, folder: LibraryIndexer.path(folder), source: source.id).photos
        let photos = found.filter { $0.files.contains { $0.name == name } }
        session.add(photos)
        let ids = photos.map(\.id)
        session.choose(ids, true)
        session.change(ids) { $0 = Self.merged(choices, into: $0) }
        let settings = state.withLock { state in
            var settings = state.settings
            settings.naming.sequenceStart = state.sequence
            return settings
        }
        let plan = try await session.plan(settings, destinationFileSystem: importer.destinationFileSystem)
        guard let item = plan.items.first else {
            let reason = plan.left.first?.reason.rawValue ?? "nothing to copy"
            throw ImportCopyError(path: file.path, message: "it wasn't ingested: \(reason)")
        }
        let outcome = try await importer.run(plan)
        if let failure = outcome.failures.first {
            throw ImportCopyError(path: file.path, message: failure.message)
        }
        state.withLock { state in
            state.sequence += 1
            state.settings.counters = plan.counters
        }
        return Placed(
            files: item.copies.compactMap { plan.targets(of: $0).first },
            backups: item.copies.compactMap { plan.targets(of: $0).dropFirst().first },
            contentKey: item.photos.first?.contentKey, numbered: item.numbered, outcome: outcome,
        )
    }

    /// `choices` with the fields it doesn't give left as `own` has them.
    private static func merged(_ choices: ImportChoices, into own: ImportChoices) -> ImportChoices {
        var merged = own
        if choices.given.contains(.rating) {
            merged.rate(choices.rating)
        }
        if choices.given.contains(.flag) {
            merged.setFlag(choices.flag)
        }
        if choices.given.contains(.label) {
            merged.setLabel(choices.label)
        }
        return merged
    }

    private func serially<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = serial.withLock { last -> Task<T, any Error> in
            let previous = last
            let task = Task {
                await previous?.value
                return try await body()
            }
            last = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}

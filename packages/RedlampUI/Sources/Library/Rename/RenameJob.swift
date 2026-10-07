import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// The photos Rename Photos names (LIB-25, LIB-26), read once off the main thread as
/// `FileOperations.renamePreview` reads them: each with its raw or JPEG pair after it, its fields from the
/// index, and the names of the files in its folder; and, once a template asks for `{original}` or
/// `{number}`, its name before Redlamp first renamed it, from its sidecar. Each template is then named
/// off the main thread from the same job, so collisions are numbered in capture order as `planRename`
/// takes them.
struct RenameJob: Sendable {
    /// The photos in the job's order, by their index IDs, and where each is now.
    let ids: [Int64]
    let paths: [String]
    let job: NamingJob
    /// Each photo's original name was read from its sidecar.
    let hasOriginals: Bool
    private let existing: [String: Set<String>]
    /// The photos that have a sidecar, which may hold an original name.
    private let sidecars: [Bool]

    /// Photos `ids` of `core`'s index with their pairs, in that order; those it doesn't have are left out.
    static func read(_ ids: [Int64], core: LibraryCore) async throws -> RenameJob {
        let ids = try await core.files.withPairs(ids)
        let (found, sidecars) = try await core.index.read { reader in
            let found = try NamingFields.read(ids, from: reader, keywords: true)
            return try (found, found.map { try reader.photo(id: $0.id)?.sidecarModified != nil })
        }
        let fileSystem = core.files.fileSystem
        let existing = await Task.detached(priority: .userInitiated) {
            var listed: [String: Set<String>] = [:]
            for folder in Set(found.map(\.fields.folder)) {
                let entries = try? fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: folder, isDirectory: true))
                listed[folder] = Set((entries ?? []).map(\.name))
            }
            return listed
        }.value
        return RenameJob(
            ids: found.map(\.id), paths: found.map { $0.fields.folder + "/" + $0.fields.name },
            job: NamingJob(found.map { NamingPhoto($0.fields) }, existing: existing), hasOriginals: false,
            existing: existing, sidecars: sidecars,
        )
    }

    /// Whether naming `template` needs the photos' original names.
    static func needsOriginals(_ template: NamingTemplate) -> Bool {
        template.tokens.contains { $0.field == .original || $0.field == .number }
    }

    /// The job again with each photo's original name, as `sidecars` reads it, a few photos at a time on every core.
    func withOriginals(_ sidecars: SidecarPlacement) -> RenameJob {
        guard !hasOriginals else { return self }
        let photos = job.photos
        let paths = paths
        let hasSidecar = self.sidecars
        let originals = Mutex([String?](repeating: nil, count: photos.count))
        let chunk = 256
        DispatchQueue.concurrentPerform(iterations: (photos.count + chunk - 1) / chunk) { number in
            let range = number * chunk ..< min(photos.count, (number + 1) * chunk)
            let read = range.map { index -> String? in
                guard hasSidecar[index] else { return nil }
                let url = URL(fileURLWithPath: paths[index])
                return sidecars.store(for: url).summary(for: url)?.metadata.originalName
            }
            originals.withLock { originals in
                for (index, name) in zip(range, read) {
                    originals[index] = name
                }
            }
        }
        let named = originals.withLock { $0 }
        let photosWithOriginals = zip(photos, named).map { photo, original in
            var photo = photo
            photo.fields.originalName = original
            return photo
        }
        return RenameJob(
            ids: ids, paths: paths, job: NamingJob(photosWithOriginals, existing: existing), hasOriginals: true,
            existing: existing, sidecars: self.sidecars,
        )
    }

    /// Each photo's new name from `template`.
    func names(
        _ template: NamingTemplate, options: NamingOptions, context: NamingContext, counters: NamingCounters,
    ) -> NamingBatch {
        job.names(template, options: options, context: context, counters: counters)
    }

    /// The renames `batch` names, but for the photos that keep their names.
    func renames(_ batch: NamingBatch) -> [PhotoRename] {
        zip(ids.indices, batch.results).compactMap { index, result in
            result.isUnchanged ? nil : PhotoRename(id: ids[index], path: paths[index], name: result.name)
        }
    }
}

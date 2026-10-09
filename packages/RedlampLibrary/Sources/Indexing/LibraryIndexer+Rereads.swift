import Foundation

extension LibraryIndexer {
    /// A folder's listing sorted into its photos, the `.redlamp` sidecars beside them by their photos' names, and
    /// other apps' `.xmp` by lowercased name.
    struct ListedFiles {
        var photos: [FileEntry] = []
        var sidecars: [String: FileEntry] = [:]
        var xmps: [String: FileEntry] = [:]

        init(_ entries: [FileEntry]) {
            for entry in entries {
                let name = entry.name.lowercased()
                if name.hasSuffix(".redlamp") {
                    sidecars[String(entry.name.dropLast(".redlamp".count))] = entry
                } else if !entry.isDirectory, name.hasSuffix(".xmp") {
                    xmps[name] = entry
                } else if FolderWalk.isPhoto(entry) {
                    photos.append(entry)
                }
            }
        }

        /// The job for `entry`, one of the photos, with the files beside it and what `LibraryXMP` recorded of it.
        func job(
            _ kind: PhotoJob.Kind, folder: String, entry: FileEntry, existing: PhotoRecord?,
            merged: [Int64: XMPMergeRecord],
        ) -> PhotoJob {
            let (xmp, darktable) = Run.xmps(for: entry.name, in: xmps)
            return PhotoJob(
                kind: kind, folder: folder, entry: entry, existing: existing, sidecar: sidecars[entry.name], xmp: xmp,
                darktable: darktable, merged: existing.flatMap { merged[$0.id] },
            )
        }
    }
}

extension LibraryIndexer.Run {
    /// Rounds of reading photos again, at most: each reads those the library overtook in the round before.
    static let rereadRounds = 3

    /// Reads again, once the library is done writing them, the photos whose reads it overtook (`PhotoWrites`):
    /// written, those reads would have put back what the library had just changed, and what another app wrote meanwhile
    /// is in their files still.
    func rereadStale() async {
        for _ in 0 ..< Self.rereadRounds {
            await batcher.drain()
            let stale = state.withLock { state in
                defer { state.stale = [] }
                return state.stale
            }
            guard !stale.isEmpty, !Task.isCancelled else { return }
            await indexer.index.photoWrites.idle(Set(stale.map(\.photo)))
            for (folder, photos) in Dictionary(grouping: stale, by: \.folder) where !Task.isCancelled {
                await reread(Set(photos.map(\.name)), in: folder)
            }
        }
    }

    /// Lists `folder` again and reads its photos named `names` whole, whatever their rows say.
    private func reread(_ names: Set<String>, in folder: String) async {
        let volume = state.withLock { state in
            state.volumes.first { volume in volume.roots.contains { folder == $0 || folder.hasPrefix($0 + "/") } }
        }
        guard let volume, let jobs = try? await listedAgain(folder, names, on: volume) else { return }
        for job in jobs {
            do {
                try await process(job, on: volume)
            } catch {
                if !(error is CancellationError) {
                    failed(job.folder + "/" + job.entry.name, error)
                }
            }
        }
    }

    /// The jobs that read `names` in `folder` again, from its listing and rows now, once no file batch holds it.
    private func listedAgain(
        _ folder: String, _ names: Set<String>, on volume: LibraryIndexer.VolumeWork,
    ) async throws -> [LibraryIndexer.PhotoJob] {
        let listing = try await indexer.index.folderHolds.list(folder)
        defer { listing.done() }
        let entries = try await volume.io.contentsOfDirectory(at: URL(fileURLWithPath: folder, isDirectory: true))
        let withRecords = state.withLock { $0.hasMergeRecords }
        let (rows, merged) = try await indexer.index.read { reader -> ([PhotoRecord], [Int64: XMPMergeRecord]) in
            guard let id = try reader.folder(path: folder)?.id else { return ([], [:]) }
            let rows = try reader.photos(inFolder: id).filter { names.contains($0.name) }
            return try (rows, withRecords ? XMPMergeRecord.records(rows.map(\.id), in: reader) : [:])
        }
        let files = LibraryIndexer.ListedFiles(entries)
        let byName = Dictionary(rows.map { ($0.name, $0) }) { first, _ in first }
        return files.photos.compactMap { entry in
            byName[entry.name].map { files.job(.changed, folder: folder, entry: entry, existing: $0, merged: merged) }
        }
    }
}

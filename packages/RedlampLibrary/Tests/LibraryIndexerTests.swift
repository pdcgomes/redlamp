import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

struct LibraryIndexerTests {
    /// Every row below the root, with its folder's path.
    static func rows(_ sandbox: IndexerSandbox) async throws -> [String: PhotoRecord] {
        let rootPath = sandbox.rootPath
        return try await sandbox.index.read { reader in
            guard let root = try reader.root(path: rootPath) else { return [:] }
            let folders = try Dictionary(uniqueKeysWithValues: reader.folders(inRoot: root.id).map { ($0.id, $0.path) })
            guard let top = try reader.folder(path: rootPath) else { return [:] }
            var rows: [String: PhotoRecord] = [:]
            for photo in try reader.photos(inSubtreeOf: top.id) {
                rows[(folders[photo.folder] ?? "?") + "/" + photo.name] = photo
            }
            return rows
        }
    }

    @Test(.enabled(if: !FixtureTests.sources.isEmpty))
    func `a fixture indexes completely, with the manifest's counts, cameras and dates`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 500, seed: 21), raws: true)
        defer { sandbox.remove() }
        let counting = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing())
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        let summary = try #require(run.summary)
        let totals = sandbox.manifest.totals
        #expect(run.failures.isEmpty, "\(run.failures)")
        #expect(summary.photosInserted == totals.photos && summary.headsRead == totals.photos)
        #expect(Set(run.inserted).count == totals.photos)
        #expect(summary.foldersListed == totals.folders + 1 && summary.foldersIndexed == totals.folders + 1)

        let photos = (0 ..< totals.photos).map(sandbox.fixture.photo(at:))
        // One read of each photo's head, and nothing else of it.
        let reads = counting.counts.reads
        #expect(counting.counts.heads == totals.photos)
        #expect(photos.allSatisfy { reads[sandbox.url($0).path] == 1 })

        let rows = try await Self.rows(sandbox)
        let (cameras, keywords, folders, unfinished) = try await sandbox.index.read { reader in
            var keywords: [Int64: [String]] = [:]
            for row in rows.values {
                keywords[row.id] = try reader.keywords(forPhoto: row.id)
            }
            return try (reader.cameraNames(), keywords, reader.folderCount(), reader.foldersToIndex())
        }
        #expect(rows.count == totals.photos)
        #expect(folders == totals.folders + 1 && unfinished.isEmpty)
        for photo in photos {
            let row = try #require(rows[sandbox.path(photo.path)], "\(photo.path)")
            #expect(row.kind == (photo.kind == .raw ? .raw : photo.kind == .heic ? .heic : .jpeg))
            // A raw keeps its source's sub-second digits; only its date and time are its own.
            #expect(row.captured.map { floor($0.timeIntervalSince1970) } == photo.captured.date.timeIntervalSince1970)
            let camera = row.camera.flatMap { cameras[$0] } ?? ""
            #expect(camera.localizedCaseInsensitiveContains(photo.model ?? "?"), "\(camera) for \(photo.path)")
            #expect(row.rating == photo.rating && row.flag == photo.flag && row.label == photo.label)
            #expect(row.edited == photo.isEdited)
            #expect(Set(keywords[row.id] ?? []) == Set(photo.keywords), "\(photo.path)")
            #expect(row.caption == photo.caption)
            #expect((row.latitude != nil) == (photo.location != nil))
            #expect(row.width != nil && row.height != nil && row.contentKey?.count == 16 && row.indexed == 1)
            #expect((row.sidecarModified != nil) == (photo.sidecar != nil))
            #expect((row.xmpModified != nil) == (photo.xmp != nil))
        }
        let all = Array(rows.values)
        let manifest = sandbox.manifest
        #expect(all.count { $0.rating >= 3 } == manifest.count(of: "rating>=3"))
        #expect(all.count { $0.flag == .pick } == manifest.count(of: "flag:pick"))
        #expect(all.count { $0.label == .red || $0.label == .blue } == manifest.count(of: "label:red,blue"))
        #expect(all.count(where: \.edited) == manifest.count(of: "edited:yes"))
        #expect(all.count { $0.latitude != nil } == manifest.count(of: "has:gps"))
        #expect(all.count { $0.kind == .raw } == manifest.count(of: "type:raw"))
        #expect(all.count { keywords[$0.id]?.contains("birds") == true } == manifest.count(of: "kw:birds"))

        let sample = try #require(photos.first { $0.kind == .raw })
        let head = try LocalFileSystem().read(sandbox.url(sample), range: 0 ..< PhotoMetadataReader.headLength)
        let size = try LocalFileSystem().attributes(of: sandbox.url(sample)).size
        #expect(rows[sandbox.path(sample.path)]?.contentKey == ContentKey(fileSize: Int(size), head: head).data)
    }

    @Test func `a run with nothing changed lists every folder and reads no file`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 22))
        defer { sandbox.remove() }
        let first = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]),
        )
        #expect(first.summary?.photosInserted == 300)
        let counting = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing())
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        let summary = try #require(run.summary)
        #expect(counting.counts.read == 0 && counting.counts.heads == 0)
        #expect(counting.counts.listed == sandbox.manifest.totals.folders + 1)
        #expect(summary.headsRead == 0 && summary.photosInserted == 0 && summary.photosUpdated == 0)
        #expect(summary.photosRemoved == 0 && summary.foldersIndexed == 0 && run.failures.isEmpty)
    }

    @Test func `a run stopped partway resumes, reading only the photos it hadn't written`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 800, seed: 23))
        defer { sandbox.remove() }
        let counting = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing(batchSize: 50))
        var inserted = 0
        for await event in indexer.index([sandbox.root]) {
            if case let .photosInserted(ids) = event {
                inserted += ids.count
                if inserted >= 150 {
                    break
                }
            }
        }
        await indexer.settle()
        let written = try await sandbox.index.read { try $0.photoCount() }
        #expect(written >= 150 && written < 800, "\(written)")
        #expect(try await sandbox.index.read { try $0.foldersToIndex() }.count > 0)

        counting.reset()
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(run.summary?.headsRead == 800 - written)
        #expect(counting.counts.heads == 800 - written)
        let (count, unfinished) = try await sandbox.index.read { try ($0.photoCount(), $0.foldersToIndex()) }
        #expect(count == 800 && unfinished.isEmpty)
    }

    @Test func `photos renamed or moved in the Finder keep their rows`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 240, seed: 24, shapes: []))
        defer { sandbox.remove() }
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing())
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        let before = try await Self.rows(sandbox)
        let photos = (0 ..< 240).map(sandbox.fixture.photo(at:))
        let plain = photos.filter { $0.sidecar == nil && $0.xmp == nil }
        let renamed = try #require(plain.first)
        let moved = try #require(plain.first { $0.folder != renamed.folder })
        let leftBehind = try #require(photos.first { $0.sidecar != nil && $0.folder != moved.folder })
        let moves = [
            (renamed, renamed.folder + "/Renamed " + renamed.name),
            (moved, renamed.folder + "/Moved " + moved.name),
            (leftBehind, leftBehind.folder + "/Without its sidecar " + leftBehind.name),
        ]
        for (photo, path) in moves {
            try FileManager.default.moveItem(at: sandbox.url(photo), to: sandbox.root.appending(path: path))
        }

        let counting = CountingFileSystem()
        let again = LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing())
        let run = await IndexerRun.collect(again.index([sandbox.root]))
        let summary = try #require(run.summary)
        #expect(summary.photosMoved == 3 && summary.photosInserted == 0 && summary.photosRemoved == 0)
        // The photo whose sidecar stayed behind is read again; the others aren't read at all.
        #expect(summary.headsRead == 1 && counting.counts.heads == 1)
        let after = try await Self.rows(sandbox)
        #expect(after.count == 240)
        for (photo, path) in moves {
            let id = try #require(before[sandbox.path(photo.path)]?.id)
            #expect(after[sandbox.path(path)]?.id == id, "\(path)")
            #expect(after[sandbox.path(photo.path)] == nil)
        }
        #expect(after[sandbox.path(moves[1].1)]?.contentKey == before[sandbox.path(moved.path)]?.contentKey)
        #expect(after[sandbox.path(moves[2].1)]?.sidecarModified == nil)
    }

    @Test func `photos and folders that vanish are removed`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 400, seed: 25, shapes: []))
        defer { sandbox.remove() }
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing())
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        let folders = sandbox.fixture.folders
        let removedFolder = try #require(folders.last)
        let kept = folders[0]
        let gone = sandbox.fixture.photos(in: kept).prefix(2)
        for photo in gone {
            try FileManager.default.removeItem(at: sandbox.url(photo))
        }
        try FileManager.default.removeItem(at: sandbox.root.appending(path: removedFolder.path))

        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        let summary = try #require(run.summary)
        let removed = gone.count + removedFolder.photos.count
        #expect(summary.photosRemoved == removed && summary.foldersRemoved == 1 && summary.headsRead == 0)
        let removedIDs = run.events.flatMap { event -> [Int64] in
            guard case let .photosRemoved(ids) = event else { return [] }
            return ids
        }
        #expect(removedIDs.count == removed)
        let rows = try await Self.rows(sandbox)
        #expect(rows.count == 400 - removed)
        #expect(gone.allSatisfy { rows[sandbox.path($0.path)] == nil })
        let removedPath = sandbox.path(removedFolder.path)
        let (folder, unfinished) = try await sandbox.index.read { reader in
            try (reader.folder(path: removedPath), reader.foldersToIndex())
        }
        #expect(folder == nil && unfinished.isEmpty)
        let keptFolder = FolderIndexed(path: sandbox.path(kept.path), removed: 2)
        #expect(run.events.contains(LibraryIndexerEvent.folderIndexed(keptFolder)))
    }

    @Test func `a photo rewritten is read again in place, and a sidecar saved changes only its row`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 200, seed: 26, shapes: []))
        defer { sandbox.remove() }
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing())
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        let before = try await Self.rows(sandbox)
        let photos = (0 ..< 200).map(sandbox.fixture.photo(at:))
        let rewritten = try #require(photos.first { $0.sidecar == nil && $0.xmp == nil && $0.kind == .jpeg })
        let other = try #require(photos.first { $0.kind == .heic })
        try Data(contentsOf: sandbox.url(other)).write(to: sandbox.url(rewritten))
        let rated = try #require(photos.first { $0.sidecar != nil })
        var sidecar = try #require(SidecarStore().load(for: sandbox.url(rated)))
        let rating = rated.rating == 5 ? 1 : 5
        sidecar.metadata = PhotoMetadata(rating: rating, flag: .pick, label: .green)
        try SidecarStore().save(sidecar, for: sandbox.url(rated))

        let counting = CountingFileSystem()
        let again = LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing())
        let run = await IndexerRun.collect(again.index([sandbox.root]))
        let summary = try #require(run.summary)
        #expect(summary.photosUpdated == 2 && summary.headsRead == 1 && counting.counts.heads == 1)
        let after = try await Self.rows(sandbox)
        let rewrittenRow = try #require(after[sandbox.path(rewritten.path)])
        #expect(rewrittenRow.id == before[sandbox.path(rewritten.path)]?.id)
        #expect(rewrittenRow.contentKey == before[sandbox.path(other.path)]?.contentKey)
        #expect(rewrittenRow.contentKey != before[sandbox.path(rewritten.path)]?.contentKey)
        let ratedRow = try #require(after[sandbox.path(rated.path)])
        #expect(ratedRow.id == before[sandbox.path(rated.path)]?.id)
        #expect(ratedRow.rating == rating && ratedRow.flag == .pick && ratedRow.label == .green)
        #expect(ratedRow.contentKey == before[sandbox.path(rated.path)]?.contentKey)
    }

    @Test func `the thumbnail handler gets each new photo's content key and head once its row is written`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 150, seed: 27, shapes: []))
        defer { sandbox.remove() }
        let calls = Mutex<[String: (key: ContentKey, head: Int, written: Bool)]>([:])
        let index = sandbox.index
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing(batchSize: 40)) { url, key, head in
            let written = (
                try? index.onWriterAndWait { try LibraryIndex.Reader(database: $0).photo(path: url.path) },
            ) !=
                nil
            calls.withLock { $0[url.path] = (key, head.count, written) }
        }
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))
        let deadline = ContinuousClock.now + .seconds(10)
        while calls.withLock({ $0.count }) < 150, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let rows = try await Self.rows(sandbox)
        let made = calls.withLock { $0 }
        #expect(made.count == 150)
        for (path, row) in rows {
            let call = try #require(made[path])
            #expect(call.key.data == row.contentKey && call.written)
            #expect(call.head == min(Int(row.size), PhotoMetadataReader.headLength))
        }
    }

    @Test func `the folders asked for are indexed first`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 900, seed: 28, shapes: []))
        defer { sandbox.remove() }
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing(batchSize: 50))
        let wanted = try #require(sandbox.fixture.folders.dropFirst(2).first)
        indexer.prioritise([sandbox.root.appending(path: wanted.path)])
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        let indexed = run.events.compactMap { event -> String? in
            guard case let .folderIndexed(folder) = event, folder.inserted > 0 else { return nil }
            return folder.path
        }
        #expect(indexed.first == sandbox.path(wanted.path), "\(indexed)")
        #expect(indexed.count == sandbox.fixture.folders.count)
    }

    @Test func `a volume that disconnects partway marks its photos offline without hanging, and resumes when back`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 29, shapes: []))
        defer { sandbox.remove() }
        let gone = VolumeProfile.nas.disconnecting(.init(.afterOperations(150), failure: .timeout(.seconds(5))))
        let volume = SwitchingFileSystem(SimulatedFileSystem(profile: gone, seed: 1))
        let volumes = VolumeIORegistry(fileSystem: volume, configuration: .init(
            timeout: .milliseconds(300), probeIntervals: .milliseconds(100) ... .milliseconds(400),
        ))
        let indexer = LibraryIndexer(index: sandbox.index, volumes: volumes, configuration: .testing(batchSize: 50))
        let clock = ContinuousClock()
        let started = clock.now
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(clock.now - started < .seconds(5))
        let summary = try #require(run.summary)
        #expect(summary.offlineVolumes.count == 1)
        let key = try #require(summary.offlineVolumes.first)
        #expect(run.events.contains(LibraryIndexerEvent.volumeOffline(key)))
        let (offline, written) = try await sandbox.index
            .read { try ($0.photoCount(withState: .offline), $0.photoCount()) }
        #expect(written > 0 && written < 300 && offline == written, "\(offline) of \(written)")
        let io = try #require(volumes.all.first)
        #expect(!io.isReachable)
        #expect(io.statistics.longestWait < .milliseconds(800), "\(io.statistics.longestWait)")

        volume.switchTo(SimulatedFileSystem(profile: .nas, seed: 2))
        await io.waitUntilReachable()
        let again = await IndexerRun.collect(indexer.index([sandbox.root]))
        #expect(again.events.contains(LibraryIndexerEvent.volumeOnline(key)))
        #expect(again.summary?.offlineVolumes.isEmpty == true)
        let (stillOffline, count) = try await sandbox.index.read { try (
            $0.photoCount(withState: .offline),
            $0.photoCount(),
        ) }
        #expect(stillOffline == 0 && count == 300)
    }
}

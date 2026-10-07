import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The library at launch: its roots current once change tracking has caught up with their volume, and
/// not after a pass that ended offline; and the file operations a forced quit cut short finished before
/// the indexer lists their folders, and the health rows and hashes nothing can bring back swept.
@MainActor
struct LibraryLaunchTests {
    private let base = FileManager.default.temporaryDirectory
        .appending(path: "library-launch-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL

    private var root: URL {
        base.appending(path: "Photos", directoryHint: .isDirectory)
    }

    private var paths: LibraryPaths {
        LibraryPaths(root: base.appending(path: "Library", directoryHint: .isDirectory))
    }

    private func photo(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .notDirectory)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }

    private func photos(_ names: [String]) throws {
        for (number, name) in names.enumerated() {
            try CullingTests.IndexedFolder.writeJPEG(photo(name), shade: number)
        }
    }

    /// A library following the root, launched as the app launches it.
    private func launch() -> (FolderLibrary, LibraryService) {
        let library = FolderLibrary()
        library.add([root])
        let service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        return (library, service)
    }

    private func eventually(seconds: Double = 30, _ condition: () async -> Bool) async throws {
        for _ in 0 ..< Int(seconds * 100) where await !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A first launch that indexes the root and catches up with it, then quits.
    private func indexOnce() async throws {
        let (_, service) = launch()
        try await eventually { await service.canShow(root, includingSubfolders: true) }
        try #require(await service.canShow(root, includingSubfolders: true))
        service.close()
        await service.core?.index.close()
    }

    @Test func `a volume's roots are current once change tracking has caught up with it, and not before`(
    ) async throws {
        defer { cleanUp() }
        try photos(["IMG_1.JPG", "IMG_2.JPG"])
        try await indexOnce()

        // The next launch indexes nothing, so the folder shows from the library only once it's caught up.
        let (_, service) = launch()
        defer { service.close() }
        try await eventually { service.currentRoots.contains(LibraryService.path(root)) }
        #expect(service.currentRoots == [LibraryService.path(root)])
        #expect(await service.canShow(root, includingSubfolders: true))

        let core = try #require(service.core)
        let volume = try #require(try await core.index.read { try $0.volumes().first?.uuid })
        let reported = Mutex<[LibraryService.Progress]>([])
        let report: @Sendable (LibraryService.Progress) async -> Void = { progress in
            reported.withLock { $0.append(progress) }
        }
        var offline = LibraryIndexerSummary()
        offline.offlineVolumes = [volume]
        for event: ChangeTracker.Event in [
            .replayed(volume: volume, folders: 0), .reconciled(volume: volume, reason: .reconnected),
            .changed(volume: volume, folders: 2), .polled(volume: volume, shown: false),
            .indexer(.finished(LibraryIndexerSummary())), .indexer(.finished(offline)),
        ] {
            await LibraryService.followed(event, core: core, report: report)
        }
        #expect(
            !reported.withLock { $0 }.contains {
                if case .current = $0 {
                    true
                } else {
                    false
                }
            },
            "no event but caughtUp makes a volume current: \(reported.withLock { $0 })",
        )

        await LibraryService.followed(.indexer(.volumeOffline(volume)), core: core, report: report)
        await LibraryService.followed(.caughtUp(volume: volume), core: core, report: report)
        let paths = [LibraryService.path(root)]
        #expect(reported.withLock { $0 }.suffix(2) == [.offline(paths), .current(paths)])
    }

    @Test func `a rename a forced quit cut short is finished at launch, before its folder is indexed again`(
    ) async throws {
        defer { cleanUp() }
        try photos(["A.JPG", "B.JPG", "C.JPG"])
        try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 3)), for: photo("A.JPG"))
        try await indexOnce()

        let index = try await LibraryIndex.open(at: paths.index)
        let originals = ["A.JPG", "B.JPG", "C.JPG"].map { LibraryService.path(photo($0)) }
        let rows = try await index.read { reader in try originals.compactMap { try reader.photo(path: $0) } }
        try #require(rows.count == 3)
        // Health rows and hashes of a photo the index no longer has, which no batch can bring back.
        try await index.write { writer in
            try writer.database.execute("""
            INSERT INTO photo_hashes (photo, size, modified, content_key, sha256) VALUES (987654, 1, 0, x'01', x'02')
            """)
        }
        let killed = FileOperations(index: index, paths: paths)
        killed.interruption.withLock { $0 = .afterStep(0) }
        let preview = try await killed.renamePreview(
            NamingTemplate(parsing: "Renamed-{sequence}"),
            photos: rows.map(\.id),
        )
        let batch = try await killed.planRename(preview)
        await #expect(throws: FileOperations.ForcedQuit.self) { try await killed.run(batch) }
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".JPG") }
        #expect(Set(left) != ["A.JPG", "B.JPG", "C.JPG"] && Set(left).count == 3, "cut short partway: \(left)")
        await index.close()

        let (library, service) = launch()
        defer { service.close() }
        try await eventually { await service.canShow(root, includingSubfolders: true) }
        let core = try #require(service.core)
        let entries = try await core.files.entries()
        #expect(entries.map(\.state) == [.finished], "the batch was finished: \(entries.map(\.state))")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
        #expect(Set(names.filter { !$0.hasSuffix(".redlamp") }) == ["Renamed-1.JPG", "Renamed-2.JPG", "Renamed-3.JPG"])
        let new = ["Renamed-1.JPG", "Renamed-2.JPG", "Renamed-3.JPG"].map { LibraryService.path(photo($0)) }
        let renamed = try await core.index.read { reader in try new.compactMap { try reader.photo(path: $0) } }
        #expect(Set(renamed.map(\.id)) == Set(rows.map(\.id)), "each photo keeps its row")
        #expect(try await core.index.read { try $0.photoCount() } == 3, "and no other row was made")
        for row in renamed {
            let original = try #require(rows.first { $0.id == row.id }).name
            let metadata = SidecarStore().load(for: photo(row.name))?.metadata
            #expect(metadata?.originalName == original, "\(row.name) records that it was \(original)")
            #expect(metadata?.rating == (original == "A.JPG" ? 3 : 0), "A's sidecar went with it")
        }
        let hashes = try await core.index.read { reader in
            try reader.database.prepare("SELECT count(*) FROM photo_hashes WHERE photo = 987654").first {
                $0.int(at: 0)
            }
        }
        #expect(hashes == 0, "the hashes nothing can bring back are swept")
        library.open(root)
        try await eventually { library.isShownFromLibrary && !library.isListing }
        #expect(library.items.map(\.name) == ["Renamed-1.JPG", "Renamed-2.JPG", "Renamed-3.JPG"])
    }
}

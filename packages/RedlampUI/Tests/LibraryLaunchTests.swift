import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The library at launch: its roots current once change tracking has caught up with their volume, and
/// not after a pass that ended offline.
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
}

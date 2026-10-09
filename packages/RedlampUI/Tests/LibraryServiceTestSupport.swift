import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization
@_spi(Harness) @testable import RedlampUI

/// How a test's scratch folder of photos and libraries is removed.
@MainActor
enum LibrarySandbox {
    /// The folders whose libraries' indexes are closing, still to go.
    private nonisolated static let going = Mutex<Set<URL>>([])

    /// Closes `services` as the app does when it quits, then removes `base` once their indexes have closed, the work
    /// queued on them done, so that SQLite's files don't go while they're open and no snapshot of an index makes the
    /// folder again: the photos first, so that a thumbnail the indexer queued for one finds it gone and writes nothing,
    /// then the libraries' folders, and the whole folder again once no thumbnail is being made, as one made as the
    /// photos went may still be written into it. A folder still to go as the tests end goes as they exit.
    static func remove(_ base: URL, closing services: [LibraryService?]) {
        let libraries = services.compactMap(\.self)
        let indexes = libraries.compactMap { $0.core?.index }
        let kept = Set(libraries.map(\.paths.root.standardizedFileURL.path))
        for library in libraries {
            library.close()
        }
        _ = removingAtExit
        going.withLock { _ = $0.insert(base) }
        Task.detached(priority: .userInitiated) {
            for index in indexes {
                await index.close()
            }
            let contents = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil))
                ?? []
            for item in contents where !kept.contains(item.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: item)
            }
            try? FileManager.default.removeItem(at: base)
            await thumbnailsMade()
            try? FileManager.default.removeItem(at: base)
            going.withLock { _ = $0.remove(base) }
        }
    }

    /// Removes the folders still to go as the process exits.
    private nonisolated static let removingAtExit: Void = {
        atexit {
            for folder in LibrarySandbox.going.withLock({ $0 }) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }()

    /// Returns once no thumbnail is being made, by the indexer or for the views, or after 10 s.
    private nonisolated static func thumbnailsMade() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, [LibraryIndexer.scheduler, WorkScheduler.shared].contains(where: {
            $0.load().running.values.contains { $0 > 0 }
        }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

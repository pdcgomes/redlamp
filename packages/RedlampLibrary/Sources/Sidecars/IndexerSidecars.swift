import Foundation
import RedlampDocument
import Synchronization

/// The sidecar locator each indexer run reads sidecars through: made the first time the run reads
/// one, after probing the roots that haven't been (`LibrarySidecars.choosePlacements`), so a run
/// sees the roots' placements as they were when it started reading.
enum IndexerSidecars {
    private struct Entry {
        weak var run: AnyObject?
        let locator: Task<SidecarLocator, Never>
    }

    private static let entries = Mutex<[ObjectIdentifier: Entry]>([:])

    static func locator(for run: some AnyObject & Sendable, index: LibraryIndex) async -> SidecarLocator {
        let task = entries.withLock { entries -> Task<SidecarLocator, Never> in
            let key = ObjectIdentifier(run)
            if let entry = entries[key], entry.run === run {
                return entry.locator
            }
            entries = entries.filter { $0.value.run != nil }
            let task = Task {
                let sidecars = LibrarySidecars(index: index)
                _ = try? await sidecars.choosePlacements()
                return await (try? sidecars.locator()) ?? .besidePhotos
            }
            entries[key] = Entry(run: run, locator: task)
            return task
        }
        return await task.value
    }
}

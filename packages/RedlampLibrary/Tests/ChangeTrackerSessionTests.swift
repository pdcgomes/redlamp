import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

/// What a session of change tracking leaves going once the next starts (LIB-08): Folders changing restarts it.
struct ChangeTrackerSessionTests {
    @Test func `a session replaced while its volumes are still being found follows none of them`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 20, seed: 48))
        defer { sandbox.remove() }
        let folders = try Self.folders(["Kept", "Dropped"], in: sandbox)
        let (kept, dropped) = (folders[0], folders[1])
        let files = LookupHoldingFileSystem()
        let finding = files.hold(lookupOf: dropped)
        defer { finding.release() }
        let tracker = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing()),
            configuration: .testing, source: ScriptedEvents(),
        )
        defer { tracker.stop() }
        _ = tracker.start([kept, dropped])
        let replaced = tracker.state.withLock { $0.tasks }
        #expect(await Self.eventually { finding.reached.fired })

        let events = TrackerEvents(tracker.start([kept]))
        let followed = [[LibraryIndexer.path(kept)]]
        #expect(await Self.eventually { tracker.followedRoots == followed })
        finding.release()
        for task in replaced {
            await task.value
        }
        #expect(await Self.eventually { tracker.isIdle })
        #expect(tracker.followedRoots == followed)
        #expect(try await sandbox.index.read { try $0.roots().map(\.path) } == [LibraryIndexer.path(kept)])
        #expect(await events.wait { $0.contains(where: Self.isCaughtUp) })
    }

    @Test func `a session's worker still running as the next session starts takes none of its work`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 20, seed: 49))
        defer { sandbox.remove() }
        let root = try Self.folders(["Followed"], in: sandbox)[0]
        let files = LookupHoldingFileSystem()
        // The first lookup is the session finding the volume; the second, its comparison's run, which the worker
        // waits on.
        var held = files.hold(lookupOf: root, skipping: 1)
        let tracker = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, fileSystem: files, configuration: .testing()),
            configuration: .testing, source: ScriptedEvents(),
        )
        defer { tracker.stop() }
        var events = TrackerEvents(tracker.start([root]))
        for session in 1 ... 8 {
            guard await Self.eventually({ held.reached.fired }) else {
                Issue.record("session \(session)'s comparison never ran")
                break
            }
            let next = files.hold(lookupOf: root, skipping: 1)
            events = TrackerEvents(tracker.start([root]))
            held.release()
            held = next
        }
        held.release()
        #expect(await events.wait(timeout: .seconds(10)) { $0.contains(where: Self.isCaughtUp) })
    }

    /// Folders `names` below the sandbox's root, each with a photo.
    static func folders(_ names: [String], in sandbox: IndexerSandbox) throws -> [URL] {
        try names.map { name in
            let folder = sandbox.root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ChangeTrackerTests.add("A.JPG", to: name, in: sandbox)
            return folder
        }
    }

    /// Waits until `condition` holds; false when it doesn't within `timeout`.
    static func eventually(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    static func isCaughtUp(_ event: ChangeTracker.Event) -> Bool {
        if case .caughtUp = event {
            true
        } else {
            false
        }
    }
}

extension ChangeTracker {
    /// The roots of each volume followed.
    var followedRoots: [[String]] {
        state.withLock { $0.volumes.values.map(\.roots) }
    }

    /// Nothing waits to run, and the worker waits for more.
    var isIdle: Bool {
        state.withLock { $0.pending.items.isEmpty && $0.waiter != nil }
    }
}

/// The local file system, holding a lookup of the volume of one folder, on its thread, until the test releases it.
final class LookupHoldingFileSystem: LibraryFileSystem {
    final class Hold: Sendable {
        let reached = Signal()
        private let released = DispatchSemaphore(value: 0)

        func release() {
            released.signal()
        }

        fileprivate func wait() {
            reached.fire()
            released.wait()
        }
    }

    private struct Waiting {
        let path: String
        var skipping: Int
        let hold: Hold
    }

    private let base = LocalFileSystem()
    private let waiting = Mutex<Waiting?>(nil)

    /// Holds the lookup of the volume of `folder` that comes after `skipping` others of it, until the hold returned
    /// is released. One hold waits at a time.
    func hold(lookupOf folder: URL, skipping: Int = 0) -> Hold {
        let hold = Hold()
        waiting.withLock { $0 = Waiting(path: LibraryIndexer.path(folder), skipping: skipping, hold: hold) }
        return hold
    }

    func volume(of url: URL) throws -> VolumeInfo {
        let hold = waiting.withLock { waiting -> Hold? in
            guard var current = waiting, current.path == LibraryIndexer.path(url) else { return nil }
            guard current.skipping == 0 else {
                current.skipping -= 1
                waiting = current
                return nil
            }
            waiting = nil
            return current.hold
        }
        hold?.wait()
        return try base.volume(of: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        try base.read(url, range: range)
    }
}

import Foundation
import Synchronization
import Testing
@testable import RedlampDocument

/// The FSEvents stream behind Folders' live updates (`FolderWatcher`): a change reported, none once it's stopped,
/// and streams replaced as fast as they're made while their folder changes, as Folders replaces its stream each
/// time a root comes or goes.
struct FolderWatcherTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "watcher-\(UUID().uuidString)")

    private func write(_ name: String) throws {
        try Data(name.utf8).write(to: folder.appending(path: name))
    }

    @Test func `a change is reported, and none once the watcher has stopped`() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reported = Mutex<[String]>([])
        let watcher = FolderWatcher(paths: [folder.path], latency: 0.05) { directories in
            reported.withLock { $0 += directories }
        }
        // The stream starts on the watchers' queue: a change is reported once it has.
        for number in 0 ..< 100 where reported.withLock({ $0.isEmpty }) {
            try write("before-\(number)")
            try await Task.sleep(for: .milliseconds(100))
        }
        let name = folder.lastPathComponent
        let changed = reported.withLock { $0 }
        #expect(changed.contains { $0.hasSuffix(name) }, "\(changed)")

        watcher.stop()
        try await Task.sleep(for: .milliseconds(500))
        reported.withLock { $0 = [] }
        for number in 0 ..< 5 {
            try write("after-\(number)")
        }
        try await Task.sleep(for: .seconds(1))
        let late = reported.withLock { $0 }
        #expect(late.isEmpty, "\(late)")
    }

    @Test func `watchers replaced as fast as they're made while their folder changes report nothing once stopped`(
    ) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = Atomic(0)
        var watcher: FolderWatcher?
        for round in 0 ..< 100 {
            let made = FolderWatcher(paths: [folder.path], latency: 0) { _ in
                reports.wrappingAdd(1, ordering: .relaxed)
            }
            try write("photo-\(round % 20)")
            // Now and then one runs until it reports, so those stopped have callbacks under way.
            let before = reports.load(ordering: .relaxed)
            for number in 0 ..< (round % 25 == 0 ? 100 : 0) where reports.load(ordering: .relaxed) == before {
                try write("running-\(number)")
                try await Task.sleep(for: .milliseconds(30))
            }
            // The one it replaces stops and goes at once.
            watcher?.stop()
            watcher = made
            try await Task.sleep(for: .milliseconds(round % 3 == 0 ? 0 : 5))
        }
        watcher?.stop()
        watcher = nil
        let reported = reports.load(ordering: .relaxed)
        #expect(reported > 0, "the watchers that ran reported changes")

        // A watcher made after every stop reports a change only once the queue has stopped them all.
        let probed = Atomic(false)
        let probe = FolderWatcher(paths: [folder.path], latency: 0) { _ in probed.store(true, ordering: .relaxed) }
        for number in 0 ..< 300 where !probed.load(ordering: .relaxed) {
            try write("probe-\(number)")
            try await Task.sleep(for: .milliseconds(100))
        }
        let started = probed.load(ordering: .relaxed)
        #expect(started)
        probe.stop()
        let settled = reports.load(ordering: .relaxed)
        for number in 0 ..< 5 {
            try write("after-\(number)")
        }
        try await Task.sleep(for: .seconds(1))
        let after = reports.load(ordering: .relaxed)
        #expect(after == settled, "a stopped watcher reported a change")
    }
}

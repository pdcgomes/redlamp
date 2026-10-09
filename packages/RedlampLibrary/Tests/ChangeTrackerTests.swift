import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

struct ChangeTrackerTests {
    /// The index's name for the sandbox's volume, once it has indexed it.
    static func volumeKey(_ sandbox: IndexerSandbox) async throws -> String {
        try #require(try await sandbox.index.read { try $0.volumes().first?.uuid })
    }

    /// A photo copied into `folder` under `name`, from another of the fixture's.
    static func add(_ name: String, to folder: String, in sandbox: IndexerSandbox) throws {
        let source = try #require((0 ..< sandbox.manifest.totals.photos).map(sandbox.fixture.photo(at:)).first {
            $0.kind == .jpeg && FileManager.default.fileExists(atPath: sandbox.url($0).path)
        })
        try FileManager.default.copyItem(at: sandbox.url(source), to: sandbox.root.appending(path: folder + "/" + name))
    }

    /// The volume's history once `condition` holds for it: the tracker records it after its run.
    static func history(
        of key: String, in sandbox: IndexerSandbox, when condition: (VolumeEventHistory?) -> Bool,
    ) async throws -> VolumeEventHistory? {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let history = try await sandbox.index.read { try $0.eventHistory(ofVolume: key) }
            if condition(history) || ContinuousClock.now > deadline {
                return history
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The row at `path` once the index has it.
    static func row(at path: String, in sandbox: IndexerSandbox) async throws -> PhotoRecord? {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let row = try await sandbox.index.read({ try $0.photo(path: path) }) {
                return row
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// The first `count` of the fixture's folders that hold at least three photos.
    static func folders(in sandbox: IndexerSandbox, count: Int) throws -> [LibraryFixture.Folder] {
        let folders = sandbox.fixture.folders.filter { $0.photos.count >= 3 }
        try #require(folders.count >= count)
        return Array(folders.prefix(count))
    }

    static func isReplayed(_ event: ChangeTracker.Event) -> Bool {
        if case .replayed = event {
            true
        } else {
            false
        }
    }

    static func isChanged(_ event: ChangeTracker.Event) -> Bool {
        if case .changed = event {
            true
        } else {
            false
        }
    }

    static func isPoll(shown: Bool) -> (ChangeTracker.Event) -> Bool {
        { event in
            if case let .polled(_, wasShown) = event {
                wasShown == shown
            } else {
                false
            }
        }
    }

    static func reconciled(_ reason: ChangeTracker.Reason) -> (ChangeTracker.Event) -> Bool {
        { event in
            if case .reconciled(_, reason) = event {
                true
            } else {
                false
            }
        }
    }

    /// Where in `events` each `.caughtUp` of `key` came.
    static func caughtUp(_ key: String, in events: [ChangeTracker.Event]) -> [Int] {
        events.indices.filter { events[$0] == .caughtUp(volume: key) }
    }

    /// Where the first run to finish after `start` finished.
    static func finished(after start: Int, in events: [ChangeTracker.Event]) -> Int? {
        events[start...].firstIndex {
            if case .indexer(.finished) = $0 {
                true
            } else {
                false
            }
        }
    }

    // MARK: - Event histories

    @Test func `FSEvents replays what changed while the tracker was stopped and follows what changes while it runs`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 41, shapes: [.clients]))
        defer { sandbox.remove() }
        let picked = try Self.folders(in: sandbox, count: 4)
        let folders = picked.map(\.path)
        let first = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, configuration: .testing()), configuration: .testing,
        )
        let events = TrackerEvents(first.start([sandbox.root]))
        // No history recorded: every folder is compared by signature, and the history is recorded.
        let initial = await events.summary(after: Self.reconciled(.historyGone))
        #expect(initial?.photosInserted == 300)
        let key = try await Self.volumeKey(sandbox)
        let recorded = try #require(try await Self.history(of: key, in: sandbox) { $0 != nil })
        let device = try #require(FSEventsSource().locate(sandbox.rootPath)).device
        #expect(recorded.eventDatabase == FSEventsSource().eventDatabase(of: device))

        try Self.add("Live.JPG", to: folders[0], in: sandbox)
        #expect(try await Self.row(at: sandbox.path(folders[0] + "/Live.JPG"), in: sandbox) != nil)
        #expect(events.all.contains(where: Self.isChanged), "\(events.all)")
        let afterLive = try await Self.history(of: key, in: sandbox) { ($0?.lastEvent ?? 0) > recorded.lastEvent }
        first.stop()
        #expect((afterLive?.lastEvent ?? 0) > recorded.lastEvent)

        // Changed while no tracker runs: a photo renamed, one removed and one added, in three folders,
        // all in the device's history before the next tracker starts.
        let probe = FSEventsProbe(sandbox.rootPath)
        let before = try await LibraryIndexerTests.rows(sandbox)
        let renamed = try #require(sandbox.fixture.photos(in: picked[1]).first {
            $0.sidecar == nil && $0.xmp == nil
        })
        try FileManager.default.moveItem(
            at: sandbox.url(renamed), to: sandbox.root.appending(path: folders[1] + "/Renamed " + renamed.name),
        )
        let removed = try #require(sandbox.fixture.photos(in: picked[2]).first { $0.sidecar == nil })
        try FileManager.default.removeItem(at: sandbox.url(removed))
        try Self.add("Added.JPG", to: folders[3], in: sandbox)
        #expect(await probe.saw(folders[1 ... 3].map(sandbox.path)))

        let counting = CountingFileSystem()
        let second = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing()),
            configuration: .testing,
        )
        let replay = TrackerEvents(second.start([sandbox.root]))
        let summary = await replay.summary(after: Self.isReplayed)
        second.stop()
        #expect(replay.all.count(of: Self.reconciled(.historyGone)) == 0)
        #expect(summary?.photosMoved == 1 && summary?.photosRemoved == 1 && summary?.photosInserted == 1)
        #expect(summary?.headsRead == 1)
        // Only the folders the history named are listed.
        let listed = Set(counting.counts.listings.keys)
        let changed = Set(folders[0 ... 3].map(sandbox.path))
        #expect(listed.isSubset(of: changed) && listed.isSuperset(of: Set(folders[1 ... 3].map(sandbox.path))))
        let after = try await LibraryIndexerTests.rows(sandbox)
        #expect(after[sandbox.path(folders[1] + "/Renamed " + renamed.name)]?.id == before[sandbox.path(renamed.path)]?
            .id)
        #expect(after[sandbox.path(removed.path)] == nil && after[sandbox.path(folders[3] + "/Added.JPG")] != nil)
        #expect(after.count == 301)
    }

    @Test func `a replayed history names the folders that changed, and a live event its folder`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 42, shapes: [.clients]))
        defer { sandbox.remove() }
        _ = await IndexerRun
            .collect(LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]))
        let key = try await Self.volumeKey(sandbox)
        try await sandbox.index.write {
            try $0.setEventHistory(VolumeEventHistory(eventDatabase: "SCRIPTED", lastEvent: 1000), ofVolume: key)
        }
        let source = ScriptedEvents()
        let picked = try Self.folders(in: sandbox, count: 2)
        let folders = picked.map(\.path)
        try Self.add("Added.JPG", to: folders[0], in: sandbox)
        source.record([
            (sandbox.path(folders[0]), []), ((sandbox.rootPath as NSString).deletingLastPathComponent, []),
        ])

        let counting = CountingFileSystem()
        let tracker = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing()),
            configuration: .testing, source: source,
        )
        let events = TrackerEvents(tracker.start([sandbox.root]))
        defer { tracker.stop() }
        let replayed = await events.summary(after: Self.isReplayed)
        #expect(events.all.contains(.replayed(volume: key, folders: 1)), "\(events.all)")
        #expect(replayed?.photosInserted == 1 && source.since == [1000])
        #expect(Set(counting.counts.listings.keys) == [sandbox.path(folders[0])])
        #expect(try await Self.history(of: key, in: sandbox) { $0?.lastEvent == 1002 }?.lastEvent == 1002)
        // The replay is the volume's first pass.
        #expect(await events.wait { $0.contains(.caughtUp(volume: key)) })
        let start = try #require(events.all.firstIndex(where: Self.isReplayed))
        let caught = Self.caughtUp(key, in: events.all)
        #expect(caught.count == 1 && Self.finished(after: start, in: events.all).map { $0 < caught[0] } == true)

        counting.reset()
        try FileManager.default.removeItem(at: sandbox.url(sandbox.fixture.photos(in: picked[1])[0]))
        source.send([(sandbox.path(folders[1]), [])])
        let live = await events.summary(after: { $0 == .changed(volume: key, folders: 1) })
        #expect(live?.photosRemoved == 1)
        #expect(Set(counting.counts.listings.keys) == [sandbox.path(folders[1])])
        #expect(try await Self.history(of: key, in: sandbox) { $0?.lastEvent == 1003 }?.lastEvent == 1003)
        #expect(Self.caughtUp(key, in: events.all).count == 1, "a live event doesn't catch it up again")
    }

    @Test func `a history that names nothing catches its volume up at once, with nothing listed`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 100, seed: 49, shapes: []))
        defer { sandbox.remove() }
        _ = await IndexerRun
            .collect(LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]))
        let key = try await Self.volumeKey(sandbox)
        try await sandbox.index.write {
            try $0.setEventHistory(VolumeEventHistory(eventDatabase: "SCRIPTED", lastEvent: 1000), ofVolume: key)
        }
        let counting = CountingFileSystem()
        let tracker = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing()),
            configuration: .testing, source: ScriptedEvents(),
        )
        let events = TrackerEvents(tracker.start([sandbox.root]))
        defer { tracker.stop() }
        #expect(await events.wait { $0.contains(.caughtUp(volume: key)) })
        #expect(events.all == [.replayed(volume: key, folders: 0), .caughtUp(volume: key)], "\(events.all)")
        #expect(counting.counts.listings.isEmpty)
    }

    @Test func `dropped events, or another event database, compare every folder by signature`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 43, shapes: [.clients]))
        defer { sandbox.remove() }
        _ = await IndexerRun
            .collect(LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]))
        let key = try await Self.volumeKey(sandbox)
        try await sandbox.index.write {
            try $0.setEventHistory(VolumeEventHistory(eventDatabase: "SCRIPTED", lastEvent: 1000), ofVolume: key)
        }
        let source = ScriptedEvents()
        let folderCount = sandbox.manifest.totals.folders + 1
        let picked = try Self.folders(in: sandbox, count: 2)
        try FileManager.default.removeItem(at: sandbox.url(sandbox.fixture.photos(in: picked[0])[0]))
        source.record([(sandbox.rootPath, [.mustScanSubfolders, .dropped])])

        let counting = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing())
        var tracker = ChangeTracker(indexer: indexer, configuration: .testing, source: source)
        var events = TrackerEvents(tracker.start([sandbox.root]))
        let dropped = await events.summary(after: Self.reconciled(.mustScan))
        #expect(try await Self.history(of: key, in: sandbox) { $0?.lastEvent == 1001 }?.lastEvent == 1001)
        tracker.stop()
        #expect(dropped?.photosRemoved == 1 && counting.counts.listed == folderCount, "\(events.all)")

        // The volume's history is another than the one recorded against: it's compared again, and the
        // new one recorded.
        counting.reset()
        source.database = "ANOTHER"
        try Self.add("Added.JPG", to: picked[1].path, in: sandbox)
        tracker = ChangeTracker(indexer: indexer, configuration: .testing, source: source)
        events = TrackerEvents(tracker.start([sandbox.root]))
        let gone = await events.summary(after: Self.reconciled(.historyGone))
        let expected = VolumeEventHistory(eventDatabase: "ANOTHER", lastEvent: source.currentEvent)
        let history = try await Self.history(of: key, in: sandbox) { $0 == expected }
        tracker.stop()
        #expect(gone?.photosInserted == 1 && counting.counts.listed == folderCount)
        #expect(source.since.last == source.currentEvent)
        #expect(history == expected)
    }

    @Test func `a folder whose subfolders must be scanned is listed with everything below it`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 200, seed: 44, shapes: [.deepTree]))
        defer { sandbox.remove() }
        _ = await IndexerRun
            .collect(LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]))
        let key = try await Self.volumeKey(sandbox)
        try await sandbox.index.write {
            try $0.setEventHistory(VolumeEventHistory(eventDatabase: "SCRIPTED", lastEvent: 1000), ofVolume: key)
        }
        let level = "Archive/Level 2/Level 3/Level 4/Level 5/Level 6"
        try Self.add("Added.JPG", to: level + "/Level 7/Level 8", in: sandbox)
        let source = ScriptedEvents()
        source.record([(sandbox.path(level), .mustScanSubfolders)])
        let counting = CountingFileSystem()
        let tracker = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing()),
            configuration: .testing, source: source,
        )
        let events = TrackerEvents(tracker.start([sandbox.root]))
        defer { tracker.stop() }
        let summary = await events.summary(after: Self.isReplayed)
        #expect(summary?.photosInserted == 1)
        let listed = counting.counts.listings.keys.sorted()
        #expect(listed.count == 7 && listed.allSatisfy { $0.hasPrefix(sandbox.path(level)) }, "\(listed)")
    }

    @Test func `events are mapped to the folders they name below each root`() {
        let roots = [(root: "/Volumes/Card/DCIM", onDevice: "DCIM"), (root: "/Volumes/Card", onDevice: "")]
        let batch = ChangeTracker.batch([
            VolumeEvent(path: "DCIM/100CANON", id: 7),
            VolumeEvent(path: "MISC", flags: .mustScanSubfolders, id: 9),
            VolumeEvent(path: "", flags: .historyDone, id: 8),
        ], roots: roots)
        #expect(batch.changes == [
            "/Volumes/Card/DCIM/100CANON": false, "/Volumes/Card/MISC": true,
        ] && batch.last == 9 && batch.historyDone && !batch.lost)

        let photos = [(root: "/Users/me/Pictures", onDevice: "Users/me/Pictures")]
        let above = ChangeTracker.batch([VolumeEvent(path: "Users/me", id: 1)], roots: photos)
        #expect(above.changes.isEmpty && !above.lost)
        let sibling = ChangeTracker.batch([VolumeEvent(path: "Users/me/Pictures 2", id: 1)], roots: photos)
        #expect(sibling.changes.isEmpty && !sibling.lost)
        let coalescedAbove = ChangeTracker.batch(
            [VolumeEvent(path: "Users/me", flags: .mustScanSubfolders, id: 1)], roots: photos,
        )
        #expect(coalescedAbove.lost)
        let atRoot = ChangeTracker.batch([VolumeEvent(path: "Users/me/Pictures", id: 1)], roots: photos)
        #expect(atRoot.changes == ["/Users/me/Pictures": false])
        for flags: VolumeEvent.Flags in [.dropped, .rootChanged, .idsWrapped] {
            #expect(ChangeTracker.batch([VolumeEvent(path: "Users/me/Pictures", flags: flags, id: 1)], roots: photos)
                .lost)
        }
    }

    @Test func `work waiting for a volume is merged, and a comparison takes in the updates and polls before it`() {
        func volume(_ key: String) -> ChangeTracker.Followed {
            let info = VolumeInfo(uuid: key, name: nil, isLocal: true, isInternal: true)
            return ChangeTracker.Followed(
                key: key, io: VolumeIO(volume: info, fileSystem: LocalFileSystem(), probe: URL(fileURLWithPath: "/")),
                roots: ["/" + key],
            )
        }
        func history(_ event: UInt64, _ database: String = "D") -> VolumeEventHistory {
            VolumeEventHistory(eventDatabase: database, lastEvent: event)
        }
        let (a, b) = (volume("A"), volume("B"))
        var pending = ChangeTracker.PendingWork()
        #expect(pending.add(.init(a, .update(["/A/1": false], replayed: true), record: history(5))).isEmpty)
        #expect(pending.add(.init(b, .poll(shown: true))).isEmpty)
        #expect(pending.add(.init(a, .update(["/A/2": true, "/A/1": true], replayed: false), record: history(7)))
            .count == 1)
        #expect(pending.add(.init(b, .poll(shown: true))).count == 1)
        #expect(pending.items.count == 2)
        guard case let .update(changes, replayed) = pending.items[0].kind else {
            Issue.record("\(pending.items[0].kind)")
            return
        }
        #expect(changes == ["/A/1": true, "/A/2": true] && replayed && pending.items[0].record == history(7))

        #expect(pending.add(.init(a, .reconcile(.mustScan), record: history(6))).count == 1)
        #expect(pending.items.map(\.volume.key) == ["B", "A"])
        #expect(pending.items[1].kind.isReconcile && pending.items[1].record == history(7))
        #expect(pending.add(.init(a, .update(["/A/3": false], replayed: false), record: history(9))).count == 1)
        #expect(pending.add(.init(a, .poll(shown: false))).count == 1)
        #expect(pending.add(.init(a, .offline)).isEmpty && pending.add(.init(a, .offline)).count == 1)
        #expect(pending.items.count == 3 && pending.items[1].record == history(9))
        #expect(pending.next()?.volume.key == "B" && pending.next()?.kind.isReconcile == true)

        #expect(ChangeTracker.PendingWork.later(history(9), history(3, "E")) == history(3, "E"))
        #expect(ChangeTracker.PendingWork.later(history(9), history(3)) == history(9))
        #expect(ChangeTracker.PendingWork.later(nil, history(3)) == history(3))
    }
}

extension ChangeTrackerTests {
    // MARK: - Network volumes

    /// A tracker polling a simulated network volume of 120 photos, with its first folder on screen.
    static func pollingTracker(of sandbox: IndexerSandbox) -> ChangeTracker {
        let indexer = LibraryIndexer(
            index: sandbox.index, fileSystem: SimulatedFileSystem(profile: .nas, seed: 4), configuration: .testing(),
        )
        let tracker = ChangeTracker(
            indexer: indexer,
            configuration: .init(
                shownInterval: .milliseconds(100),
                pollIntervals: .milliseconds(200) ... .milliseconds(800),
            ),
            source: ScriptedEvents(),
        )
        tracker.show([sandbox.root.appending(path: sandbox.fixture.folders[0].path)])
        return tracker
    }

    @Test func `a network volume's folders are polled, a photo added on screen is found, and none in the background`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 120, seed: 45, shapes: []))
        defer { sandbox.remove() }
        let tracker = Self.pollingTracker(of: sandbox)
        let events = TrackerEvents(tracker.start([sandbox.root]))
        defer { tracker.stop() }
        let initial = await events.summary(after: Self.reconciled(.network))
        #expect(initial?.photosInserted == 120)
        #expect(await events.wait { $0.count(of: Self.isPoll(shown: false)) >= 4 })
        #expect(events.all.count(of: Self.isPoll(shown: true)) >= 5)

        // A photo added to the folder on screen is found by the next poll of it.
        try Self.add("Added.JPG", to: sandbox.fixture.folders[0].path, in: sandbox)
        let started = events.all.count
        #expect(await events.wait(timeout: .seconds(10)) { all in
            all.dropFirst(started).contains {
                if case .indexer(.photosInserted) = $0 {
                    true
                } else {
                    false
                }
            }
        })

        // A poll under way as the app goes to the background finishes; none starts after it.
        tracker.setActive(false)
        try await Task.sleep(for: .seconds(1))
        let paused = events.all.count(of: Self.isPoll(shown: true)) + events.all.count(of: Self.isPoll(shown: false))
        try await Task.sleep(for: .seconds(1))
        let later = events.all.count(of: Self.isPoll(shown: true)) + events.all.count(of: Self.isPoll(shown: false))
        #expect(later == paused)
        tracker.setActive(true)
        #expect(await events.wait { $0.count(of: Self.isPoll(shown: true)) > paused })
    }

    @Test(.measuresSpeed)
    func `a network volume's folders off screen are polled with backoff, and those on screen at once when active`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 120, seed: 45, shapes: []))
        defer { sandbox.remove() }
        let tracker = Self.pollingTracker(of: sandbox)
        let events = TrackerEvents(tracker.start([sandbox.root]))
        defer { tracker.stop() }
        _ = await events.summary(after: Self.reconciled(.network))
        #expect(await events.wait { $0.count(of: Self.isPoll(shown: false)) >= 4 })
        let full = events.times(of: Self.isPoll(shown: false))
        try #require(full.count >= 4)
        let gaps = zip(full.dropFirst(), full).map { $0 - $1 }
        #expect(gaps[1] > gaps[0] + .milliseconds(200) && gaps[2] > .milliseconds(700), "\(gaps)")

        tracker.setActive(false)
        try await Task.sleep(for: .seconds(1))
        let paused = events.all.count(of: Self.isPoll(shown: true))
        tracker.setActive(true)
        let resumed = ContinuousClock.now
        #expect(await events.wait { $0.count(of: Self.isPoll(shown: true)) > paused })
        #expect(ContinuousClock.now - resumed < .seconds(1))
    }

    @Test func `each simulated volume's first pass is over once, after its run, however often it's polled after`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 120, seed: 47, shapes: []))
        defer { sandbox.remove() }
        let second = try TemporaryFolder()
        let copied = sandbox.fixture.photos(in: sandbox.fixture.folders[0]).prefix(5)
        for photo in copied {
            try FileManager.default.copyItem(at: sandbox.url(photo), to: second.url.appending(path: photo.name))
        }
        let simulated = SimulatedFileSystem(profile: .nas, seed: 5)
        simulated.mount(second.url, uuid: "SECOND-VOLUME")
        let tracker = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, fileSystem: simulated, configuration: .testing()),
            configuration: .init(
                shownInterval: .milliseconds(100), pollIntervals: .milliseconds(100) ... .milliseconds(200),
            ),
            source: ScriptedEvents(),
        )
        let events = TrackerEvents(tracker.start([sandbox.root, second.url]))
        defer { tracker.stop() }
        let keys = try [
            VolumeIORegistry.key(for: simulated.volume(of: sandbox.root), probe: sandbox.root),
            "SECOND-VOLUME",
        ]
        #expect(await events.wait { all in
            keys.allSatisfy { key in all.count(of: { $0 == .polled(volume: key, shown: false) }) >= 2 }
        }, "every folder of both volumes polled twice after their first passes")
        tracker.stop()

        let all = events.all
        for (key, photos) in zip(keys, [120, copied.count]) {
            let caught = Self.caughtUp(key, in: all)
            let start = try #require(all.firstIndex(of: .reconciled(volume: key, reason: .network)))
            let finished = try #require(Self.finished(after: start, in: all))
            #expect(caught.count == 1 && caught[0] > finished, "\(key): \(all)")
            guard case let .indexer(.finished(summary)) = all[finished] else { continue }
            #expect(summary.photosInserted == photos, "\(key)'s first pass indexed all of it")
            let polled = try #require(all.firstIndex(of: .polled(volume: key, shown: false)))
            #expect(caught[0] < polled)
        }
    }

    @Test func `a volume that stops answering is marked offline without hanging, and compared again when it's back`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 46, shapes: []))
        defer { sandbox.remove() }
        // The volume's own timeouts, of 30 s, stay well beyond the 10 s a pass may take, so one that waits fails.
        let gone = VolumeProfile.nas.disconnecting(.init(.afterOperations(150), failure: .timeout(.seconds(30))))
        let volume = SwitchingFileSystem(SimulatedFileSystem(profile: gone, seed: 1))
        let volumes = VolumeIORegistry(fileSystem: volume, configuration: .init(
            timeout: .milliseconds(300), probeIntervals: .milliseconds(100) ... .milliseconds(400),
        ))
        let tracker = ChangeTracker(
            indexer: LibraryIndexer(index: sandbox.index, volumes: volumes, configuration: .testing(batchSize: 50)),
            configuration: .init(shownInterval: .seconds(60), pollIntervals: .seconds(60) ... .seconds(60)),
            source: ScriptedEvents(),
        )
        let started = ContinuousClock.now
        let events = TrackerEvents(tracker.start([sandbox.root]))
        defer { tracker.stop() }
        let first = await events.summary(after: Self.reconciled(.network))
        #expect(ContinuousClock.now - started < .seconds(10))
        let key = try #require(first?.offlineVolumes.first)
        #expect(events.all.contains(.indexer(.volumeOffline(key))))
        let (offline, written) = try await sandbox.index
            .read { try ($0.photoCount(withState: .offline), $0.photoCount()) }
        #expect(written > 0 && written < 300 && offline == written, "\(offline) of \(written)")
        #expect(Self.caughtUp(key, in: events.all).isEmpty, "a first pass the volume left isn't over")

        volume.switchTo(SimulatedFileSystem(profile: .nas, seed: 2))
        let back = await events.summary(after: Self.reconciled(.reconnected))
        #expect(back?.offlineVolumes.isEmpty == true && events.all.contains(.indexer(.volumeOnline(key))))
        let (stillOffline, count) = try await sandbox.index.read {
            try ($0.photoCount(withState: .offline), $0.photoCount())
        }
        #expect(stillOffline == 0 && count == 300)
        #expect(await events.wait { !Self.caughtUp(key, in: $0).isEmpty })
        let start = try #require(events.all.firstIndex(where: Self.reconciled(.reconnected)))
        let caught = Self.caughtUp(key, in: events.all)
        #expect(caught.count == 1 && Self.finished(after: start, in: events.all).map { $0 < caught[0] } == true)
    }
}

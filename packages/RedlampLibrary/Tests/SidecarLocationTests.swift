import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct SidecarLocationTests {
    /// `spec`'s fixture indexed, its sidecars beside its photos, and its root's ID.
    private static func indexed(_ spec: LibraryFixture.Spec) async throws -> (IndexerSandbox, LibrarySidecars, Int64) {
        let sandbox = try await IndexerSandbox.make(spec)
        let run = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]),
        )
        #expect(run.failures.isEmpty, "\(run.failures)")
        let rootPath = sandbox.rootPath
        let root = try #require(try await sandbox.index.read { try $0.root(path: rootPath) })
        return (sandbox, LibrarySidecars(index: sandbox.index), root.id)
    }

    /// Every `.redlamp` sidecar below `folder` by its photo's path below it, with each file in it and
    /// its bytes. Hidden files are left out.
    private static func sidecars(below folder: URL) throws -> [String: [String: Data]] {
        var found: [String: [String: Data]] = [:]
        for path in FileManager.default.subpaths(atPath: folder.path) ?? [] {
            let parts = path.split(separator: "/").map(String.init)
            guard !parts.contains(where: { $0.hasPrefix(".") }),
                  let end = parts.firstIndex(where: { $0.lowercased().hasSuffix(".redlamp") })
            else { continue }
            let photo = String(parts[...end].joined(separator: "/").dropLast(".redlamp".count))
            let url = folder.appending(path: path)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            found[photo, default: [:]][parts[(end + 1)...].joined(separator: "/")] = isDirectory.boolValue
                ? nil : try Data(contentsOf: url)
        }
        return found
    }

    /// Other apps' `.xmp` below `folder` by path, with their bytes.
    private static func otherApps(below folder: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        for path in FileManager.default.subpaths(atPath: folder.path) ?? [] where path.lowercased().hasSuffix(".xmp") {
            found[path] = try Data(contentsOf: folder.appending(path: path))
        }
        return found
    }

    /// What interrupted saves, moves and probes leave below `folder`: hidden names of sidecars.
    private static func leftovers(below folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).filter { path in
            path.split(separator: "/").contains { $0.hasPrefix(".") && $0.contains(".redlamp") }
        }
    }

    // MARK: - Choosing

    @Test func `a root Redlamp can't write in is kept on this Mac, chosen once, and probing leaves nothing behind`(
    ) async throws {
        let folder = try TemporaryFolder()
        let card = folder.url.appending(path: "Card Été", directoryHint: .isDirectory)
        let shoots = folder.url.appending(path: "Shoots", directoryHint: .isDirectory)
        let later = folder.url.appending(path: "Later", directoryHint: .isDirectory)
        for url in [card, shoots] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.appending(path: "IMG_0001.ARW"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: card.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.path) }
        let index = try await LibraryIndex.open(at: folder.url.appending(path: "Library/Index.sqlite"))
        defer { index.closeAndWait() }
        let (cardRoot, shootsRoot, laterRoot) = try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "VOLUME-1", name: "Test", kind: .ssd))
            return try (
                writer.upsertRoot(RootRecord(volume: volume, path: LibraryIndexer.path(card))),
                writer.upsertRoot(RootRecord(volume: volume, path: LibraryIndexer.path(shoots))),
                writer.upsertRoot(RootRecord(volume: volume, path: LibraryIndexer.path(later))),
            )
        }
        let sidecars = LibrarySidecars(index: index)
        #expect(sidecars.paths.sidecars.path == folder.url.appending(path: "Library/Sidecars").path)
        func listing(_ url: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }
        func placements() async throws -> [Int64: RootRecord.Sidecars] {
            try await index.read { reader in
                try Dictionary(uniqueKeysWithValues: reader.roots().map { ($0.id, $0.sidecars) })
            }
        }

        #expect(try await sidecars.choosePlacements() == [cardRoot])
        #expect(try await placements() == [cardRoot: .onThisMac, shootsRoot: .besidePhotos, laterRoot: .besidePhotos])
        #expect(try listing(card) == ["IMG_0001.ARW"] && listing(shoots) == ["IMG_0001.ARW"])

        // The card stays on this Mac once it can be written; a root that wasn't there is probed again.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.path)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: later.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: later.path) }
        #expect(try await sidecars.choosePlacements() == [laterRoot])
        #expect(try await sidecars.choosePlacements().isEmpty)
        #expect(try await placements() == [cardRoot: .onThisMac, shootsRoot: .besidePhotos, laterRoot: .onThisMac])
        #expect(try listing(later).isEmpty)

        // A placement the user sets stands.
        try await sidecars.setPlacement(.besidePhotos, forRoot: laterRoot)
        try await sidecars.setPlacement(.onThisMac, forRoot: shootsRoot)
        #expect(try await sidecars.choosePlacements().isEmpty)
        #expect(try await placements() == [cardRoot: .onThisMac, shootsRoot: .onThisMac, laterRoot: .besidePhotos])

        // Sidecars of roots on this Mac go by the volume and the root's path in it.
        let locator = try await sidecars.locator()
        let inVolume = try #require(LibrarySidecars.pathInVolume(of: card))
        #expect(!inVolume.hasPrefix("/") && inVolume.hasSuffix("Card Été"))
        let photo = card.appending(path: "100 MSDCF/IMG_0002.ARW")
        #expect(locator.url(for: photo).path
            == sidecars.paths.sidecars.appending(path: "VOLUME-1/\(inVolume)/100 MSDCF/IMG_0002.ARW.redlamp").path)
        let beside = later.appending(path: "IMG_0003.ARW")
        #expect(locator.url(for: beside) == beside.appendingPathExtension("redlamp"))
        await #expect(throws: LibrarySidecarsError.noSuchRoot(99)) { try await sidecars.setPlacement(
            .onThisMac,
            forRoot: 99,
        ) }
    }

    // MARK: - Indexing

    @Test func `the indexer reads a root's sidecars on this Mac without reading its photos again`() async throws {
        let (sandbox, sidecars, root) = try await Self.indexed(.init(photos: 200, seed: 51, shapes: []))
        defer { sandbox.remove() }
        let photos = (0 ..< 200).map(sandbox.fixture.photo(at:))
        let rated = photos.filter { $0.sidecar != nil }
        let first = try #require(rated.first)
        _ = try await sidecars.move(sidecars.planMove(ofRoot: root, to: .onThisMac))
        let store = try await SidecarStore(locator: sidecars.locator())
        #expect(store.url(for: sandbox.url(first)) != SidecarLocator.besidePhoto(sandbox.url(first)))
        var sidecar = try #require(store.load(for: sandbox.url(first)))
        let rating = first.rating == 5 ? 1 : 5
        sidecar.metadata = PhotoMetadata(rating: rating, flag: .pick, label: .green)
        try store.save(sidecar, for: sandbox.url(first))

        let counting = CountingFileSystem()
        let run = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing()).index([sandbox.root]),
        )
        #expect(run.failures.isEmpty && counting.counts.heads == 0)
        let rows = try await LibraryIndexerTests.rows(sandbox)
        for photo in rated {
            let row = try #require(rows[sandbox.path(photo.path)])
            if photo == first {
                #expect(row.rating == rating && row.flag == .pick && row.label == .green)
            } else {
                #expect(row.rating == photo.rating && row.flag == photo.flag && row.label == photo.label)
            }
            #expect(row.edited == photo.isEdited && row.sidecarModified != nil)
        }

        // A photo that arrives with its sidecar already on this Mac has it read there.
        let name = "Arrived/IMG_9999." + (first.name as NSString).pathExtension
        let copy = sandbox.root.appending(path: name)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sandbox.url(first), to: copy)
        try store.save(sidecar, for: copy)
        _ = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]),
        )
        let arrived = try #require(try await LibraryIndexerTests.rows(sandbox)[sandbox.path(name)])
        #expect(arrived.rating == rating && arrived.flag == .pick && arrived.label == .green && arrived.edited == first
            .isEdited)
    }

    // MARK: - Moving

    @Test func `moving a root's sidecars to this Mac and back keeps every byte, and other apps' xmp beside the photos`(
    ) async throws {
        let (sandbox, sidecars, root) = try await Self.indexed(.init(photos: 300, seed: 52))
        defer { sandbox.remove() }
        let totals = sandbox.manifest.totals
        let before = try Self.sidecars(below: sandbox.root)
        let xmps = try Self.otherApps(below: sandbox.root)
        #expect(before.count == totals.sidecars && xmps.count == totals.xmpSidecars && !xmps.isEmpty)
        #expect(try await sidecars.census(ofRoot: root) == SidecarCensus(
            root: sandbox.rootPath, placement: .besidePhotos, beside: totals.sidecars, onThisMac: 0, both: 0,
            otherApps: totals.xmpSidecars,
        ))
        let mac = try await LibrarySidecars.folder(of: sidecars.knownRoot(root).1, in: sidecars.paths.sidecars)

        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        #expect(plan.items.count == totals.sidecars && plan.conflicts.isEmpty && plan.destination == .onThisMac)
        #expect(plan.items
            .allSatisfy { $0.source.path.hasPrefix(sandbox.root.path) && $0.target.path.hasPrefix(mac.path) })
        let there = try await sidecars.move(plan)
        #expect(there.moved == totals.sidecars && there.gone == 0 && there.conflicts.isEmpty && there.failed.isEmpty)
        #expect(try await sidecars.census(ofRoot: root) == SidecarCensus(
            root: sandbox.rootPath, placement: .onThisMac, beside: 0, onThisMac: totals.sidecars, both: 0,
            otherApps: totals.xmpSidecars,
        ))
        #expect(try Self.sidecars(below: sandbox.root).isEmpty)
        #expect(try Self.sidecars(below: mac) == before)
        #expect(try Self.otherApps(below: sandbox.root) == xmps && Self.otherApps(below: mac).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecars.moveJournal.path))

        let back = try await sidecars.move(sidecars.planMove(ofRoot: root, to: .besidePhotos))
        #expect(back.moved == totals.sidecars && back.failed.isEmpty)
        #expect(try await sidecars.census(ofRoot: root) == SidecarCensus(
            root: sandbox.rootPath, placement: .besidePhotos, beside: totals.sidecars, onThisMac: 0, both: 0,
            otherApps: totals.xmpSidecars,
        ))
        #expect(try Self.sidecars(below: sandbox.root) == before)
        #expect(try Self.sidecars(below: mac).isEmpty && Self.otherApps(below: sandbox.root) == xmps)
        #expect(Self.leftovers(below: sandbox.root).isEmpty && Self.leftovers(below: mac).isEmpty)
        #expect(try await sidecars.planMove(ofRoot: root, to: .besidePhotos).items.isEmpty)
    }

    @Test func `a sidecar in both places stops a move before it starts, and is listed`() async throws {
        let (sandbox, sidecars, root) = try await Self.indexed(.init(photos: 150, seed: 53, shapes: []))
        defer { sandbox.remove() }
        let totals = sandbox.manifest.totals
        let photo = try #require((0 ..< 150).map(sandbox.fixture.photo(at:)).first { $0.sidecar != nil })
        let locator = try await SidecarLocator(folder: sidecars.paths.sidecars, roots: [sidecars.knownRoot(root).1])
        let onThisMac = try #require(locator.onThisMac(sandbox.url(photo)))
        try FileManager.default.createDirectory(
            at: onThisMac.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try FileManager.default.copyItem(at: SidecarLocator.besidePhoto(sandbox.url(photo)), to: onThisMac)
        let before = try Self.sidecars(below: sandbox.root)

        for destination in RootRecord.Sidecars.allCases {
            let plan = try await sidecars.planMove(ofRoot: root, to: destination)
            #expect(plan.conflicts == [SidecarMovePlan.Conflict(
                photo: photo.path, beside: SidecarLocator.besidePhoto(sandbox.url(photo)), onThisMac: onThisMac,
            )])
            await #expect(throws: LibrarySidecarsError.conflicts(plan.conflicts)) { try await sidecars.move(plan) }
        }
        #expect(try await sidecars.census(ofRoot: root) == SidecarCensus(
            root: sandbox.rootPath, placement: .besidePhotos, beside: totals.sidecars, onThisMac: 1, both: 1,
            otherApps: totals.xmpSidecars,
        ))
        #expect(try Self.sidecars(below: sandbox.root) == before)
        #expect(!FileManager.default.fileExists(atPath: sidecars.moveJournal.path))
    }

    @Test func `the journal finishes a move a forced quit interrupted`() async throws {
        let (sandbox, sidecars, root) = try await Self.indexed(.init(photos: 200, seed: 54, shapes: []))
        defer { sandbox.remove() }
        let totals = sandbox.manifest.totals
        let before = try Self.sidecars(below: sandbox.root)
        let plan = try await sidecars.planMove(ofRoot: root, to: .onThisMac)
        #expect(plan.items.count == totals.sidecars && plan.items.count >= 3)

        // As a forced quit leaves it: the journal written, one sidecar moved, one copied but still
        // where it was, and one halfway through its copy.
        try FileManager.default.createDirectory(at: sidecars.paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: sidecars.moveJournal)
        #expect(try SidecarMover.move(plan.items[0].source, to: plan.items[0].target) == .moved)
        for item in plan.items[1 ... 2] {
            try FileManager.default.createDirectory(
                at: item.target.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
        }
        try FileManager.default.copyItem(at: plan.items[1].source, to: plan.items[1].target)
        let staging = plan.items[2].target.deletingLastPathComponent()
            .appending(path: ".\(plan.items[2].target.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: plan.items[2].source, to: staging)
        try FileManager.default.removeItem(at: staging.appending(path: SidecarStore.editFile))

        let outcome = try #require(try await sidecars.resumeMove())
        #expect(outcome.moved == plan.items.count && outcome.failed.isEmpty && outcome.conflicts.isEmpty)
        #expect(try await sidecars.census(ofRoot: root) == SidecarCensus(
            root: sandbox.rootPath, placement: .onThisMac, beside: 0, onThisMac: totals.sidecars, both: 0,
            otherApps: totals.xmpSidecars,
        ))
        let mac = try await LibrarySidecars.folder(of: sidecars.knownRoot(root).1, in: sidecars.paths.sidecars)
        #expect(try Self.sidecars(below: mac) == before)
        #expect(Self.leftovers(below: mac).isEmpty && Self.leftovers(below: sandbox.root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sidecars.moveJournal.path))
        #expect(try await sidecars.resumeMove() == nil)
    }
}

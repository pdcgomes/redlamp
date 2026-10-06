import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct ImportCopyTests {
    private static func jpegs(_ count: Int, from first: Int = 1, padding: Int = 0) -> [SimulatedCard.Shot] {
        (first ..< first + count).map { number in
            SimulatedCard.Shot(
                name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number)), padding: padding,
            )
        }
    }

    @Test func `the destination and the backup get copies of their own, never clones of the card's files`(
    ) async throws {
        let raw = try #require(SimulatedCard.raws(in: FixtureTests.rawFolder).first, "the CC0 raws")
        // The card, the destination and the backup on one APFS volume, where a copy could be a clone.
        let sandbox = try await ImportSandbox.make(onRawVolume: true)
        defer { sandbox.remove() }
        let name = "IMG_0001." + raw.pathExtension.uppercased()
        let source = try sandbox.card("CARD", [SimulatedCard.Shot(name: name, captured: cameraTime(), raw: raw)])
        let original = source.photosFolder.appending(path: "100CANON/" + name)
        #expect(mayShareBlocks(original) == true, "the card's raw is a clone of the CC0 raw")
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(folders: ""))
        let outcome = try await session.importer().run(plan)
        #expect(outcome.isSafeToErase && outcome.bytes == plan.bytes)
        for copy in try plan.targets(of: #require(plan.items.first?.copies.first)) {
            #expect(mayShareBlocks(copy) == false, "\(copy.path)")
            #expect(try Data(contentsOf: copy) == Data(contentsOf: original))
            let dates = try (
                LocalFileSystem().attributes(of: copy).modified,
                LocalFileSystem().attributes(of: original).modified,
            )
            #expect(abs(dates.0.timeIntervalSince(dates.1)) < 0.001)
        }
    }

    @Test func `a copy that reads back different is never verified, and its card isn't safe to erase`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Self.jpegs(4))
        let session = sandbox.session([source], previews: false)
        let settings = try sandbox.settings(folders: "")
        let plan = try await session.plan(settings)
        let corrupting = CorruptingFileSystem { url in
            url.path.contains("/Backup/") && url.lastPathComponent.hasPrefix(".IMG_0002.JPG")
        }
        let outcome = try await session.importer(destinationFileSystem: corrupting).run(plan)
        #expect(outcome.state == .finished && outcome.verified == 3)
        let failure = try #require(outcome.failures.first)
        #expect(failure.photo.hasSuffix("/IMG_0002.JPG") && failure.message.contains("isn't the same as the original"))
        #expect(!outcome.isSafeToErase && outcome.sources.first?.isSafeToErase == false)
        #expect(outcome.sources.first?.failed == 1)
        // Nothing of it at either destination; the others at both.
        for root in [sandbox.destination, sandbox.backup] {
            #expect(Set(ImportSandbox.files(in: root).keys) == ["IMG_0001.JPG", "IMG_0003.JPG", "IMG_0004.JPG"])
            #expect(ImportSandbox.leftovers(in: root).isEmpty)
        }
        let entry = try #require(try await session.importer().entries().last)
        #expect(entry.state == .finished && entry.done == 3 && entry.failed == 1)

        // Imported again, the photos the library now has stay, and the one that failed is copied.
        let again = sandbox.session([source], previews: false)
        let retry = try await again.plan(settings)
        #expect(retry.items.map(\.copies[0].name) == ["IMG_0002.JPG"] && retry.left(.imported) == 3)
        let retried = try await again.importer().run(retry)
        #expect(retried.isSafeToErase && retried.verified == 1)
    }

    @Test func `a photo that changed on the card since it was read isn't copied`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Self.jpegs(2))
        let session = sandbox.session([source], previews: false)
        let plan = try await session.plan(sandbox.settings(folders: ""))
        // Another card with the same names put in, as it would be read from the same place.
        let changed = source.photosFolder.appending(path: "100CANON/IMG_0002.JPG")
        try Data(repeating: 1, count: Int(LocalFileSystem().attributes(of: changed).size)).write(to: changed)
        let outcome = try await session.importer().run(plan)
        #expect(outcome.verified == 1 && outcome.failures.first?.message == "it changed since it was read")
        #expect(!outcome.isSafeToErase)
        #expect(Set(ImportSandbox.files(in: sandbox.destination).keys) == ["IMG_0001.JPG"])
    }

    @Test func `a copy that can't be written is never verified, and leaves nothing behind`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let source = try sandbox.card("CARD", Self.jpegs(3))
        try FileManager.default.createDirectory(at: sandbox.backup, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sandbox.backup.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.backup.path) }
        let session = sandbox.session([source], previews: false)
        let outcome = try await session.importer().run(session.plan(sandbox.settings()))
        #expect(outcome.verified == 0 && outcome.failures.count == 3 && !outcome.isSafeToErase)
        #expect(ImportSandbox.files(in: sandbox.destination).isEmpty)
        #expect(ImportSandbox.leftovers(in: sandbox.destination).isEmpty)
    }

    @Test func `the choices made while browsing are written at the destination, and the library hears of them`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .milliseconds(10)))
        let library = ImportLibrary(
            paths: sandbox.paths, index: sandbox.index, store: sandbox.store, indexer: sandbox.library.indexer,
            live: live,
        )
        let source = try sandbox.card("CARD", Self.jpegs(4))
        let session = ImportSession(sources: [source], library: library, fileSystem: sandbox.fileSystem)
        _ = await session.browsed()
        let ids = try (1 ... 4).map { try #require(session.id(named: String(format: "IMG_%04d.JPG", $0))) }
        session.rate([ids[0]], 4)
        session.flag([ids[1]], .pick)
        session.label([ids[2]], .red)
        session.choose([ids[3]], false)
        #expect(session.photo(ids[0])?.choices.given == [.rating])

        let updates = live.open(.allPhotographs)
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?.list.isEmpty == true)
        let settings = try sandbox.settings(metadata: ImportMetadata(
            name: "Trip",
            keywords: ["Places/Portugal/Lisbon"],
        ))
        let plan = try await session.plan(settings)
        #expect(plan.items.count == 3 && plan.left(.notChosen) == 1)
        let outcome = try await session.importer().run(plan)
        #expect(outcome.sidecars == 3 && outcome.indexed == 3 && outcome.isSafeToErase)

        let folder = sandbox.destination.appending(path: "2026/2026-10-05")
        let store = SidecarStore()
        let written = try (1 ... 3).map { try #require(store.load(for: folder.appending(path: String(
            format: "IMG_%04d.JPG",
            $0,
        )))?.metadata) }
        #expect(written[0].rating == 4 && written[0].flag == nil && written[0].label == nil)
        #expect(written[1].rating == 0 && written[1].flag == .pick)
        #expect(written[2].label == .red && written[2].originalName == nil)
        #expect(written.allSatisfy { $0.keywords == ["Places/Portugal/Lisbon"] })
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "IMG_0004.JPG").path))

        let rows = try await sandbox.rows(below: sandbox.destination)
        #expect(rows["2026/2026-10-05/IMG_0001.JPG"]?.rating == 4)
        #expect(rows["2026/2026-10-05/IMG_0002.JPG"]?.flag == .pick)
        #expect(rows["2026/2026-10-05/IMG_0003.JPG"]?.label == .red)
        let keyword = try await sandbox.index.read { try $0.photoIDs(withKeyword: "Places/Portugal/Lisbon") }
        #expect(keyword.count == 3)
        await live.settle()
        let update = await iterator.next()
        #expect(update?.list.count == 3)
        updates.close()
    }

    @Test func `several cards are browsed and copied at once, each through its own readers`() async throws {
        let sandbox = try await ImportSandbox.make(profile: .cardReader)
        defer { sandbox.remove() }
        // Two cameras numbering alike, their shots interleaved in time.
        let first = try sandbox.card("CARD_A", (1 ... 3).map { number in
            SimulatedCard.Shot(name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number * 10)))
        })
        let second = try sandbox.card("CARD_B", (1 ... 3).map { number in
            SimulatedCard.Shot(
                name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number * 10 + 5)),
                model: "Canon EOS R5",
            )
        })
        let session = sandbox.session([first, second])
        let events = await session.browsed()
        #expect(events.count {
            if case .listed = $0 {
                true
            } else {
                false
            }
        } == 2)
        let readers = [session.io(for: first), session.io(for: second)]
        #expect(readers[0] !== readers[1] && readers.allSatisfy { $0.statistics.operations > 0 })
        #expect(session.photos.count == 6 && session.photos.allSatisfy { $0.state == .previewed })

        let plan = try await session.plan(sandbox.settings(folders: "{date:yyyy-MM-dd}"))
        let names = plan.items.map { item in
            "\(item.source == first.id ? "A" : "B") \(FilePlanner.split(item.copies[0].source).name) → \(item.copies[0].name)"
        }
        #expect(names == [
            "A IMG_0001.JPG → IMG_0001.JPG", "B IMG_0001.JPG → IMG_0001-2.JPG", "A IMG_0002.JPG → IMG_0002.JPG",
            "B IMG_0002.JPG → IMG_0002-2.JPG", "A IMG_0003.JPG → IMG_0003.JPG", "B IMG_0003.JPG → IMG_0003-2.JPG",
        ])
        let outcome = try await session.importer().run(plan)
        #expect(outcome.verified == 6 && outcome.sources.count == 2 && outcome.sources.allSatisfy(\.isSafeToErase))
        #expect(ImportSandbox.files(in: sandbox.backup).count == 6)
    }
}

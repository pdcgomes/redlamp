import Foundation
import RedlampDocument
import Synchronization
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

    @Test func `a metadata preset's ticked fields are written at the destination, each replacing, appending or prefixing`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        var shots = Self.jpegs(2)
        shots[0].sidecars = ["IMG_0001.xmp": Data(MetadataIndexTests.packet(
            #"photoshop:City="Lisbon" photoshop:Country="Portugal""#,
            """
            <dc:description><rdf:Alt><rdf:li xml:lang="x-default">On the card</rdf:li></rdf:Alt></dc:description>
            <dc:creator><rdf:Seq><rdf:li>Ana Sousa</rdf:li></rdf:Seq></dc:creator>
            <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© Ana Sousa</rdf:li></rdf:Alt></dc:rights>
            """,
        ).utf8)]
        let source = try sandbox.card("CARD", shots)
        let session = sandbox.session([source])
        _ = await session.browsed()
        let preset = MetadataPreset(name: "Wedding", fields: [
            .title: MetadataPreset.Entry("Wedding"),
            .caption: MetadataPreset.Entry(#"at the \ch\"#, mode: .append),
            .creator: MetadataPreset.Entry("Studio Lumen", mode: .prefix),
            .city: MetadataPreset.Entry("Sintra"),
        ])
        let metadata = ImportMetadata(preset, codes: CodeReplacements(text: "ch\tchapel"), keywords: ["Weddings"])
        #expect(metadata.name == "Wedding" && metadata.fields[.caption]?.text == "at the chapel")
        let settings = try sandbox.settings(metadata: metadata)
        let journaled = try JSONDecoder().decode(ImportSettings.self, from: JSONEncoder().encode(settings))
        #expect(journaled.metadata == metadata, "the plan's preset is kept as the journal writes it")

        let outcome = try await session.importer().run(session.plan(settings))
        #expect(outcome.sidecars == 2 && outcome.isSafeToErase)
        let folder = sandbox.destination.appending(path: "2026/2026-10-05")
        let written = try (1 ... 2).map { number in
            try #require(SidecarStore().load(for: folder.appending(path: String(format: "IMG_%04d.JPG", number)))?
                .metadata)
        }
        #expect(written[0].title == "Wedding", "replacing")
        #expect(written[0].caption == "On the card at the chapel", "appended to the caption it came with")
        #expect(written[0].creator == "Studio Lumen; Ana Sousa", "put before its creator")
        #expect(written[0].location == PhotoLocation(country: "Portugal", city: "Sintra"), "its city replaced")
        #expect(written[0].copyright == nil, "a field the preset doesn't tick is left to the photo's own")
        #expect(written[0].keywords == ["Weddings"])
        #expect(written[1].title == "Wedding" && written[1].caption == "at the chapel")
        #expect(written[1].creator == "Studio Lumen" && written[1].location == PhotoLocation(city: "Sintra"))

        let rows = try await sandbox.rows(below: sandbox.destination)
        let first = rows["2026/2026-10-05/IMG_0001.JPG"]
        #expect(first?.caption == "On the card at the chapel" && first?.copyright == "© Ana Sousa")
        #expect(rows["2026/2026-10-05/IMG_0002.JPG"]?.title == "Wedding")
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
        let reports = Mutex<[ImportProgress]>([])
        let outcome = try await session.importer().run(plan) { progress in reports.withLock { $0.append(progress) } }
        #expect(outcome.verified == 6 && outcome.sources.count == 2 && outcome.sources.allSatisfy(\.isSafeToErase))
        #expect(ImportSandbox.files(in: sandbox.backup).count == 6)
        // Each card's part as it copies, adding up to the whole.
        let told = reports.withLock { $0 }
        #expect(told.allSatisfy { $0.sources.values.reduce(0) { $0 + $1.done } == $0.done })
        #expect(told.last?.sources[first.id] == ImportProgress.Source(photos: 3, done: 3, failed: 0))
        #expect(told.last?.sources[second.id] == ImportProgress.Source(photos: 3, done: 3, failed: 0))
    }

    @Test func `photos browsed in a session for each card are planned together, with the choices made in each`(
    ) async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        let cards = try ["CARD_A", "CARD_B"].enumerated().map { offset, name in
            try sandbox.card(name, (1 ... 2).map { number in
                SimulatedCard.Shot(
                    name: String(format: "IMG_%04d.JPG", number),
                    captured: cameraTime(Double(number * 10 + offset * 5)),
                )
            })
        }
        let sessions = cards.map { sandbox.session([$0]) }
        for session in sessions {
            _ = await session.browsed()
        }
        let rated = try #require(sessions[1].id(named: "IMG_0002.JPG"))
        sessions[1].rate([rated], 4)
        sandbox.reads.reset()
        let together = sandbox.session(cards, previews: false)
        together.add(sessions.flatMap(\.photos))
        let plan = try await together.plan(sandbox.settings(folders: ""))
        #expect(plan.items.map { "\($0.source == cards[0].id ? "A" : "B") \($0.copies[0].name)" } == [
            "A IMG_0001.JPG", "B IMG_0001-2.JPG", "A IMG_0002.JPG", "B IMG_0002-2.JPG",
        ])
        #expect(plan.items.first { $0.photo == rated }?.choices.rating == 4)
        #expect(together.photos.allSatisfy { sandbox.reads.bytesRead($0.url) == 0 }, "photos read once, by their own")
    }
}

import Foundation
import Testing
@testable import RedlampLibrary

struct ImportBrowseTests {
    /// Six JPEGs over two days, then a raw beside its JPEG, the newest.
    private static func shots(raw: URL?, padding: Int = 0) -> [SimulatedCard.Shot] {
        var shots = (1 ... 6).map { number in
            SimulatedCard.Shot(
                name: String(format: "IMG_%04d.JPG", number), captured: cameraTime(Double(number * 3600 * 5)),
                padding: padding,
            )
        }
        if let raw {
            shots.append(SimulatedCard.Shot(name: "IMG_0007.CR3", captured: cameraTime(40 * 3600), raw: raw))
            shots.append(SimulatedCard.Shot(name: "IMG_0007.JPG", captured: cameraTime(40 * 3600), padding: padding))
        }
        return shots
    }

    private static var canonRaw: URL? {
        SimulatedCard.raws(in: FixtureTests.rawFolder).first { $0.pathExtension.lowercased() == "cr3" }
    }

    @Test func `a card is browsed from its previews, newest first, before anything is copied`() async throws {
        let raw = try #require(Self.canonRaw, "the CC0 CR3 in tests/fixtures/raw")
        let sandbox = try await ImportSandbox.make(onRawVolume: true)
        defer { sandbox.remove() }
        let source = try sandbox.card("EOS_DIGITAL", Self.shots(raw: raw))
        let session = sandbox.session([source])
        let events = await session.browsed()

        let listed = try #require(events.compactMap { event -> [String]? in
            guard case let .listed(_, photos) = event else { return nil }
            return photos
        }.first)
        let names: [String] = listed.map { ($0 as NSString).lastPathComponent }
        let newestFirst: [String] = (1 ... 7).reversed().map { number in
            String(format: number == 7 ? "IMG_%04d.CR3" : "IMG_%04d.JPG", number)
        }
        #expect(names == newestFirst)
        #expect(events.last == .browsed)
        let photos = session.photos
        #expect(photos.count == 7 && photos.allSatisfy { $0.state == .previewed })
        for photo in photos {
            let key = try #require(photo.primary.contentKey)
            let thumbnail = try #require(sandbox.store.data(for: key, tier: .grid))
            let image = try #require(StoreImageEncoder.decode(thumbnail))
            #expect(max(image.width, image.height) <= PhotoStore.Tier.grid.pixelSize)
        }
        // The raw's preview is its camera's 1620 by 1080 JPEG, read alone: not the 23 MB around it.
        let pair = try #require(photos.first { $0.primary.name == "IMG_0007.CR3" })
        #expect(pair.photoFiles.map(\.name) == ["IMG_0007.CR3", "IMG_0007.JPG"])
        #expect(pair.metadata?.cameraName == "Canon EOS R6")
        let pairKey = try #require(pair.primary.contentKey)
        let stored = try #require(sandbox.store.data(for: pairKey, tier: .grid))
        let preview = try #require(StoreImageEncoder.decode(stored))
        #expect(preview.width == 384 && preview.height == 256)
        let read = sandbox.reads.bytesRead(pair.url)
        #expect(read > 0 && read < 3_000_000 && Int64(read) < pair.primary.size / 5, "\(read) bytes read")
        // Nothing is copied or written while browsing: no destination, nothing beside the photos.
        #expect(!FileManager.default.fileExists(atPath: sandbox.destination.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
        #expect(ImportSandbox.files(in: source.url).keys.allSatisfy { !$0.contains(".redlamp") })
    }

    @Test func `photos the library has are recognised by content key before their previews are read`() async throws {
        let sandbox = try await ImportSandbox.make()
        defer { sandbox.remove() }
        // Larger than a head, so a preview would read past it.
        let source = try sandbox.card("CARD", Self.shots(raw: nil, padding: 400_000))
        let folder = source.photosFolder.appending(path: "100CANON")
        let known = ["IMG_0002.JPG", "IMG_0005.JPG"]
        let records = try known.map { name in
            let url = folder.appending(path: name)
            let size = try LocalFileSystem().attributes(of: url).size
            return try (
                name,
                ContentKey(fileSize: Int(size), head: LocalFileSystem().read(url, range: 0 ..< 65536)),
                size,
            )
        }
        try await sandbox.index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "ELSEWHERE", name: "Elsewhere"))
            try writer.upsertRoot(RootRecord(volume: volume, path: "/Elsewhere"))
            let id = try #require(try writer.folderID(forPath: "/Elsewhere"))
            try writer.upsertPhotos(records.map { name, key, size in
                PhotoRecord(folder: id, name: "Copy of " + name, size: size, contentKey: key.data)
            })
        }
        let session = sandbox.session([source])
        let events = await session.browsed()
        let imported = events.flatMap { event -> [String] in
            guard case let .imported(ids) = event else { return [] }
            return ids
        }
        #expect(Set(imported.map { ($0 as NSString).lastPathComponent }) == Set(known))
        for photo in session.photos {
            let key = try #require(photo.primary.contentKey)
            let isKnown = known.contains(photo.primary.name)
            #expect(photo.state == (isKnown ? .imported : .previewed), "\(photo.primary.name)")
            #expect(sandbox.store.contains(key, tier: .grid) == !isKnown, "\(photo.primary.name)")
            // The bytes its content key covers, and nothing past them, for those the library has.
            let read = sandbox.reads.bytesRead(photo.url)
            #expect(isKnown ? read == ContentKey.headLength : read == Int(photo.primary.size), "\(read)")
        }
        let plan = try await session.plan(sandbox.settings())
        #expect(plan.items.count == 4 && plan.left(.imported) == 2)
        #expect(Set(plan.left.map { ($0.file as NSString).lastPathComponent }) == Set(known))
    }
}

import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct IndexWriterTests {
    private struct Failure: Error {}

    @Test func `a photo reads back with every field it was written with`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["2024"])["2024"])
        let (camera, lens) = try await sandbox.index.write { writer in
            try (writer.cameraID(for: "Fujifilm X-T5"), writer.lensID(for: "XF 35mm F1.4 R"))
        }
        var photo = PhotoRecord(
            folder: folder, name: "DSCF1234.RAF", kind: .raw, size: 52_000_000,
            modified: Date(timeIntervalSince1970: 1_717_200_000.5), fileID: UInt64.max - 1,
            contentKey: Data((0 ..< 16).map { UInt8($0) }), captured: Date(timeIntervalSince1970: 1_717_196_400.25),
            capturedOffset: 3600, camera: camera, lens: lens, iso: 640, aperture: 2.8, shutter: 1.0 / 250, focal: 35,
            width: 7728, height: 5152, orientation: 6, latitude: 38.7139, longitude: -9.1394, rating: 4, flag: .reject,
            label: .purple, marked: true, edited: true, sidecarModified: Date(timeIntervalSince1970: 1_717_300_000),
            xmpModified: Date(timeIntervalSince1970: 1_717_400_000), title: "Tram 28", caption: "Alfama at dusk",
            state: [.offline, .settling], indexed: 3,
        )
        let id = try #require(try await sandbox.upsert([photo]).first)
        photo.id = id

        #expect(try await sandbox.index.read { try $0.photo(id: id) } == photo)
        let empty = PhotoRecord(folder: folder, name: "IMG_0001.HEIC")
        let emptyID = try #require(try await sandbox.upsert([empty]).first)
        let readBack = try await sandbox.index.read { try $0.photo(id: emptyID) }
        #expect(readBack?.kind == .heic && readBack?.captured == nil && readBack?.flag == nil && readBack?.state == [])
    }

    @Test func `upserting a photo already in its folder updates it in place and keeps its ID`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["2024", "2025"])
        let folder = try #require(folders["2024"])
        let original = try await sandbox.upsert([
            PhotoRecord(folder: folder, name: "DSC_0001.NEF", size: 100),
            PhotoRecord(folder: folder, name: "DSC_0002.NEF", size: 100),
        ])

        let updated = try await sandbox.upsert([
            PhotoRecord(folder: folder, name: "DSC_0002.NEF", size: 200, rating: 3, title: "Harbour"),
            PhotoRecord(folder: #require(folders["2025"]), name: "DSC_0002.NEF", size: 300),
        ])
        #expect(updated[0] == original[1], "same folder and name, same row")
        #expect(!original.contains(updated[1]), "same name in another folder is another photo")

        let (count, photo) = try await sandbox.index.read { reader in
            try (reader.photoCount(), reader.photo(id: original[1]))
        }
        #expect(count == 3)
        #expect(photo?.size == 200 && photo?.rating == 3 && photo?.title == "Harbour")
    }

    @Test func `organising changes reach only the photos and fields given`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Cull"])["Cull"])
        let photos = (0 ..< 10000).map { PhotoRecord(folder: folder, name: "IMG_\($0).CR3", label: .blue) }
        let ids = try await sandbox.upsert(photos)

        let rated = try await sandbox.index.write { writer in
            try writer.setOrganising([.rating(2), .rating(4), .flag(.pick)], forPhotos: Array(ids[0 ..< 5000]))
        }
        let marked = try await sandbox.index.write { writer in
            try writer.setOrganising([.label(nil), .marked(true)], forPhotos: [ids[0], ids[9999]])
        }
        #expect(rated == 5000 && marked == 2)

        let (first, middle, last) = try await sandbox.index.read { reader in
            try (reader.photo(id: ids[0]), reader.photo(id: ids[4999]), reader.photo(id: ids[9999]))
        }
        #expect(first?.rating == 4 && first?.flag == .pick && first?.label == nil && first?.marked == true)
        #expect(middle?.rating == 4 && middle?.flag == .pick && middle?.label == .blue && middle?.marked == false)
        #expect(last?.rating == 0 && last?.flag == nil && last?.label == nil && last?.marked == true)

        try await sandbox.index.write { try $0.setOrganising([.flag(nil)], forPhotos: ids) }
        let picks = try await sandbox.index.read { reader in
            try reader.database.prepare("SELECT count(*) FROM photos WHERE flag != 0").first { $0.int(at: 0) }
        }
        #expect(picks == 0)
    }

    @Test func `cameras and lenses are stored once each, by name, and read back by ID`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let (fuji, again, leica, lens) = try await sandbox.index.write { writer in
            try (
                writer.cameraID(for: "Fujifilm X-T5", make: "FUJIFILM", model: "X-T5"),
                writer.cameraID(for: "Fujifilm X-T5"),
                writer.cameraID(for: "Leica Q3"),
                writer.lensID(for: "XF 35mm F1.4 R"),
            )
        }
        #expect(fuji == again && fuji != leica)

        // A rolled-back write takes the cameras it added with it, and a later write adds them again.
        await #expect(throws: Failure.self) {
            try await sandbox.index.write { writer in
                _ = try writer.cameraID(for: "Ricoh GR III")
                throw Failure()
            }
        }
        #expect(try await sandbox.index.read { try $0.cameraNames() }.count == 2)
        let (later, ricoh, sameLens) = try await sandbox.index.write { writer in
            try (
                writer.cameraID(for: "Fujifilm X-T5"),
                writer.cameraID(for: "Ricoh GR III"),
                writer.lensID(for: "XF 35mm F1.4 R"),
            )
        }
        #expect(later == fuji && sameLens == lens)

        let (cameras, lenses, make) = try await sandbox.index.read { reader in
            try (
                reader.cameraNames(), reader.lensNames(),
                reader.database.prepare("SELECT make FROM cameras WHERE name = 'Fujifilm X-T5'")
                    .first { $0.string(at: 0) },
            )
        }
        #expect(cameras == [fuji: "Fujifilm X-T5", leica: "Leica Q3", ricoh: "Ricoh GR III"])
        #expect(lenses == [lens: "XF 35mm F1.4 R"])
        #expect(make == "FUJIFILM")
    }

    @Test func `keywords by path add their parents once and replace a photo's set`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Trip"])["Trip"])
        let ids = try await sandbox.upsert((0 ..< 3).map { PhotoRecord(folder: folder, name: "IMG_\($0).HEIC") })

        let (lisbon, portugal, paths) = try await sandbox.index.write { writer in
            let lisbon = try writer.keywordID(forPath: "Places/Portugal/Lisbon")
            let portugal = try writer.keywordID(forPath: " Places / Portugal ")
            try writer.setKeywords(["Places/Portugal/Lisbon", "Birds"], forPhoto: ids[0])
            try writer.setKeywords(["Birds", "Places/Portugal/Porto"], forPhoto: ids[0])
            try writer.addKeyword("Places/Portugal/Lisbon", toPhotos: [ids[1], ids[2]])
            try writer.removeKeyword("Places/Portugal/Lisbon", fromPhotos: [ids[2]])
            return try (lisbon, portugal, writer.keywordPaths())
        }
        #expect(paths[portugal] == "Places/Portugal" && paths[lisbon] == "Places/Portugal/Lisbon")
        #expect(Set(paths.values) == [
            "Places",
            "Places/Portugal",
            "Places/Portugal/Lisbon",
            "Places/Portugal/Porto",
            "Birds",
        ])

        let (first, second, third, underPlaces, exactlyPlaces) = try await sandbox.index.read { reader in
            try (
                reader.keywords(forPhoto: ids[0]), reader.keywords(forPhoto: ids[1]), reader.keywords(forPhoto: ids[2]),
                reader.photoIDs(withKeyword: "Places"), reader.photoIDs(
                    withKeyword: "Places",
                    includingChildren: false,
                ),
            )
        }
        #expect(first == ["Birds", "Places/Portugal/Porto"])
        #expect(second == ["Places/Portugal/Lisbon"] && third.isEmpty)
        #expect(underPlaces == [ids[0], ids[1]] && exactlyPlaces.isEmpty)

        await #expect(throws: LibraryIndexError.emptyKeywordPath) {
            try await sandbox.index.write { try $0.keywordID(forPath: " / ") }
        }
    }

    @Test func `a photo is found by path, by file identifier on its volume and by content key`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["2024/Lisbon", "Copies"])
        let key = Data(repeating: 7, count: 16)
        let ids = try await sandbox.upsert([
            PhotoRecord(
                folder: #require(folders["2024/Lisbon"]),
                name: "DSC_0001.ARW",
                fileID: 42,
                contentKey: key,
            ),
            PhotoRecord(
                folder: #require(folders["Copies"]),
                name: "DSC_0001 copy.ARW",
                fileID: 43,
                contentKey: key,
            ),
        ])
        let volume = sandbox.volume
        let (byPath, missing, byFileID, otherVolume, byKey) = try await sandbox.index.read { reader in
            try (
                reader.photo(path: IndexSandbox.rootPath + "/2024/Lisbon/DSC_0001.ARW"),
                reader.photo(path: IndexSandbox.rootPath + "/2024/DSC_0001.ARW"),
                reader.photos(fileID: 42, volume: volume), reader.photos(fileID: 42, volume: volume + 1),
                reader.photos(contentKey: key),
            )
        }
        #expect(byPath?.id == ids[0] && missing == nil)
        #expect(byFileID.map(\.id) == [ids[0]] && otherVolume.isEmpty)
        #expect(byKey.map(\.id) == ids)
    }

    @Test func `a folder's subtree, the folders left to index and the counts come from the index`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders([
            "2024",
            "2024/Lisbon",
            "2024/Lisbon/Day 1",
            "2024 Extra",
            "2024-old",
            "20240",
        ])
        func id(_ path: String) throws -> Int64 {
            try #require(folders[path])
        }
        var photos: [PhotoRecord] = []
        for path in folders.keys.sorted() {
            photos += try (0 ..< 2).map { try PhotoRecord(folder: id(path), name: "IMG_\($0).JPG") }
        }
        try await sandbox.upsert(photos)
        let (listed, indexed, changed) = try (id("2024"), id("2024/Lisbon"), id("2024/Lisbon/Day 1"))
        try await sandbox.index.write { writer in
            for folder in [listed, indexed, changed] {
                try writer.setListing(signature: 5, listedAt: Date(), forFolder: folder)
            }
            try writer.setIndexedSignature(5, forFolder: indexed)
            try writer.setIndexedSignature(4, forFolder: changed)
        }

        let subtree = try id("2024")
        let lisbon = try id("2024/Lisbon")
        let (inSubtree, idsInSubtree, toIndex, children, counts, total, inLisbon, folderCount) = try await sandbox.index
            .read { reader in
                try (
                    reader.photos(inSubtreeOf: subtree), reader.photoIDs(inSubtreeOf: subtree), reader.foldersToIndex(),
                    reader.subfolders(of: subtree), reader.photoCountsByFolder(), reader.photoCount(),
                    reader.photoCount(inFolder: lisbon), reader.folderCount(),
                )
            }
        let subtreeFolders = try Set([id("2024"), id("2024/Lisbon"), id("2024/Lisbon/Day 1")])
        #expect(Set(inSubtree.map(\.folder)) == subtreeFolders && inSubtree.count == 6)
        #expect(idsInSubtree == inSubtree.map(\.id).sorted())
        #expect(!toIndex.contains { $0.id == indexed } && toIndex.contains { $0.id == changed })
        #expect(toIndex.contains { $0.id == listed } && toIndex.count == 5, "unlisted, or listed and not yet indexed")
        #expect(children.map(\.id) == [lisbon])
        #expect(counts.count == 6 && counts.values.allSatisfy { $0 == 2 })
        #expect(total == 12 && inLisbon == 2 && folderCount == 6)
    }

    @Test func `a moved folder keeps its rows, and a deleted one takes everything under it`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["Trips", "Trips/Lisbon", "Trips/Lisbon/Day 1", "Other"])
        let day = try #require(folders["Trips/Lisbon/Day 1"])
        let lisbon = try #require(folders["Trips/Lisbon"])
        let other = try #require(folders["Other"])
        let ids = try await sandbox.upsert([
            PhotoRecord(folder: day, name: "IMG_0001.HEIC"), PhotoRecord(folder: lisbon, name: "IMG_0002.HEIC"),
        ])

        try await sandbox.index.write { try $0.moveFolder(
            lisbon,
            to: IndexSandbox.rootPath + "/Other/Lisboa",
            parent: other,
        ) }
        let (moved, child, photo, stale) = try await sandbox.index.read { reader in
            try (
                reader.folder(id: lisbon), reader.folder(id: day),
                reader.photo(path: IndexSandbox.rootPath + "/Other/Lisboa/Day 1/IMG_0001.HEIC"),
                reader.photo(path: IndexSandbox.rootPath + "/Trips/Lisbon/Day 1/IMG_0001.HEIC"),
            )
        }
        #expect(moved?.path == IndexSandbox.rootPath + "/Other/Lisboa" && moved?.parent == other)
        #expect(child?.path == IndexSandbox.rootPath + "/Other/Lisboa/Day 1")
        #expect(photo?.id == ids[0] && stale == nil)

        try await sandbox.index.write { try $0.deleteFolder(lisbon) }
        let (count, folderCount) = try await sandbox.index.read { try ($0.photoCount(), $0.folderCount()) }
        #expect(count == 0 && folderCount == 2)
    }

    @Test func `deleting photos takes their keywords and text with them`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Birds"])["Birds"])
        let ids = try await sandbox.upsert([
            PhotoRecord(folder: folder, name: "Kingfisher.JPG"), PhotoRecord(folder: folder, name: "Heron.JPG"),
        ])
        try await sandbox.index.write { try $0.addKeyword("Animals/Birds", toPhotos: ids) }

        let deleted = try await sandbox.index.write { try $0.deletePhotos([ids[0], 999_999]) }
        let (left, links, text) = try await sandbox.index.read { reader in
            try (
                reader.photoCount(),
                reader.database.prepare("SELECT count(*) FROM photo_keywords").first { $0.int(at: 0) },
                reader.photoIDs(matching: "fisher"),
            )
        }
        #expect(deleted == 1 && left == 1 && links == 1 && text.isEmpty)
    }

    @Test func `the hot-column scan reads every photo in ID order, quickly`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders((0 ..< 20).map { "Day \($0)" })
        let (cameras, lenses) = try await sandbox.index.write { writer in
            try (
                SyntheticIndexPhotos.cameras.map { try writer.cameraID(for: $0) },
                SyntheticIndexPhotos.lenses.map { try writer.lensID(for: $0) },
            )
        }
        var synthetic = SyntheticIndexPhotos(seed: 1, cameraIDs: cameras, lensIDs: lenses)
        let folderIDs = folders.keys.sorted().compactMap { folders[$0] }
        var expected: [PhotoRecord] = []
        for batch in 0 ..< 20 {
            let photos = (0 ..< 1000).map { synthetic.photo(batch * 1000 + $0, in: folderIDs[batch]) }
            expected += try await sandbox.upsert(photos).enumerated().map { offset, id in
                var photo = photos[offset]
                photo.id = id
                return photo
            }
        }

        let count = expected.count
        let (rows, seconds) = try await sandbox.index.read { reader in
            var rows: [HotColumns] = []
            rows.reserveCapacity(count)
            let start = ContinuousClock.now
            try reader.scanHotColumns { rows.append($0) }
            return (rows, (ContinuousClock.now - start) / .seconds(1))
        }
        print(
            "Hot-column scan: \(rows.count) rows in \(Int(seconds * 1000)) ms, \(Int(Double(rows.count) / seconds)) rows/s",
        )
        #expect(rows.map(\.id) == expected.map(\.id))
        let sample = try #require(rows.last)
        let photo = try #require(expected.last)
        #expect(sample.folder == photo.folder && sample.name == photo.name && sample.camera == photo.camera)
        #expect(sample.captured == photo.captured?.timeIntervalSince1970 && sample.iso == photo.iso)
        #expect(sample.rating == photo.rating && sample.flag == PhotoRecord.code(for: photo.flag))
        #expect(sample.label == PhotoRecord.code(for: photo.label) && sample.kind == photo.kind.rawValue)
    }
}

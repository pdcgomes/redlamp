import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization
import Testing
@_spi(Harness) @testable import RedlampUI

/// A Library entry's list (`LibrarySourceList`) as photos change, arrive and leave: each update after the first is
/// taken from the photos its diff names, and what it hands over is what a list opened afresh hands over.
@MainActor
struct LibrarySourceListTests {
    /// The last change a list handed over: its photos' ratings by path, and how many changes it has handed.
    private final class Handed: Sendable {
        private let state = Mutex<(photos: [String: Int]?, changes: Int)>((nil, 0))

        var photos: [String: Int]? {
            state.withLock { $0.photos }
        }

        var changes: Int {
            state.withLock { $0.changes }
        }

        func take(_ change: LibrarySourceList.Change) {
            let photos = Dictionary(change.items.map { ($0.url.path, $0.metadata.rating) }) { first, _ in first }
            state.withLock { $0 = (photos, $0.changes + 1) }
        }
    }

    private static func open(_ core: LibraryCore) -> (LibrarySourceList, Handed) {
        let handed = Handed()
        let list = LibrarySourceList(core: core, source: .allPhotographs) { change in handed.take(change) }
        return (list, handed)
    }

    /// What a list opened afresh hands over first.
    private static func afresh(_ core: LibraryCore, _ sandbox: SourcesSandbox) async throws -> [String: Int] {
        let (list, handed) = open(core)
        defer { list.close() }
        try await sandbox.eventually { handed.photos != nil }
        return try #require(handed.photos)
    }

    @Test func `a list follows photos changed, added and taken out as a list opened afresh has them`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg", "B.jpg", "C.jpg"])
        let model = try await sandbox.open()
        let service = try #require(sandbox.service)
        let core = try #require(service.core)
        let (list, handed) = Self.open(core)
        defer { list.close() }
        try await sandbox.eventually { handed.photos?.count == 3 }
        let b = sandbox.photo("B.jpg").path

        // B rated: one photo changed in place.
        model.showFolder(sandbox.root)
        try await sandbox.eventually { model.items.count == 3 }
        try await sandbox.cull(.rating3, [sandbox.photo("B.jpg")])
        try await sandbox.eventually { handed.photos?[b] == 3 }
        let rated = try #require(handed.photos)
        #expect(try await rated == Self.afresh(core, sandbox))

        // Trip added: its photos arrive among the others.
        let trip = try FolderRemovalTests.trip(in: sandbox)
        try await FolderRemovalTests.add(trip, to: model.library, service: service)
        try await sandbox.eventually { handed.photos?.count == 6 }
        let added = try #require(handed.photos)
        #expect(added.count == 6 && added[b] == 3, "\(added)")
        #expect(try await added == Self.afresh(core, sandbox))

        // Trip taken out: its photos leave, the others stay as they were.
        let changes = handed.changes
        try model.library.remove(#require(model.library.root(containing: trip)))
        try await sandbox.eventually { handed.photos?.count == 3 }
        let left = try #require(handed.photos)
        let expected = ["A.jpg": 0, "B.jpg": 3, "C.jpg": 0].reduce(into: [String: Int]()) { photos, photo in
            photos[sandbox.photo(photo.key).path] = photo.value
        }
        #expect(left == expected)
        #expect(try await left == Self.afresh(core, sandbox))
        #expect(handed.changes > changes)
    }

    /// An index in `folder` of three folders' photos, the grid's every field set on some, more than are read a row at a
    /// time; their IDs, and each one's row as the grid shows it, with its content key.
    private func photosIndex(
        in folder: URL,
    ) async throws -> (index: LibraryIndex, ids: [Int64], items: [LibraryItem], keys: [ContentKey?]) {
        let index = try await LibraryIndex.open(at: folder.appending(path: "Index.sqlite"), readers: 2)
        let ids = try await index.write { writer -> [Int64] in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "TEST", name: "Test", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/Photos"))
            let folders = try [
                "/Volumes/Test/Photos",
                "/Volumes/Test/Photos/Day 2",
                "/Volumes/Test/Photos/Café – Alfama",
            ]
            .map { path in try writer.upsertFolder(FolderRecord(root: root, path: path)) }
            let flags: [PhotoFlag?] = [nil, .pick, .reject]
            let photos = (0 ..< LibrarySourceList.Mapping.passFrom + 500).map { number -> PhotoRecord in
                var photo = PhotoRecord(folder: folders[number % 3], name: String(format: "IMG_%04d.JPG", number))
                photo.size = Int64(1000 + number)
                photo.modified = Date(timeIntervalSince1970: 1_700_000_000 + Double(number))
                photo.contentKey = number % 3 == 0 ? nil : Data(repeating: UInt8(number % 251), count: 16)
                photo.rating = number % 6
                photo.flag = flags[number % 3]
                photo.label = number % 4 == 0 ? .red : nil
                photo.marked = number % 5 == 0
                photo.edited = number % 7 == 0
                photo.sidecarModified = number % 2 == 0 ? Date(timeIntervalSince1970: 1_700_100_000) : nil
                photo.customLabel = number % 9 == 0 ? "Hero" : nil
                photo.otherFields = number % 4 == 3 ? [.rating, .label] : []
                return photo
            }
            return try writer.upsertPhotos(photos)
        }
        let (items, keys) = try await index.read { reader -> ([LibraryItem], [ContentKey?]) in
            var (items, keys) = ([LibraryItem](), [ContentKey?]())
            for id in ids {
                let row = try #require(try reader.photo(id: id))
                let folder = try #require(try reader.folder(id: row.folder)?.path)
                let url = URL(fileURLWithPath: folder + "/" + row.name, isDirectory: false)
                items.append(LibraryFolderList.Mapping.item(row, url: url))
                keys.append(row.contentKey.flatMap(ContentKey.init(data:)))
            }
            return (items, keys)
        }
        return (index, ids, items, keys)
    }

    @Test func `photos read in one pass over their rows are those read a row at a time`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "source-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (index, ids, items, keys) = try await photosIndex(in: folder)
        // In parts of 100 IDs, more than are read at once.
        let pass: [LibrarySourceList.Read] = try await LibrarySourceList.Mapping
            .read(ids, folders: [:], index: index, part: 100).parts.joined().sorted { $0.id < $1.id }
        let few: [LibrarySourceList.Read] = try await Array(LibrarySourceList.Mapping
            .read(Array(ids.prefix(10)), folders: [:], index: index).parts.joined())
        await index.close()
        #expect(pass.map(\.item) == items)
        #expect(pass.map(\.key) == keys)
        #expect(few.map(\.item) == Array(items.prefix(10)))
    }

    @Test func `the URLs and badges read for photos whose rows aren't read are what their rows show`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "source-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (index, ids, items, _) = try await photosIndex(in: folder)
        let rows = LargeListRows(index: index, firstRead: LibrarySourceList.firstRead)
        // In one pass over their IDs' range, and a row at a time.
        let (urls, badges) = try await (rows.urls(of: ids), rows.badges(of: ids))
        let few = Array(ids.prefix(10))
        let (fewURLs, fewBadges) = try await (rows.urls(of: few), rows.badges(of: few))
        await index.close()
        #expect(ids.map { urls[$0] } == items.map(\.url))
        #expect(ids.map { badges[$0]?.url } == items.map(\.url))
        #expect(ids.map { badges[$0]?.values } == items.map { CullingValues($0.metadata) })
        #expect(few.map { fewURLs[$0] } == items.prefix(10).map(\.url))
        #expect(few.map { fewBadges[$0]?.values } == items.prefix(10).map { CullingValues($0.metadata) })
        // Photo 27 has no sidecar, and its rating and label are other apps'; photo 9's are Redlamp's.
        #expect(badges[ids[27]]?.values.rating == 0 && badges[ids[27]]?.values.customLabel == nil)
        #expect(badges[ids[9]]?.values.rating == 3 && badges[ids[9]]?.values.customLabel == "Hero")
    }
}

import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization
import Testing
@_spi(Harness) @testable import RedlampUI

/// One name order (LIB-06, LIB-10): every list of the library's sorted by name, All Photographs, a collection, a smart
/// collection, a search and a folder shown from the library, small or large, with its subfolders or without, has its
/// photos in Folders' order, as `FolderScanner` lists them from the disk, for names with digits, punctuation, case and
/// accents.
@MainActor
@Suite(.serialized)
struct NameOrderTests {
    /// Names the query engine once ordered otherwise than Folders, and others like them, no two the same to Folders.
    static let names = [
        "DSC05507.JPG", "DSC_5513.JPG", "dsc_5514.jpg", "_DSC0001.JPG", "DSC-0002.JPG", "DSC 0003.JPG",
        "DSC.0004.JPG", "DSCF0005.JPG", "IMG_9.JPG", "IMG_10.JPG", "img_0010b.jpg", "IMG(1).JPG", "IMG~1.JPG",
        "IMG[2].JPG", "Café 2.jpg", "Café 10.jpg", "cafe 3.jpg", "Cafe.jpg", "Café_1.jpg", "Cafe01.jpg", "Été.jpg",
        "ete 2.jpg", "Etude.jpg", "Zoë.jpg", "Ångström.jpg", "東京.jpg", "Ｆｕｌｌ.jpg",
    ]
    /// Subfolders of the shoot whose names the two orders once took otherwise too.
    static let subfolders = ["Day 2", "Day 10", "Day_1", "Day-1", "Day1", "Été"]

    /// Every name in the shoot's folder, and four in each of its subfolders.
    static var paths: [String] {
        names.map { "Shoot/\($0)" } + subfolders.enumerated().flatMap { place, folder in
            (0 ..< 4).map { "Shoot/\(folder)/\(names[(place * 4 + $0 * 5) % names.count])" }
        }
    }

    /// The photos of the folder at `url` as Folders lists them from the disk: its own by name, then each subfolder's in
    /// turn, the subfolders by name.
    static func listed(_ url: URL, subfolders: Bool) throws -> [String] {
        let listing = try FolderScanner.list(url)
        let below = subfolders ? try listing.subfolders.flatMap { try listed($0, subfolders: true) } : []
        return listing.photos.map { $0.url.path(percentEncoded: false) } + below
    }

    /// The paths of the photos `ids`, in order, as the index has them.
    static func paths(of ids: some Sequence<Int64>, in index: LibraryIndex) async throws -> [String] {
        let ids = Array(ids)
        let found = try await index.read { reader in
            try reader.photosWithPaths(ids).reduce(into: [Int64: String]()) { paths, found in
                paths[found.photo.id] = found.folder + "/" + found.photo.name
            }
        }
        return ids.compactMap { found[$0] }
    }

    /// The photos of `list` in Folders' name order, those Folders takes as the same by their IDs.
    static func byName(_ list: PhotoList, in index: LibraryIndex) async throws -> [String] {
        let ids = Array(list.ids)
        let paths = try await paths(of: ids, in: index)
        return zip(ids, paths).sorted { lhs, rhs in
            let order = FileOrder.compare(Self.name(lhs.1), Self.name(rhs.1))
            return order == .orderedSame ? lhs.0 < rhs.0 : order == .orderedAscending
        }.map(\.1)
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// `folder`'s first change from the library, with its subfolders or without, every row read or as a large folder.
    static func opened(
        _ folder: URL, core: LibraryCore, subfolders: Bool, largestRead: Int,
    ) async throws -> LibraryFolderList.Change {
        let arrived = Mutex<LibraryFolderList.Change?>(nil)
        let list = LibraryFolderList(
            core: core, folder: folder, includingSubfolders: subfolders, largestRead: largestRead, firstRead: 2,
        ) { change in
            arrived.withLock { $0 = $0 ?? change }
        }
        defer { list.close() }
        try await SourcesSandbox.eventually { arrived.withLock { $0 != nil } }
        return try #require(arrived.withLock { $0 })
    }

    @Test func `every list sorted by name has its photos in Folders' order`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(Self.paths)
        let model = try await sandbox.open()
        let core = try #require(sandbox.service?.core)
        let (engine, index) = (core.engine, core.index)
        let name = QuerySort(.name)

        // All Photographs, and a search in it, once every photo is indexed.
        try await SourcesSandbox.eventually {
            try await engine.list(.allPhotographs, matching: .all).count == Self.paths.count
        }
        let all = try await engine.list(.allPhotographs, matching: .all, sort: name)
        #expect(all.count == Self.paths.count)
        var lists = [("All Photographs", all)]
        try await lists.append((
            "a search",
            engine.list(.allPhotographs, matching: LibraryQuery(parsing: "dsc"), sort: name),
        ))

        // A collection of every photo, and a smart collection of those named IMG in any case.
        let collection = try #require(CollectionPath(names: ["Every photo"]))
        #expect(model.libraryPanels.make(
            [.collections(.create(collection, .collection)), .collections(.add(Array(all.ids), to: collection))],
            title: "New collection", onSelection: false,
        ))
        #expect(model.librarySources.saveSmart("name:img", named: "IMG", inside: nil))
        await model.libraryPanels.written()
        let smart = try #require(CollectionPath(names: ["IMG"]))
        try await SourcesSandbox.eventually {
            let every = try await engine.list(.collection(collection), matching: .all).count
            let named = try await engine.list(.collection(smart), matching: .all).count
            return every == Self.paths.count && named > 0
        }
        try await lists.append(("a collection", engine.list(.collection(collection), matching: .all, sort: name)))
        try await lists.append(("a smart collection", engine.list(.collection(smart), matching: .all, sort: name)))
        for (title, list) in lists {
            let shown = try await Self.paths(of: list.ids, in: index)
            let expected = try await Self.byName(list, in: index)
            #expect(list.count > 4 && shown == expected, "\(title)")
        }

        // The shoot shown from the library, every row read and as a large folder, as Folders lists it from the disk.
        let shoot = sandbox.folder("Shoot")
        for subfolders in [true, false] {
            let disk = try Self.listed(shoot, subfolders: subfolders)
            let every = try await Self.opened(shoot, core: core, subfolders: subfolders, largestRead: .max)
            let items = try #require(every.all?.items)
            #expect(
                items.map { $0.url.path(percentEncoded: false) } == disk,
                "every row read, subfolders \(subfolders)",
            )
            let large = try await Self.opened(shoot, core: core, subfolders: subfolders, largestRead: 4)
            let ids = try #require(large.large?.list.ids)
            let shown = try await Self.paths(of: ids, in: index)
            #expect(shown == disk, "as a large folder, subfolders \(subfolders)")
        }
    }
}

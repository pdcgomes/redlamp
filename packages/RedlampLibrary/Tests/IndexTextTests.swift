import Foundation
import Testing
@testable import RedlampLibrary

struct IndexTextTests {
    @Test func `text search finds substrings of names, folders, keywords, titles, captions, cameras and lenses`(
    ) async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["2024/Lisbon Trip", "2024/Studio"])
        let (camera, lens) = try await sandbox.index.write { writer in
            try (writer.cameraID(for: "Fujifilm X-T5"), writer.lensID(for: "XF 35mm F1.4 R"))
        }
        let ids = try await sandbox.upsert([
            PhotoRecord(
                folder: #require(folders["2024/Lisbon Trip"]), name: "DSCF4821.RAF", camera: camera, lens: lens,
                title: "Tram 28", caption: "Alfama at dusk",
            ),
            PhotoRecord(folder: #require(folders["2024/Studio"]), name: "IMG_0001.CR3"),
        ])
        try await sandbox.index.write { try $0.setKeywords(["Places/Portugal"], forPhoto: ids[1]) }

        let searches = ["f482", "LISBON", "tram 2", "alfama", "x-t5", "35mm", "portugal", "studio", "img_0", "2024/"]
        let found = try await sandbox.index.read { reader in
            try searches.map { try reader.photoIDs(matching: $0) }
        }
        #expect(found == [
            [ids[0]],
            [ids[0]],
            [ids[0]],
            [ids[0]],
            [ids[0]],
            [ids[0]],
            [ids[1]],
            [ids[1]],
            [ids[1]],
            ids,
        ])
    }

    @Test func `text search follows a photo's renames, edits, keywords and deletion`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["Porto", "Faro"])
        let porto = try #require(folders["Porto"])
        let id = try #require(try await sandbox.upsert([PhotoRecord(folder: porto, name: "DSC_1234.NEF")]).first)
        func search(_ text: String) async throws -> [Int64] {
            try await sandbox.index.read { try $0.photoIDs(matching: text) }
        }
        #expect(try await search("1234") == [id])

        try await sandbox.upsert([PhotoRecord(folder: porto, name: "DSC_1234.NEF", caption: "Ribeira at night")])
        #expect(try await search("ribeira") == [id])
        #expect(try await search("1234") == [id], "an edit rewrites the whole row")

        let faro = try #require(folders["Faro"])
        try await sandbox.index.write { try $0.movePhoto(id, toFolder: faro, name: "Sunset.NEF") }
        #expect(try await search("1234").isEmpty)
        #expect(try await search("porto").isEmpty)
        #expect(try await search("sunset") == [id])
        #expect(try await search("faro") == [id])
        #expect(try await search("ribeira") == [id])

        try await sandbox.index.write { try $0.addKeyword("Events/Festival", toPhotos: [id]) }
        #expect(try await search("festival") == [id])
        try await sandbox.index.write { try $0.setKeywords([], forPhoto: id) }
        #expect(try await search("festival").isEmpty)
        #expect(try await search("sunset") == [id])

        try await sandbox.index.write { try $0.deletePhotos([id]) }
        #expect(try await search("sunset").isEmpty)
        #expect(try await search("faro").isEmpty)
    }

    @Test func `moved folders and photos carry their text with them`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folders = try await sandbox.addFolders(["Lisbon", "Lisbon/Day 1", "Porto"])
        let lisbon = try #require(folders["Lisbon"])
        let porto = try #require(folders["Porto"])
        let ids = try await sandbox.upsert([
            PhotoRecord(folder: #require(folders["Lisbon/Day 1"]), name: "IMG_0001.HEIC"),
            PhotoRecord(folder: porto, name: "IMG_0002.HEIC"), PhotoRecord(folder: porto, name: "IMG_0003.HEIC"),
        ])
        try await sandbox.index.write { writer in
            try writer.addKeyword("Birds/Herons", toPhotos: [ids[0]])
            try writer.moveFolder(lisbon, to: IndexSandbox.rootPath + "/Lisboa", parent: nil)
            try writer.movePhotos([(ids[1], lisbon, "Ribeira.HEIC"), (ids[2], porto, "Douro.HEIC")])
        }
        let searches = ["lisboa", "lisbon", "herons", "ribeira", "douro", "img_000"]
        let found = try await sandbox.index.read { reader in try searches.map { try reader.photoIDs(matching: $0) } }
        #expect(found == [[ids[0], ids[1]], [], [ids[0]], [ids[1]], [ids[2]], [ids[0]]])
    }

    @Test func `short text matches nothing, quotes are searched as written, and a column can be chosen`() async throws {
        let sandbox = try await IndexSandbox.make()
        defer { sandbox.remove() }
        let folder = try #require(try await sandbox.addFolders(["Tram"])["Tram"])
        let ids = try await sandbox.upsert([
            PhotoRecord(folder: folder, name: "The \"Tram\" 28.jpg"),
            PhotoRecord(folder: folder, name: "IMG_0002.jpg", caption: "tram stop"),
        ])
        let (short, quoted, inNames, inFolders, limited) = try await sandbox.index.read { reader in
            try (
                reader.photoIDs(matching: "tr"), reader.photoIDs(matching: "\"Tram\""),
                reader.photoIDs(matching: "tram", in: .name), reader.photoIDs(matching: "tram", in: .folder),
                reader.photoIDs(matching: "tram", limit: 1),
            )
        }
        #expect(short.isEmpty, "trigrams need three characters")
        #expect(quoted == [ids[0]])
        #expect(inNames == [ids[0]] && inFolders == ids && limited == [ids[0]])
    }
}

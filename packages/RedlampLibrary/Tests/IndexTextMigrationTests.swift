import Foundation
import Testing
@testable import RedlampLibrary

/// Version 7 of the index's schema (DEC-52): the text index built again with the trigram tokenizer's
/// `remove_diacritics 1`, its text folded by the writer as the small tables fold names, so names,
/// keywords, titles and captions are found without their accents or width.
struct IndexTextMigrationTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "redlamp-text-migration-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var url: URL {
        directory.appending(path: "Index.sqlite")
    }

    /// Photos whose text isn't all ASCII, each with text that finds it only once accents and width
    /// don't count.
    private static let accented: [(
        photo: (name: String, title: String?, caption: String?, keyword: String?),
        found: [String],
    )] = [
        (("SP-0001.JPG", nil, "Avenida Paulista, São Paulo", nil), ["sao paulo", "SÃO"]),
        (("ZH-0001.JPG", "Zu\u{308}richsee", nil, "Orte/Zürich"), ["zurich", "ZÜRICHSEE", "orte/zu"]),
        (("Café-0001.JPG", nil, nil, nil), ["cafe", "CAFÉ-0", "afe-00"]),
        (("IMG_0001.JPG", "ＦＵＬＬ ＷＩＤＴＨ", "ｶﾀｶﾅの夜", "ＴＯＫＹＯ"), ["full width", "ｆｕｌｌ", "tokyo", "カタカナ"]),
        (("Ακρόπολη.JPG", nil, "Hội An at dusk", nil), ["ακροπολη", "hoi an", "HỘI"]),
    ]

    /// An index at version 6: synthetic photos, a third with a keyword, and the accented ones, their
    /// text in `photo_text` as version 6's writer put it there, unfolded.
    private func makeVersion6() async throws -> (ids: [Int64], accented: [Int64]) {
        let index = try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(6)))
        defer { index.closeAndWait() }
        let (ids, accented) = try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "MIGRATION", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/Photos"))
            let folder = try writer.upsertFolder(FolderRecord(root: root, path: "/Volumes/Test/Photos/2024"))
            let cameras = try SyntheticIndexPhotos.cameras.map { try writer.cameraID(for: $0) }
            let lenses = try SyntheticIndexPhotos.lenses.map { try writer.lensID(for: $0) }
            var synthetic = SyntheticIndexPhotos(seed: 7, cameraIDs: cameras, lensIDs: lenses)
            let ids = try writer.upsertPhotos((1 ... 3000).map { synthetic.photo($0, in: folder) })
            for (number, id) in ids.enumerated() where number % 3 == 0 {
                try writer.setKeywords(["Events/Festival \(number % 40)"], forPhoto: id)
            }
            let accented = try writer.upsertPhotos(Self.accented.map { photo, _ in
                PhotoRecord(folder: folder, name: photo.name, title: photo.title, caption: photo.caption)
            })
            for (id, (photo, _)) in zip(accented, Self.accented) {
                if let keyword = photo.keyword {
                    try writer.setKeywords([keyword], forPhoto: id)
                }
            }
            try writer.database.execute("""
            DELETE FROM photo_text;
            INSERT INTO photo_text (rowid, name, keywords, title, caption)
              SELECT id, name, keywords, title, caption FROM photo_text_rows;
            """)
            return (ids, accented)
        }
        return (ids, accented)
    }

    /// What each photo's text should find it by: its name, its caption, and its keyword's last level.
    private static func searches(of index: LibraryIndex, _ ids: [Int64]) async throws -> [Int64: [String]] {
        try await index.read { reader in
            var searches: [Int64: [String]] = [:]
            for id in ids {
                guard let photo = try reader.photo(id: id) else { continue }
                let keywords = try reader.keywords(forPhoto: id).compactMap { $0.split(separator: "/").last }
                searches[id] = [photo.name, photo.caption].compactMap(\.self) + keywords.map(String.init)
            }
            return searches
        }
    }

    @Test func `the migration keeps every photo's text searchable, and accents and width stop counting`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (ids, accented) = try await makeVersion6()
        let old = try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(6)))
        let searches = try await Self.searches(of: old, ids)
        let before = try await old.read { reader in
            try Set(searches.keys).sorted()
                .map { id in try searches[id, default: []].map { try reader.photoIDs(matching: $0) } }
        }
        let foundBefore = try await old.read { reader in
            try Self.accented.map { _, found in try found.map { try reader.photoIDs(matching: $0) } }
        }
        await old.close()
        let noneBefore = foundBefore.joined().allSatisfy(\.isEmpty)
        #expect(noneBefore, "version 6 finds none of them: \(foundBefore)")

        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        let (version, tokenizer) = try await index.read { reader in
            try (
                reader.database.userVersion,
                reader.database.prepare("SELECT sql FROM sqlite_master WHERE name = 'photo_text'").first {
                    $0.string(at: 0) ?? ""
                },
            )
        }
        #expect(version == LibraryIndex.migrations.count && version == 7)
        #expect(tokenizer?.contains("tokenize='trigram remove_diacritics 1'") == true)

        let after = try await index.read { reader in
            try Set(searches.keys).sorted()
                .map { id in try searches[id, default: []].map { try reader.photoIDs(matching: $0) } }
        }
        #expect(after == before, "every search finds what it found before the migration")
        for (place, id) in Set(searches.keys).sorted().enumerated() {
            let findsIt = after[place].allSatisfy { $0.contains(id) }
            #expect(findsIt, "photo \(id) by \(searches[id] ?? [])")
        }
        let found = try await index.read { reader in
            try Self.accented.map { _, found in try found.map { try reader.photoIDs(matching: $0) } }
        }
        for (place, id) in accented.enumerated() {
            for (text, photos) in zip(Self.accented[place].found, found[place]) {
                #expect(photos == [id], "\(text) finds \(Self.accented[place].photo.name)")
            }
        }
    }

    @Test func `the writer folds what it writes after the migration, as the typed text is folded`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeVersion6()
        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        let id = try await index.write { writer in
            let folder = try #require(try writer.folder(path: "/Volumes/Test/Photos/2024")?.id)
            let id = try writer.upsertPhotos([PhotoRecord(folder: folder, name: "Ärzte.JPG", caption: "Ｓｅｓｓｉｏｎ")])[0]
            try writer.setKeywords(["Música/Fado"], forPhoto: id)
            return id
        }
        let searches = ["arzte", "ÄRZTE.jpg", "session", "ＳＥＳＳ", "musica/fado", "MÚSICA"]
        let found = try await index.read { reader in try searches.map { try reader.photoIDs(matching: $0) } }
        #expect(found == Array(repeating: [id], count: searches.count))
        let columns = try await index.read { reader in
            try (reader.photoIDs(matching: "arz", in: .name), reader.photoIDs(matching: "arz", in: .caption))
        }
        #expect(columns.0 == [id] && columns.1.isEmpty)
    }
}

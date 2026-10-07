import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Text ignores accents and width everywhere (DEC-45): a name typed without its accents, or in
/// ordinary letters where the library has full-width ones, finds its photos, and the other way
/// round, through the column store and the SQL alike.
struct QueryAccentTests {
    /// Five photos: in São Paulo, Zürich (its folder's name decomposed), a café, a folder named in
    /// full-width letters, and one with the same names in plain letters.
    struct Library {
        let sandbox: IndexSandbox
        /// Photo IDs, by number from 1.
        let ids: [Int64]

        static func make() async throws -> Library {
            let sandbox = try await IndexSandbox.make()
            let folders = try await sandbox.addFolders([
                "Viagens", "Viagens/São Paulo 2019", "Reisen", "Reisen/Zu\u{308}rich", "Cafés", "ＴＯＫＹＯ", "Plain",
            ])
            let ids = try await sandbox.index.write { writer in
                let ids = try writer.upsertPhotos([
                    PhotoRecord(
                        folder: #require(folders["Viagens/São Paulo 2019"]), name: "SP-0001.JPG",
                        title: "Avenida Paulista à noite", caption: "Café da manhã em São Paulo",
                        customLabel: "Célèbre", creator: "João Costa",
                        location: PhotoLocation(country: "Brasil", city: "São Paulo"),
                    ),
                    PhotoRecord(
                        folder: #require(folders["Reisen/Zu\u{308}rich"]), name: "ZH-0001.JPG", title: "Zürichsee",
                        caption: "Grossmu\u{308}nster", location: PhotoLocation(country: "Schweiz", city: "Zürich"),
                    ),
                    PhotoRecord(folder: #require(folders["Cafés"]), name: "Café-0001.JPG", title: "Au lait"),
                    PhotoRecord(
                        folder: #require(folders["ＴＯＫＹＯ"]), name: "IMG_0001.JPG", title: "ＦＵＬＬ ＷＩＤＴＨ",
                        caption: "ｶﾀｶﾅ", creator: "ＡＣＭＥ", location: PhotoLocation(city: "Ｔｏｋｙｏ"),
                    ),
                    PhotoRecord(
                        folder: #require(folders["Plain"]), name: "Plain.JPG", title: "Full width",
                        caption: "Zurich lake, Sao Paulo cafe", customLabel: "Celebre", creator: "Joao",
                        location: PhotoLocation(city: "Zurich"),
                    ),
                ])
                let keywords = [["Lugares/Brasil/São Paulo"], ["Orte/Zu\u{308}rich"], ["Café"], ["ＴＯＫＹＯ"], [
                    "Sao Paulo",
                    "Tokyo",
                ]]
                let collections = [["Viagens/São Paulo"], ["Reisen/Zürich"], ["Cafés"], ["ＴＯＫＹＯ"], ["Sao Paulo"]]
                for (number, id) in ids.enumerated() {
                    try writer.setKeywords(keywords[number], forPhoto: id)
                    try writer.setCollections(collections[number], forPhoto: id)
                }
                return ids
            }
            return Library(sandbox: sandbox, ids: ids)
        }

        /// The photos each engine finds for `text`, by number.
        func numbers(_ text: String) async throws -> (columns: [Int], sql: [Int]) {
            var found: [[Int]] = []
            for loaded in [true, false] {
                let engine = QueryEngine(index: sandbox.index, timeZone: .gmt)
                if loaded {
                    try await engine.load()
                }
                let ids = try await engine.ids(text, sort: QuerySort(.name))
                found.append(ids.map { id in (self.ids.firstIndex(of: id) ?? -1) + 1 }.sorted())
            }
            return (found[0], found[1])
        }
    }

    static let smallTables: [(String, [Int])] = [
        ("in:sao", [1]),
        ("in:\"são paulo\"", [1]),
        ("in:zurich", [2]),
        ("in:ZÜRICH", [2]),
        ("in:cafes", [3]),
        ("in:tokyo", [4]),
        ("in:ｐｌａｉｎ", [5]),
        ("kw:\"sao paulo\"", [1, 5]),
        ("kw:\"são paulo\"", [1, 5]),
        ("kw:zurich", [2]),
        ("kw:ZÜRICH", [2]),
        ("kw:cafe", [3]),
        ("kw:tokyo", [4, 5]),
        ("kw:ＴＯＫＹＯ", [4, 5]),
        ("kw:\"Lugares/Brasil/Sao Paulo\"", [1]),
        ("collection:\"sao paulo\"", [1, 5]),
        ("collection:\"Viagens/Sao Paulo\"", [1]),
        ("collection:zurich", [2]),
        ("collection:cafes", [3]),
        ("collection:tokyo", [4]),
        ("creator:joao", [1, 5]),
        ("creator:joão", [1, 5]),
        ("creator:acme", [4]),
        ("city:sao", [1]),
        ("city:zürich", [2, 5]),
        ("city:tokyo", [4]),
        ("label:celebre", [1, 5]),
        ("label:CÉLÈBRE", [1, 5]),
    ]

    @Test func `folders, keywords, collections, creators, places and labels match without accents or width`(
    ) async throws {
        let library = try await Library.make()
        defer { library.sandbox.remove() }
        for (text, expected) in Self.smallTables {
            let (columns, sql) = try await library.numbers(text)
            #expect(columns == expected, "\(text) with the column store")
            #expect(sql == expected, "\(text) with SQL")
        }
    }

    static let textIndex: [(String, [Int])] = [
        ("title:zurich", [2]),
        ("title:\"full width\"", [4, 5]),
        ("title:ｆｕｌｌ", [4, 5]),
        ("title:\"paulista a noite\"", [1]),
        ("caption:\"sao paulo\"", [1, 5]),
        ("caption:são", [1, 5]),
        ("caption:grossmunster", [2]),
        ("caption:GROSSMÜNSTER", [2]),
        ("caption:カタカナ", [4]),
        ("name:cafe", [3]),
        ("name:CAFÉ-0", [3]),
        ("zurichsee", [2]),
        ("grossmünster", [2]),
        ("cafe", [1, 3, 5]),
        ("\"sao paulo\"", [1, 5]),
        ("tokyo", [4, 5]),
        ("\"brasil/sao\"", [1]),
        ("ＷＩＤＴＨ", [4, 5]),
    ]

    @Test func `names, keywords, titles and captions match without accents or width, through the text index`(
    ) async throws {
        let library = try await Library.make()
        defer { library.sandbox.remove() }
        for (text, expected) in Self.textIndex {
            let (columns, sql) = try await library.numbers(text)
            #expect(columns == expected, "\(text) with the column store")
            #expect(sql == expected, "\(text) with SQL")
        }
    }
}

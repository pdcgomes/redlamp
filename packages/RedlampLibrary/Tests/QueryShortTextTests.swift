import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Free text under three characters (LIB-06): too short for the text index's trigrams, it still finds
/// folders, cameras, lenses, creators and places by name, and keywords by their synonyms
/// (`KeywordQueryTests`), through the column store and the SQL alike; only names, keywords, titles
/// and captions wait for a third character.
struct QueryShortTextTests {
    /// Six photos: in a folder named in Japanese, in a lab, and four in Misc, one of them named and
    /// captioned with `ab`, one by Abel, one taken in Abu Dhabi.
    static func make() async throws -> (IndexSandbox, [Int64]) {
        let sandbox = try await IndexSandbox.make()
        let folders = try await sandbox.addFolders(["Trips", "Trips/東京駅 2019", "Lab Tests", "Misc"])
        let ids = try await sandbox.index.write { writer in
            let (z8, r5) = try (writer.cameraID(for: "NIKON Z 8"), writer.cameraID(for: "Canon EOS R5"))
            let (nikkor, rf) = try (
                writer.lensID(for: "NIKKOR Z 24-70mm f/2.8 S"),
                writer.lensID(for: "RF24-70mm F2.8"),
            )
            let misc = try #require(folders["Misc"])
            return try writer.upsertPhotos([
                PhotoRecord(
                    folder: #require(folders["Trips/東京駅 2019"]), name: "DSC_0001.NEF", camera: z8, lens: nikkor,
                    rating: 3,
                ),
                PhotoRecord(
                    folder: #require(folders["Lab Tests"]),
                    name: "IMG_0002.CR3",
                    camera: r5,
                    lens: rf,
                    rating: 1,
                ),
                PhotoRecord(folder: misc, name: "ABC_0003.JPG", rating: 3, title: "ab", caption: "about ab"),
                PhotoRecord(folder: misc, name: "IMG_0004.JPG", creator: "Abel Silva"),
                PhotoRecord(
                    folder: misc, name: "IMG_0005.JPG",
                    location: PhotoLocation(country: "United Arab Emirates", city: "Abu Dhabi", countryCode: "AE"),
                ),
                PhotoRecord(folder: misc, name: "IMG_0006.JPG"),
            ])
        }
        return (sandbox, ids)
    }

    static let cases: [(String, [Int])] = [
        ("ab", [2, 4, 5]),
        ("abc", [3]),
        ("ab rating:1", [2]),
        ("ab rating:3", []),
        ("-ab", [1, 3, 6]),
        ("ab OR 東京", [1, 2, 4, 5]),
        ("東京", [1]),
        ("京駅", [1]),
        ("r5", [2]),
        ("z", [1]),
        ("rf", [2]),
        ("ae", [5]),
        ("title:ab", [1, 2, 3, 4, 5, 6]),
        ("caption:ab rating:3", [1, 3]),
        ("name:abc", [3]),
    ]

    @Test func `ab finds folders, cameras, lenses, creators and places while the text index is left out`() async throws {
        let (sandbox, ids) = try await Self.make()
        defer { sandbox.remove() }
        let sql = QueryEngine(index: sandbox.index, timeZone: .gmt)
        let columns = QueryEngine(index: sandbox.index, timeZone: .gmt)
        try await columns.load()
        func numbers(_ found: [Int64]) -> [Int] {
            found.map { id in (ids.firstIndex(of: id) ?? -1) + 1 }.sorted()
        }
        for (text, expected) in Self.cases {
            #expect(try await numbers(columns.ids(text)) == expected, "\(text) with the column store")
            #expect(try await numbers(sql.ids(text)) == expected, "\(text) with SQL")
        }
    }
}

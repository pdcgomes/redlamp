import Foundation
import Testing
@testable import RedlampLibrary

/// `redlamp library search`, which prints `LibrarySearch`'s lines or its JSON, with the organising
/// fields the sidecars hold: creators, copyrights, locations, custom labels and collections.
struct LibrarySearchTests {
    private static func path(_ path: String) -> String {
        IndexSandbox.rootPath + "/" + path
    }

    @Test func `the search command finds photos by creator, location, custom label and collection`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let cases: [(String, [String])] = [
            ("creator:ana city:lisboa", ["2024/Lisbon Trip/DSCF0001.RAF", "2024/Lisbon Trip/DSCF0002.RAF"]),
            ("country:canada", ["Voyages/Été à Montréal 2014/Café-0001.JPG"]),
            ("label:approved", ["2024/Studio/IMG_0009.HEIC"]),
            ("collection:\"AC/DC\"", ["2019/Algarve/DSC_0100.NEF"]),
            ("has:copyright -has:gps", ["2024/Studio/IMG_0010.CR3"]),
            ("marinha", ["2019/Algarve/Sunset.JPG"]),
        ]
        for (text, expected) in cases {
            let query = try LibraryQuery(parsing: text)
            let search = try await LibrarySearch.run(query, index: library.index)
            #expect(search.paths == expected.map(Self.path), "\(text)")
            #expect(search.count == expected.count)
            let lines = search.lines()
            #expect(lines.dropLast() == search.paths[...])
            let photos = expected.count == 1 ? "1 photo" : "\(expected.count) photos"
            #expect(lines.last?.hasPrefix("\(photos) for \(query), sorted by captured, in ") == true, "\(lines)")
        }
    }

    @Test func `the search command searches a smart collection's photos, or a set's`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let definitions = try CollectionDefinitions(collections: [
            #require(CollectionPath("Picks")): .set,
            #require(CollectionPath("Picks/Portugal")): .smart("country:portugal rating>=3"),
        ])
        try definitions.save(to: CollectionDefinitions.url(in: LibraryPaths(root: library.sandbox.directory)))
        let smart = try await LibrarySearch.run(.all, in: CollectionPath("Picks/Portugal"), index: library.index)
        #expect(try await library.numbers(library.index.read { reader in
            try smart.paths.compactMap { try reader.photo(path: $0)?.id }
        }) == [5, 1, 2])
        #expect(smart.summary.hasPrefix("3 photos for everything in “Picks › Portugal”, sorted by captured, in "))
        let picked = try await LibrarySearch.run(
            LibraryQuery(parsing: "has:gps"), in: CollectionPath("Picks"), index: library.index,
        )
        #expect(picked.count == 2 && picked.summary.hasPrefix("2 photos for has:gps in “Picks”"))
        let portfolio = try await LibrarySearch.run(.all, in: CollectionPath("Portfolio"), index: library.index)
        #expect(portfolio.paths == ["2024/Lisbon Trip/DSCF0001.RAF", "2024/Studio/IMG_0010.CR3"].map(Self.path))
        let json = try #require(try JSONSerialization.jsonObject(with: portfolio.json()) as? [String: Any])
        #expect(json["collection"] as? String == "Portfolio" && json["count"] as? Int == 2)
    }

    @Test func `the search command's JSON and its limit`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let query = try LibraryQuery(parsing: "country:portugal")
        let search = try await LibrarySearch.run(
            query, sort: QuerySort(.name, ascending: false), limit: 2, index: library.index,
        )
        #expect(search.count == 4 && search.paths.count == 2)
        #expect(search.summary.hasPrefix("4 photos for country:portugal, sorted by name, descending, in "))
        #expect(search.summary.hasSuffix("; the first 2 shown"))
        let json = try #require(try JSONSerialization.jsonObject(with: search.json()) as? [String: Any])
        #expect(json["query"] as? String == "country:portugal" && json["count"] as? Int == 4)
        #expect(json["sort"] as? String == "name" && json["ascending"] as? Bool == false)
        #expect(json["paths"] as? [String] == search.paths)
        #expect(search.paths == ["2019/Algarve/Sunset.JPG", "2024/Studio/IMG_0010.CR3"].map(Self.path))
    }
}

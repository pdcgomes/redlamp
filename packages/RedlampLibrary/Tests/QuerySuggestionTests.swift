import Foundation
import Testing
@testable import RedlampLibrary

/// A filter that finds nothing (LIB-18) offers a name a typo or two from a word of a term, with the
/// photos it brings back, as it names the term whose removal brings back the most.
struct QuerySuggestionTests {
    @Test func `a filter that finds nothing offers a name a typo from its text, and the photos it brings back`(
    ) async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let text = try #require(await engine.suggestion(for: LibraryQuery(parsing: "lisbao"), in: .allPhotographs))
        #expect(text.name == "Lisboa" && text.term == "Lisboa" && text.typos == 1 && text.index == 0)
        #expect(text.rule == .text("lisbao", contains: true))
        #expect(try await engine.ids(text.query.description).count == text.count && text.count == 2)

        let camera = try #require(await engine.suggestion(
            for: LibraryQuery(parsing: "rating>=0 camera:fujiflim"), in: .allPhotographs,
        ))
        #expect(camera.term == "camera:Fujifilm" && camera.index == 1 && camera.count == 3)
        #expect(camera.query.description == "rating>=0 camera:Fujifilm")

        let keyword = try #require(await engine.suggestion(for: LibraryQuery(parsing: "kw:birdz"), in: .allPhotographs))
        #expect(keyword.term == "kw:Birds" && keyword.count > 0)
        #expect(try await engine.ids(keyword.query.description).count == keyword.count)

        let folder = try #require(await engine.suggestion(
            for: LibraryQuery(parsing: "in:\"2024/lisbom trip\""), in: .allPhotographs,
        ))
        #expect(folder.term == "folder:\"2024/Lisbon trip\"" && folder.name == "Lisbon", "the rest of the text kept")

        let label = try #require(await engine.suggestion(
            for: LibraryQuery(parsing: "label:yelow"),
            in: .allPhotographs,
        ))
        #expect(label.term == "label:yellow" && label.replacement == .filter(
            LibraryQuery.Filter(.label, .equal, [.label(.yellow)]), negated: false,
        ), "a colour's name read as the colour")
    }

    @Test func `the source's photos decide, and the fewest typos win`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let studio = PhotoSource.folder(
            URL(fileURLWithPath: IndexSandbox.rootPath + "/2024/Studio", isDirectory: true), includingSubfolders: false,
        )
        #expect(
            try await engine.suggestion(for: LibraryQuery(parsing: "lisbao"), in: studio) == nil,
            "Lisboa's photos aren't in the studio",
        )
        let porto = try await engine.suggestion(for: LibraryQuery(parsing: "portp"), in: studio)
        #expect(porto?.name == "Porto" && porto?.count == 1)
    }

    @Test func `no suggestion when the filter finds photos, no name is near, or its terms needn't all match`(
    ) async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        for text in ["lisboa", "zzzzzz", "lisbao OR kw:birdz", "lsb", "-lisbao kw:zzzz", "kisboa"] {
            #expect(
                try await engine.suggestion(for: LibraryQuery(parsing: text), in: .allPhotographs) == nil,
                "\(text)",
            )
        }
    }
}

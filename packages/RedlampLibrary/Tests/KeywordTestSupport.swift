import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

/// Photos in a folder of their own with their sidecars, and an index of them in a library folder of
/// its own, for the keyword tests.
struct KeywordSandbox {
    let folder: TemporaryFolder
    let library: TemporaryFolder
    let index: LibraryIndex

    var root: URL {
        folder.url
    }

    var paths: LibraryPaths {
        LibraryPaths(root: library.url)
    }

    static func make() async throws -> KeywordSandbox {
        let library = try TemporaryFolder()
        let index = try await LibraryIndex.open(at: library.url.appending(path: "Index.sqlite"), readers: 2)
        return try KeywordSandbox(folder: TemporaryFolder(), library: library, index: index)
    }

    func remove() {
        index.closeAndWait()
    }

    func keywords(live: LibraryLive? = nil) -> LibraryKeywords {
        LibraryKeywords(index: index, live: live)
    }

    func url(_ path: String) -> URL {
        root.appending(path: path)
    }

    /// A photo's bytes at `path`, which the library indexes though ImageIO can't read them; with a
    /// sidecar holding `keywords` when they're given.
    @discardableResult
    func photo(_ path: String, keywords: [String]? = nil, rating: Int = 0) throws -> URL {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an image: \(path)".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: file.path,
        )
        if keywords != nil || rating > 0 {
            try sidecar(path, PhotoMetadata(rating: rating, keywords: keywords))
        }
        return file
    }

    /// Saves `metadata` in the photo's `.redlamp`, with an edit and a field a newer Redlamp wrote,
    /// which keyword changes must keep.
    func sidecar(_ path: String, _ metadata: PhotoMetadata) throws {
        var recipe = EditRecipe()
        recipe[.exposure] = 0.35
        var sidecar = Sidecar(recipe: recipe, metadata: metadata, modified: Date(timeIntervalSinceNow: -3600))
        sidecar.unknownFields = ["fromTheFuture": .string("kept")]
        try SidecarStore().save(sidecar, for: url(path))
    }

    /// The keywords the photo's sidecar holds; nil when it holds none, or has no sidecar.
    func sidecarKeywords(_ path: String) -> [String]? {
        SidecarStore().load(for: url(path))?.metadata?.keywords
    }

    func sidecar(_ path: String) -> Sidecar? {
        SidecarStore().load(for: url(path))
    }

    func indexAll() async throws {
        let run = await IndexerRun.collect(LibraryIndexer(index: index, configuration: .testing()).index([root]))
        #expect(run.failures.isEmpty, "\(run.failures)")
    }

    func id(_ path: String) async throws -> Int64 {
        let full = LibraryIndexer.path(url(path))
        return try #require(try await index.read { try $0.photo(path: full) }?.id)
    }

    func ids(_ paths: [String]) async throws -> [Int64] {
        var ids: [Int64] = []
        for path in paths {
            try await ids.append(id(path))
        }
        return ids
    }

    /// The photo's keywords in the index, by text, sorted.
    func indexed(_ path: String) async throws -> [String] {
        let id = try await id(path)
        return try await index.read { try $0.keywords(forPhoto: id) }.sorted()
    }

    /// The photos `query` finds, by name, with the column store and with SQL alone: both must agree.
    func search(_ query: String) async throws -> [String] {
        let parsed = try LibraryQuery(parsing: query)
        let sql = QueryEngine(index: index)
        var bySQL: [Int64] = []
        for try await result in sql.search(parsed) {
            bySQL = Array(result.ids)
        }
        let engine = QueryEngine(index: index)
        try await engine.load()
        var byStore: [Int64] = []
        for try await result in engine.search(parsed) {
            byStore = Array(result.ids)
        }
        #expect(Set(bySQL) == Set(byStore), "\(query): SQL and the column store disagree")
        let ids = byStore
        return try await index.read { reader in
            try ids.compactMap { try reader.photo(id: $0)?.name }.sorted()
        }
    }
}

/// The keyword at `text`, a path with no empty names.
func kw(_ text: String) -> KeywordPath {
    KeywordPath(text)!
}

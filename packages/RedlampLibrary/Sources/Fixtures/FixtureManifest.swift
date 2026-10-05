import Foundation

/// What a fixture holds, from the generator's own choices: its totals, every folder's photos,
/// and how many photos each query of the corpus must return. Written last, as
/// `manifest.json` in the fixture's root, so a fixture without one is unfinished.
public struct FixtureManifest: Sendable, Hashable, Codable {
    public static let fileName = "manifest.json"
    public static let format = "app.redlamp.library-fixture"

    public var format = FixtureManifest.format
    public var version = 1
    public var spec: LibraryFixture.Spec
    /// The raws the fixture's raws are clones of, by name.
    public var rawSources: [String]
    public var totals: Totals
    /// Every folder below the root, those holding only folders included, by path.
    public var folders: [Folder]
    public var queries: [Query]

    public struct Totals: Sendable, Hashable, Codable {
        public var photos = 0
        public var raws = 0
        public var jpegs = 0
        public var heics = 0
        /// `.redlamp` sidecars, and those of them holding an edit.
        public var sidecars = 0
        public var edited = 0
        /// Other apps' `.xmp` sidecars.
        public var xmpSidecars = 0
        public var withLocation = 0
        /// Photos with keywords, in the file or in an `.xmp`.
        public var withKeywords = 0
        public var withCaption = 0
        public var folders = 0
        /// Photos that are copies of another photo of the fixture, byte for byte (LIB-39): what
        /// removing every copy but one would remove. Nil in a fixture made without them.
        public var duplicates: Int?

        public init() {}

        mutating func add(_ photo: FixturePhoto) {
            photos += 1
            switch photo.kind {
            case .raw: raws += 1
            case .jpeg: jpegs += 1
            case .heic: heics += 1
            }
            sidecars += photo.sidecar == nil ? 0 : 1
            edited += photo.isEdited ? 1 : 0
            xmpSidecars += photo.xmp == nil ? 0 : 1
            withLocation += photo.location == nil ? 0 : 1
            withKeywords += photo.keywords.isEmpty ? 0 : 1
            withCaption += photo.caption == nil ? 0 : 1
            if photo.original != nil {
                duplicates = (duplicates ?? 0) + 1
            }
        }

        mutating func add(_ other: Totals) {
            photos += other.photos
            raws += other.raws
            jpegs += other.jpegs
            heics += other.heics
            sidecars += other.sidecars
            edited += other.edited
            xmpSidecars += other.xmpSidecars
            withLocation += other.withLocation
            withKeywords += other.withKeywords
            withCaption += other.withCaption
            if let copies = other.duplicates {
                duplicates = (duplicates ?? 0) + copies
            }
        }
    }

    public struct Folder: Sendable, Hashable, Codable {
        /// Below the fixture's root, `/`-separated.
        public var path: String
        /// Photos in the folder itself, not in its subfolders.
        public var photos: Int
    }

    public struct Query: Sendable, Hashable, Codable {
        public var query: String
        public var count: Int
    }

    public static func load(from fixture: URL) throws -> FixtureManifest {
        try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: fixture.appending(path: fileName)))
    }

    public func write(to fixture: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: fixture.appending(path: Self.fileName), options: .atomic)
    }

    /// A query's count, by its text.
    public func count(of query: String) -> Int? {
        queries.first { $0.query == query }?.count
    }
}

extension LibraryFixture {
    /// The manifest, from the photos' records alone; `write(to:)` makes the same one.
    public func manifest() -> FixtureManifest {
        var tally = Tally(queries: FixtureQuery.corpus.count)
        for folder in folders {
            for photo in photos(in: folder) {
                tally.add(photo)
            }
        }
        return manifest(tally)
    }

    func manifest(_ tally: Tally) -> FixtureManifest {
        let counts = Dictionary(folders.map { ($0.path, $0.photos.count) }) { first, _ in first }
        var totals = tally.totals
        let paths = allFolderPaths
        totals.folders = paths.count
        if spec.duplicateShare != nil {
            totals.duplicates = totals.duplicates ?? 0
        }
        return FixtureManifest(
            spec: spec,
            rawSources: rawSources.map(\.name),
            totals: totals,
            folders: paths.map { FixtureManifest.Folder(path: $0, photos: counts[$0] ?? 0) },
            queries: zip(FixtureQuery.corpus, tally.queries).map { FixtureManifest.Query(query: $0.text, count: $1) },
        )
    }

    /// Counts kept while photos are made, merged across the cores that made them.
    struct Tally: Sendable {
        var totals = FixtureManifest.Totals()
        var queries: [Int]

        init(queries: Int) {
            self.queries = Array(repeating: 0, count: queries)
        }

        mutating func add(_ photo: FixturePhoto) {
            totals.add(photo)
            for (index, query) in FixtureQuery.corpus.enumerated() where query.matches(photo) {
                queries[index] += 1
            }
        }

        mutating func add(_ other: Tally) {
            totals.add(other.totals)
            for index in queries.indices {
                queries[index] += other.queries[index]
            }
        }
    }
}

import Foundation

/// What a Lightroom Classic catalog would bring into the library, and what it wouldn't and why
/// (LIB-29): worked out before anything is written, from the catalog and the index as they are.
public struct LightroomReport: Sendable, Hashable, Codable {
    /// A root folder of the catalog, and where it is on this Mac.
    public struct Root: Sendable, Hashable, Codable, Identifiable {
        public enum State: String, Sendable, Hashable, Codable {
            /// In a folder of the library: its photos are found in the index.
            case inLibrary
            /// On this Mac but not in the library yet: importing adds it, and its photos once it's indexed.
            case notInLibrary
            /// Not where the catalog says, nor beside the catalog where it says: it has to be located.
            case missing
        }

        public var id: Int64
        public var name: String
        /// Where the catalog says it is.
        public var lightroomPath: String
        /// Where it is on this Mac, when it's found.
        public var path: String?
        /// It was found beside the catalog, or the user said where it is now, not where the catalog says.
        public var moved: Bool
        public var state: State
        /// The catalog's photos in it, virtual copies aside.
        public var photos: Int
        /// Of those, the photos the library has.
        public var found: Int
    }

    /// How many photos have each field Lightroom gives them; with `differing`, how many of those show
    /// another value in the library now, which Lightroom's replaces.
    public struct Fields: Sendable, Hashable, Codable {
        public var ratings = 0
        public var picks = 0
        public var rejects = 0
        public var labels = 0
        public var customLabels = 0
        /// In Lightroom's Quick Collection, which is Redlamp's mark.
        public var marks = 0
        public var titles = 0
        public var captions = 0
        public var creators = 0
        public var copyrights = 0
        public var locations = 0
        public var keywords = 0
        public var collections = 0

        public init() {}
    }

    /// A smart collection, and what became of its rules.
    public struct Smart: Sendable, Hashable, Codable {
        /// Its place in the collection list, as Redlamp writes it.
        public var path: String
        public var query: String?
        public var differences: [String] = []
        public var reasons: [String] = []
    }

    /// Something the catalog holds that doesn't come across, with how many and why.
    public struct Left: Sendable, Hashable, Codable {
        public var what: String
        public var count: Int
        public var why: String
    }

    public var catalog: String
    public var version: String?
    public var roots: [Root] = []
    /// The catalog's photos, virtual copies aside.
    public var photos = 0
    /// Of those, the photos the library has, matched by path.
    public var found = 0
    /// In root folders not in the library yet: importing adds the folders and finds them once indexed.
    public var waiting = 0
    /// In root folders that weren't found.
    public var unlocated = 0
    /// In the library's folders, but not on disk or not indexed: paths, the first `listed` of them.
    public var notFound = 0
    public var notFoundPaths: [String] = []
    /// JPEGs Lightroom keeps as one photo with their raws, which get their raws' fields as Redlamp keeps
    /// a pair together.
    public var pairs = 0
    /// Lightroom's values by field, for the photos found.
    public var fields = Fields()
    /// Of `fields`, those whose photos show another value in the library now.
    public var differing = Fields()
    /// The photos found whose fields change.
    public var changing = 0
    public var keywords = 0
    public var synonyms = 0
    /// Keywords Lightroom doesn't export, and people's names.
    public var notExported = 0
    public var people = 0
    public var collections = 0
    public var sets = 0
    public var smart: [Smart] = []
    /// Books, slideshows, prints and web galleries, brought across as collections of their photos.
    public var outputs: [String] = []
    /// Collections renamed because the library has another kind of thing at their place, before and after.
    public var renamed: [String: String] = [:]
    public var left: [Left] = []
    /// What the catalog lacked or how it was read, in words.
    public var notes: [String] = []

    /// Paths listed of the photos not found.
    public static let listed = 20

    /// The smart collections brought across, and those that aren't.
    public var smartMapped: [Smart] {
        smart.filter { $0.query != nil }
    }

    public var smartLeft: [Smart] {
        smart.filter { $0.query == nil }
    }

    /// Whether importing would change nothing: no photo found, no keyword and no collection to bring.
    public var isEmpty: Bool {
        changing == 0 && keywords == 0 && collections == 0 && sets == 0 && smartMapped.isEmpty
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public extension LightroomReport {
    /// The report in lines, as `redlamp library lightroom` prints it.
    func lines() -> [String] {
        var lines = ["\(catalog): Lightroom Classic catalog\(version.map { " version \($0)" } ?? "")"]
        lines.append("  \(Self.count(photos)) photos; \(Self.count(found)) found in the library"
            + (waiting > 0 ? ", \(Self.count(waiting)) in folders it doesn't have yet" : "")
            + (unlocated > 0 ? ", \(Self.count(unlocated)) in folders not found" : "")
            + (notFound > 0 ? ", \(Self.count(notFound)) not found" : ""))
        lines.append("  root folders:")
        for root in roots {
            let state = switch root.state {
            case .inLibrary: "in the library, \(Self.count(root.found)) of \(Self.count(root.photos)) photos found"
            case .notInLibrary: "not in the library yet: importing adds it (\(Self.count(root.photos)) photos)"
            case .missing: "not found: --root \(root.lightroomPath)=<folder> says where it is"
            }
            let place = root.path.map { root.moved ? " → \($0)" : "" } ?? ""
            lines.append("    \(root.lightroomPath)\(place): \(state)")
        }
        let fieldLines: [(String, Int, Int)] = [
            ("ratings", fields.ratings, differing.ratings), ("picks", fields.picks, differing.picks),
            ("rejects", fields.rejects, differing.rejects), ("colour labels", fields.labels, differing.labels),
            ("custom labels", fields.customLabels, differing.customLabels),
            ("marks (the Quick Collection)", fields.marks, differing.marks),
            ("titles", fields.titles, differing.titles), ("captions", fields.captions, differing.captions),
            ("creators", fields.creators, differing.creators), ("copyrights", fields.copyrights, differing.copyrights),
            ("locations", fields.locations, differing.locations), ("with keywords", fields.keywords, 0),
            ("in collections", fields.collections, 0),
        ]
        lines.append("  coming across, for the photos found (\(Self.count(changing)) of them change):")
        for (name, count, differing) in fieldLines where count > 0 {
            lines.append("    \(Self.count(count)) \(name)"
                + (differing > 0 ? ", \(Self.count(differing)) replacing another value" : ""))
        }
        if pairs > 0 {
            lines.append("    \(Self.count(pairs)) JPEGs given their raws' fields, as Lightroom kept each pair as one")
        }
        lines.append("    \(Self.count(keywords)) keywords, \(Self.count(synonyms)) synonyms, "
            + "\(Self.count(notExported)) not exported, \(Self.count(people)) people")
        lines.append("    \(Self.count(collections)) collections and \(Self.count(sets)) sets, "
            + "\(Self.count(smartMapped.count)) of \(Self.count(smart.count)) smart collections")
        for smart in smartMapped {
            lines.append("      \(smart.path): \(smart.query ?? "")")
            for difference in smart.differences {
                lines.append("        \(difference)")
            }
        }
        for output in outputs {
            lines.append("      \(output): a book, slideshow, print or web gallery, brought across as a collection")
        }
        for (from, to) in renamed.sorted(by: { $0.key < $1.key }) {
            lines.append("      \(from) is “\(to)”: the library has something else at its place")
        }
        if !smartLeft.isEmpty || !left.isEmpty || notFound > 0 {
            lines.append("  not coming across:")
        }
        for smart in smartLeft {
            lines.append("    the smart collection \(smart.path): \(smart.reasons.joined(separator: "; "))")
        }
        for item in left {
            lines.append("    \(Self.count(item.count)) \(item.what): \(item.why)")
        }
        if notFound > 0 {
            lines.append("    \(Self.count(notFound)) photos not found in the library's folders:")
            lines += notFoundPaths.map { "      \($0)" }
            if notFound > notFoundPaths.count {
                lines.append("      and \(Self.count(notFound - notFoundPaths.count)) more")
            }
        }
        lines += notes.map { "  note: \($0)" }
        return lines
    }

    /// `20,000`, whatever the locale.
    internal static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

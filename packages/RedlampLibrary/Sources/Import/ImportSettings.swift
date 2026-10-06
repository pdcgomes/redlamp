import Foundation
import RedlampDocument

/// A metadata preset an import applies to every photo it brings in: keywords added to its own, and a
/// rating and a label for those the user gave none while browsing. IPTC's fields (creator, copyright,
/// captions) join when the sidecar holds them (LIB-22).
public struct ImportMetadata: Sendable, Hashable, Codable {
    public var name: String
    /// Keywords by path, `Places/Portugal/Lisbon`.
    public var keywords: [String]
    public var rating: Int?
    public var label: ColorLabel?

    public init(name: String = "", keywords: [String] = [], rating: Int? = nil, label: ColorLabel? = nil) {
        self.name = name
        self.keywords = KeywordPath.texts(keywords)
        self.rating = rating.map { min(max($0, 0), 5) }
        self.label = label
    }

    public var isEmpty: Bool {
        keywords.isEmpty && rating == nil && label == nil
    }
}

/// Where an import puts what it copies and how it names it (LIB-27), and what tethered capture's
/// sessions (TET-01) share with it: a destination and an optional backup, folders made from each
/// photo's fields below them, a naming template (LIB-25), raw files only or every photo, a metadata
/// preset, and what the app does around a card.
public struct ImportSettings: Sendable, Hashable, Codable {
    /// The folder photos go in, below which `folders` makes their folders. It's added to the library
    /// if it isn't in it.
    public var destination: URL
    /// A second place every photo is copied to, under the same folders and names, and never added to
    /// the library: a copy of its own, block for block, never an APFS clone.
    public var backup: URL?
    /// The folders below the destination, a level for each `/` written between tokens:
    /// `{date:yyyy}/{date:yyyy-MM-dd}`. A level that comes out empty is left out.
    public var folders: NamingTemplate
    /// The photos' names; `{name}` keeps the camera's. A raw and its JPEG share one.
    public var names: NamingTemplate
    public var naming: NamingOptions
    /// `{text}` and `{text:shoot}`.
    public var texts: [String: String]
    /// Named counters `{counter:…}` continue from; an import returns them moved on.
    public var counters: NamingCounters
    /// Only raw files: a raw's JPEG, and photos that aren't raws, stay on the source.
    public var rawOnly: Bool
    /// Photos the library already has, recognised by their content keys, aren't copied again.
    public var skipsImported: Bool
    public var metadata: ImportMetadata
    /// For the app: an import window opens and starts browsing when a card is inserted.
    public var startsWhenCardInserted: Bool
    /// For the app: the cards are ejected once the import is over and every photo verified.
    public var ejectsWhenDone: Bool

    public init(
        destination: URL, backup: URL? = nil, folders: NamingTemplate = ImportSettings.standardFolders,
        names: NamingTemplate = ImportSettings.standardNames, naming: NamingOptions = NamingOptions(),
        texts: [String: String] = [:], counters: NamingCounters = NamingCounters(), rawOnly: Bool = false,
        skipsImported: Bool = true, metadata: ImportMetadata = ImportMetadata(),
        startsWhenCardInserted: Bool = false, ejectsWhenDone: Bool = false,
    ) {
        self.destination = URL(fileURLWithPath: LibraryIndexer.path(destination), isDirectory: true)
        self.backup = backup.map { URL(fileURLWithPath: LibraryIndexer.path($0), isDirectory: true) }
        self.folders = folders
        self.names = names
        self.naming = naming
        self.texts = texts
        self.counters = counters
        self.rawOnly = rawOnly
        self.skipsImported = skipsImported
        self.metadata = metadata
        self.startsWhenCardInserted = startsWhenCardInserted
        self.ejectsWhenDone = ejectsWhenDone
    }

    /// A folder a year, and in it a folder a day: `2026/2026-10-05`, as Lightroom Classic's import
    /// makes them by date.
    public static let standardFolders = template("{date:yyyy}/{date:yyyy-MM-dd}")
    /// The camera's own names.
    public static let standardNames = template("{name}")

    /// Folder templates the import window offers, by name.
    public static let folderPresets: [(name: String, folders: NamingTemplate)] = [
        ("Year / Year-Month-Day", standardFolders),
        ("Year / Month", template("{date:yyyy}/{date:MM}")),
        ("Year-Month-Day", template("{date:yyyy-MM-dd}")),
        ("Year / Year-Month-Day Shoot", template("{date:yyyy}/{date:yyyy-MM-dd}{text:shoot|before:\" \"}")),
        ("Camera / Year-Month-Day", template("{camera}/{date:yyyy-MM-dd}")),
        ("Into One Folder", NamingTemplate([])),
    ]

    private static func template(_ text: String) -> NamingTemplate {
        try! NamingTemplate(parsing: text)
    }

    /// The folder template's levels: its parts split at each `/` in its text.
    var folderLevels: [NamingTemplate] {
        var levels: [[NamingTemplate.Part]] = [[]]
        for part in folders.parts {
            guard case let .text(text) = part else {
                levels[levels.count - 1].append(part)
                continue
            }
            for (number, piece) in text.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
                if number > 0 {
                    levels.append([])
                }
                if !piece.isEmpty {
                    levels[levels.count - 1].append(.text(String(piece)))
                }
            }
        }
        return levels.filter { !$0.isEmpty }.map(NamingTemplate.init)
    }
}
